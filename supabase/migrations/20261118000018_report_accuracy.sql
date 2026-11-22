-- Report accuracy (from the system audit):
--  * gift cards and prepaid packages are money held for the customer, not sales; the ledger already books them as liabilities.
--    Sales reports and the dashboard now leave them out of sales (shown separately as "prepaid sold"), so revenue is not
--    counted twice (once when the card is sold, again when it is spent).
--  * the payments report now includes deposits and driver cash, so it matches the cash drawer.

-- what part of a document is a voucher (gift card or prepaid package), VAT included
create or replace function public._voucher_total(p_sale uuid) returns bigint
language sql stable set search_path = public as $$
  select coalesce(sum(l.line_total), 0)::bigint from sale_lines l join items i on i.id = l.item_id
   where l.sale_id = p_sale and i.item_type in ('gift_card', 'package');
$$;
grant execute on function public._voucher_total(uuid) to authenticated;

create or replace view public.v_daily_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id,
       (s.created_at at time zone b.timezone)::date as day,
       count(*) filter (where s.doc_type = 'invoice')                          as invoices,
       count(*) filter (where s.doc_type = 'credit_note')                      as credit_notes,
       coalesce(sum(s.total - public._voucher_total(s.id)) filter (where s.doc_type = 'invoice'),0) as gross_sales,
       coalesce(sum(s.total - public._voucher_total(s.id)) filter (where s.doc_type = 'credit_note'),0) as refunds,
       coalesce(sum(case when s.doc_type='invoice' then 1 else -1 end * (s.total - public._voucher_total(s.id))),0) as net_sales,
       coalesce(sum(case when s.doc_type='invoice' then s.tax_total else -s.tax_total end),0) as tax,
       coalesce(sum(s.discount_total) filter (where s.doc_type = 'invoice'),0) as discounts,
       coalesce(sum(case when s.doc_type='invoice' then 1 else -1 end * public._voucher_total(s.id)),0) as prepaid_sold
  from public.sales s join public.branches b on b.id = s.branch_id
 group by 1,2,3;

create or replace view public.v_hourly_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day,
       extract(hour from s.created_at at time zone b.timezone)::int as hour,
       sum(case when s.doc_type='invoice' then 1 else -1 end * (s.total - public._voucher_total(s.id))) as net_sales, count(*) as docs
  from public.sales s join public.branches b on b.id = s.branch_id
 group by 1,2,3,4;

grant select on public.v_daily_sales, public.v_hourly_sales to authenticated;

-- ================================================================ per-user preferences (theme, sidebar, dashboard layout)
create table if not exists public.user_prefs (
  user_id    uuid not null,
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  prefs      jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (user_id, tenant_id)
);
alter table public.user_prefs enable row level security;
create policy up_own on public.user_prefs for all to authenticated
  using (user_id = auth.uid() and public.is_member(tenant_id)) with check (user_id = auth.uid() and public.is_member(tenant_id));
grant select, insert, update on public.user_prefs to authenticated;

-- ================================================================ card methods (K-Net, Visa / Mastercard, Apple Pay, mada…) on payments
alter table public.payments add column if not exists method text;
-- every payment that moves money: sales, refunds, deposits on job cards / pre-orders, driver cash handed in
drop view if exists public.v_tender_daily;
create view public.v_tender_daily with (security_invoker = true) as
select p.tenant_id, coalesce(s.branch_id, w.branch_id, d.branch_id) as branch_id,
       (p.created_at at time zone b.timezone)::date as day, p.tender, p.status, p.method,
       sum(p.amount) as amount, count(*) as count
  from public.payments p
  left join public.sales s on s.id = p.sale_id
  left join public.work_orders w on w.id = p.work_order_id
  left join public.deliveries d on d.id = p.delivery_id
  join public.branches b on b.id = coalesce(s.branch_id, w.branch_id, d.branch_id)
 group by 1,2,3,4,5,6;
grant select on public.v_tender_daily to authenticated;

-- checkout keeps the card method chosen at the till
create or replace function public.complete_sale(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  t tenants%rowtype;
  v_branch uuid := (p->>'branch_id')::uuid;
  v_shift uuid := nullif(p->>'shift_id','')::uuid;
  v_client uuid := (p->>'client_id')::uuid;
  v_customer uuid := nullif(p->>'customer_id','')::uuid;
  v_at timestamptz := coalesce(nullif(p->>'device_created_at','')::timestamptz, now());
  v_existing uuid; v_sale uuid; v_number text; v_appr uuid;
  l jsonb; it items%rowtype; pay jsonb; cp customer_packages%rowtype; w work_orders%rowtype; oo open_orders%rowtype;
  v_qty numeric; v_price bigint; v_list_price bigint; v_disc bigint; v_promo bigint; v_pkg_disc bigint; v_rate numeric; v_gross bigint; v_tax bigint; v_net bigint; v_total_line bigint;
  v_list bigint := 0; v_manual bigint := 0; v_promo_total bigint := 0; v_pkg_total bigint := 0;
  v_sub bigint := 0; v_sub_deferred bigint := 0; v_taxsum bigint := 0; v_total bigint := 0; v_cogs bigint := 0;
  v_paysum bigint := 0; v_captured bigint := 0; v_credit_use bigint := 0; v_sc_use bigint := 0; v_loyalty bigint := 0; v_dep bigint := 0;
  v_lines jsonb := '[]'; v_je jsonb := '[]'; v_pid uuid; v_tender tender_type; v_amt bigint; v_ucost bigint; v_track boolean;
  v_pre jsonb := '[]'; v_allow jsonb; v_idx int := 0; v_mods jsonb; v_mod_add bigint; v_mod_cost bigint; v_mod_names text; v_mod_ar text;
  v_pkg_value bigint; v_tender_list jsonb := '[]'; v_point_value numeric; v_points int; v_earn_base bigint; g record; v_cnt int;
  v_sub_gift bigint := 0; gc gift_cards%rowtype; v_gift_use jsonb := '[]'; v_cod bigint := 0; v_code text; oq online_orders%rowtype;
begin
  select * into t from tenants where id = (p->>'tenant_id')::uuid;
  if not found or not is_member(t.id) then raise exception 'not a member of this business' using errcode = '42501'; end if;
  if not can_see_branch(t.id, v_branch) or not exists (select 1 from branches where id = v_branch and tenant_id = t.id) then
    raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(t.id, 'sale.create', null, null);

  -- idempotency: replays from the offline outbox return the original sale
  select id into v_existing from sales where tenant_id = t.id and client_id = v_client;
  if v_existing is not null then return sale_json(v_existing); end if;

  if v_shift is not null and not exists (select 1 from shifts where id = v_shift and branch_id = v_branch and closed_at is null) then v_shift := null; end if;
  if v_customer is not null and not exists (select 1 from customers where id = v_customer and tenant_id = t.id) then raise exception 'unknown customer'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'empty sale'; end if;

  -- ---- pass 1: list prices with add-ons, for the promotion engine
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_idx := v_idx + 1;
    select coalesce(sum(o.price), 0) into v_mod_add from modifier_options o
     where o.tenant_id = t.id and o.id in (select jsonb_array_elements_text((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end))::uuid);
    select * into it from items where id = nullif(l->>'item_id','')::uuid and tenant_id = t.id;
    v_pre := v_pre || jsonb_build_object('idx', v_idx, 'item_id', it.id, 'qty', (l->>'qty')::numeric,
              'gross', round((l->>'qty')::numeric * coalesce((l->>'unit_price')::bigint, coalesce(it.price, 0) + v_mod_add)));
  end loop;
  v_allow := case when has_feature(t.id, 'promotions') then promo_allowance(t.id, v_at, v_pre, p->>'coupon') else '[]' end;

  -- ---- pass 2: price every line
  v_idx := 0;
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_idx := v_idx + 1;
    it := null; cp := null;
    if nullif(l->>'item_id','') is not null then
      select * into it from items where id = (l->>'item_id')::uuid and tenant_id = t.id;
      if not found then raise exception 'unknown item %', l->>'item_id'; end if;
    end if;
    if it.item_type = 'ingredient' then raise exception 'ingredients are not sold directly: %', it.name using errcode = 'ZT422'; end if;
    if it.is_template then raise exception 'choose a size or colour for %', it.name using errcode = 'ZT422'; end if;
    if it.item_type = 'package' and v_customer is null then raise exception 'choose the customer who buys the package' using errcode = 'ZT422'; end if;
    if it.item_type = 'gift_card' then
      perform _require_feature(t.id, 'gift_cards');
      if coalesce((l->>'unit_price')::bigint, 0) <= 0 then raise exception 'enter the gift card amount' using errcode = 'ZT422'; end if;
    end if;
    v_qty := (l->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'quantity must be positive'; end if;

    -- add-ons: valid options of this item's groups; required groups must be answered
    select coalesce(jsonb_agg(jsonb_build_object('option_id', o.id, 'name', o.name, 'name_ar', o.name_ar, 'price', o.price) order by g2.sort, o.sort), '[]'),
           coalesce(sum(o.price), 0), coalesce(sum(round(o.qty * coalesce(oi.cost, 0))), 0),
           string_agg(o.name, ', ' order by g2.sort, o.sort), string_agg(coalesce(o.name_ar, o.name), '، ' order by g2.sort, o.sort)
      into v_mods, v_mod_add, v_mod_cost, v_mod_names, v_mod_ar
      from modifier_options o join modifier_groups g2 on g2.id = o.group_id
      join item_modifier_groups ig on ig.group_id = g2.id and ig.item_id = it.id
      left join items oi on oi.id = o.item_id
     where o.tenant_id = t.id and o.is_active and o.id in (select jsonb_array_elements_text((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end))::uuid);
    if jsonb_array_length(v_mods) < jsonb_array_length((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end)) then raise exception 'an add-on does not belong to %', it.name using errcode = 'ZT422'; end if;
    for g in select g3.name, g3.min_select, g3.max_select, (select count(*) from jsonb_array_elements(v_mods) m join modifier_options mo on mo.id = (m->>'option_id')::uuid where mo.group_id = g3.id) as n
               from item_modifier_groups ig2 join modifier_groups g3 on g3.id = ig2.group_id where ig2.item_id = it.id loop
      if g.n < g.min_select or g.n > g.max_select then raise exception 'choose % for %', g.name, it.name using errcode = 'ZT422'; end if;
    end loop;

    v_ucost := case when it.item_type = 'recipe' then recipe_cost(it.id) else coalesce(it.cost, 0) end + v_mod_cost;
    v_track := coalesce(it.track_stock, false) and coalesce(it.item_type, 'standard') = 'standard';
    v_list_price := coalesce(it.price, 0) + v_mod_add;
    v_price := coalesce((l->>'unit_price')::bigint, v_list_price);
    v_disc  := coalesce((l->>'discount')::bigint, 0);
    if v_price < 0 or v_disc < 0 then raise exception 'negative price or discount'; end if;
    -- promotion: what the POS claims, capped at what the rules allow for this line
    v_promo := least(greatest(coalesce((l->>'promo_discount')::bigint, 0), 0),
                     coalesce((select (x->>'discount')::bigint from jsonb_array_elements(v_allow) x where (x->>'idx')::int = v_idx), 0));
    v_rate  := coalesce(it.tax_rate, t.vat_rate);
    -- a gift card is a voucher for later purchases: no VAT now, the money is owed to the holder
    if it.item_type = 'gift_card' then v_rate := 0; v_promo := 0; end if;

    -- a session from a prepaid package: the line is valued at the package's price per session, VAT was charged when it was sold
    v_pkg_disc := 0; v_pkg_value := null;
    if nullif(l->>'customer_package_id','') is not null then
      select * into cp from customer_packages where id = (l->>'customer_package_id')::uuid and tenant_id = t.id for update;
      if not found or cp.customer_id is distinct from v_customer then raise exception 'this package belongs to another customer' using errcode = 'ZT422'; end if;
      if cp.status <> 'active' or cp.expires_on < v_at::date then raise exception 'the package has expired or is used up' using errcode = 'ZT422'; end if;
      if cp.covers is not null and not (it.id = any(cp.covers)) then raise exception 'the package does not cover %', it.name using errcode = 'ZT422'; end if;
      if cp.kind <> 'sessions' or v_qty <> floor(v_qty) or cp.sessions_used + v_qty > cp.sessions_total then
        raise exception 'not enough sessions left in the package' using errcode = 'ZT422'; end if;
      v_pkg_value := least(package_session_value(cp.id, v_qty::int), round(v_qty * v_price)::bigint);
      v_pkg_disc := round(v_qty * v_price)::bigint - v_pkg_value; v_promo := 0; v_disc := 0; v_rate := 0;
      update customer_packages set sessions_used = sessions_used + v_qty::int, released = released + v_pkg_value,
             status = case when sessions_used + v_qty::int >= sessions_total then 'used' else status end where id = cp.id;
      v_pkg_total := v_pkg_total + v_pkg_value;
    end if;

    v_gross := round(v_qty * v_price)::bigint - v_disc - v_promo - v_pkg_disc;
    if v_gross < 0 then raise exception 'discount larger than line'; end if;
    if t.prices_include_tax then
      v_tax := round(v_gross * v_rate / (100 + v_rate))::bigint; v_net := v_gross - v_tax; v_total_line := v_gross;
    else
      v_net := v_gross; v_tax := round(v_net * v_rate / 100)::bigint; v_total_line := v_net + v_tax;
    end if;
    v_list := v_list + round(v_qty * v_list_price)::bigint;
    v_manual := v_manual + v_disc + greatest(round(v_qty * (v_list_price - v_price))::bigint, 0);
    v_promo_total := v_promo_total + v_promo;
    v_sub := v_sub + v_net; v_taxsum := v_taxsum + v_tax; v_total := v_total + v_total_line;
    if it.item_type = 'package' then v_sub_deferred := v_sub_deferred + v_net; end if;
    if it.item_type = 'gift_card' then v_sub_gift := v_sub_gift + v_net; end if;
    if it.id is not null and (v_track or it.item_type = 'recipe' or v_mod_cost > 0) then v_cogs := v_cogs + round(v_qty * v_ucost)::bigint; end if;
    if nullif(l->>'staff_id','') is not null and not exists (select 1 from memberships where tenant_id = t.id and user_id = (l->>'staff_id')::uuid) then
      raise exception 'unknown staff member'; end if;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'item_type', it.item_type,
      'name', coalesce(nullif(l->>'name',''), it.name, 'Item') || coalesce(' (' || v_mod_names || ')', ''),
      'qty', v_qty, 'unit_price', v_price, 'discount', v_disc + v_pkg_disc, 'tax_rate', v_rate, 'net', v_net, 'tax', v_tax,
      'total', v_total_line, 'unit_cost', v_ucost, 'track', v_track, 'note', nullif(l->>'note',''), 'modifiers', case when jsonb_array_length(v_mods) > 0 then v_mods end,
      'staff_id', nullif(l->>'staff_id',''), 'promo_id', case when v_promo > 0 then (select x->>'promo_id' from jsonb_array_elements(v_allow) x where (x->>'idx')::int = v_idx) end,
      'promo_discount', v_promo, 'customer_package_id', cp.id, 'pkg_value', v_pkg_value, 'gift_code', nullif(upper(trim(l->>'gift_code')),''));
  end loop;

  -- ---- manual discount / price override approval (promotions and package sessions need none)
  if v_manual > 0 then
    v_appr := _require(t.id, 'sale.discount', round(v_manual * 100.0 / nullif(v_list,0), 2), p->>'approver_pin');
  end if;

  -- ---- server-side tenders: package sessions, then the deposit of the job / pre-order
  if v_pkg_total > 0 then v_tender_list := v_tender_list || jsonb_build_object('tender', 'package', 'amount', v_pkg_total); end if;
  if nullif(p->>'work_order_id','') is not null then
    select * into w from work_orders where id = (p->>'work_order_id')::uuid and tenant_id = t.id for update;
    if not found or w.status in ('collected','cancelled') then raise exception 'this order is closed' using errcode = 'ZT422'; end if;
    v_dep := least(w.deposit_paid - w.deposit_used, v_total - v_pkg_total);
    if v_dep > 0 then v_tender_list := v_tender_list || jsonb_build_object('tender', 'deposit', 'amount', v_dep); end if;
  end if;

  -- ---- tenders from the POS
  for pay in select * from jsonb_array_elements(coalesce(p->'payments','[]')) loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    if v_amt is null or v_amt <= 0 then raise exception 'payment amounts must be positive'; end if;
    if v_tender in ('package','deposit') then raise exception 'package and deposit amounts are applied automatically' using errcode = 'ZT422'; end if;
    v_paysum := v_paysum + v_amt;
    if v_tender in ('on_account','payment_link','store_credit','loyalty') and v_customer is null then
      raise exception 'choose a customer for % payments', v_tender; end if;
    if v_tender = 'on_account' then v_credit_use := v_credit_use + v_amt; end if;
    if v_tender = 'store_credit' then v_sc_use := v_sc_use + v_amt; end if;
    if v_tender = 'loyalty' then v_loyalty := v_loyalty + v_amt; end if;
    if v_tender = 'gift_card' then
      v_code := upper(trim(coalesce(pay->>'reference','')));
      select * into gc from gift_cards where tenant_id = t.id and code = v_code for update;
      if not found or gc.status <> 'active' or (gc.expires_on is not null and gc.expires_on < v_at::date) then raise exception 'gift card % is not valid', v_code using errcode = 'ZT422'; end if;
      if gc.balance - coalesce((select sum((x->>'amount')::bigint) from jsonb_array_elements(v_gift_use) x where x->>'id' = gc.id::text), 0) < v_amt then
        raise exception 'gift card % has only %', v_code, gc.balance using errcode = 'ZT422'; end if;
      v_gift_use := v_gift_use || jsonb_build_object('id', gc.id, 'amount', v_amt);
    end if;
    if v_tender = 'cod' then
      perform _require_feature(t.id, 'own_delivery');
      if jsonb_typeof(p->'delivery') <> 'object' then raise exception 'cash on delivery needs a delivery address' using errcode = 'ZT422'; end if;
      v_cod := v_cod + v_amt;
    end if;
    v_tender_list := v_tender_list || jsonb_build_object('tender', v_tender, 'amount', v_amt, 'reference', pay->>'reference', 'method', left(nullif(pay->>'method',''), 40));
  end loop;
  if v_paysum + v_pkg_total + v_dep <> v_total then
    raise exception 'payments (%) must equal the total (%)', v_paysum, v_total - v_pkg_total - v_dep using errcode = 'ZT422'; end if;
  if v_credit_use > 0 and customer_balance(v_customer) + v_credit_use > (select credit_limit from customers where id = v_customer) then
    v_appr := coalesce(_require(t.id, 'sale.over_credit', null, p->>'approver_pin'), v_appr);
  end if;
  if v_sc_use > customer_store_credit(v_customer) then raise exception 'not enough store credit'; end if;
  if v_loyalty > 0 then
    perform _require_feature(t.id, 'loyalty');
    v_point_value := coalesce((t.settings->>'loyalty_point_value')::numeric, 0);
    if v_point_value <= 0 then raise exception 'set the value of a point in Settings first' using errcode = 'ZT422'; end if;
    v_points := ceil(v_loyalty / v_point_value);
    if v_points > customer_points(v_customer) then raise exception 'not enough points' using errcode = 'ZT422'; end if;
    if v_points < coalesce((t.settings->>'loyalty_min_points')::int, 0) then
      raise exception 'redeem at least % points', (t.settings->>'loyalty_min_points') using errcode = 'ZT422'; end if;
  end if;

  -- ---- write documents
  v_number := _next_number(t.id, v_branch, 'invoice');
  insert into sales(tenant_id, branch_id, shift_id, client_id, doc_type, number, customer_id, subtotal, discount_total,
                    tax_total, total, paid_total, approved_by, created_by, device_created_at, reason, channel_id, external_ref)
  values (t.id, v_branch, v_shift, v_client, 'invoice', v_number, v_customer, v_sub, v_manual + v_promo_total, v_taxsum, v_total, 0,
          v_appr, auth.uid(), nullif(p->>'device_created_at','')::timestamptz, nullif(p->>'note',''),
          (select id from delivery_channels where id = nullif(p->>'channel_id','')::uuid and tenant_id = t.id),
          case when nullif(p->>'channel_id','') is not null then nullif(p->>'external_ref','') end)
  returning id into v_sale;

  for l in select * from jsonb_array_elements(v_lines) loop
    insert into sale_lines(tenant_id, sale_id, item_id, name, qty, unit_price, discount, tax_rate, net_amount, tax_amount, line_total, unit_cost, note,
                           modifiers, staff_id, promo_id, promo_discount, customer_package_id)
    values (t.id, v_sale, nullif(l->>'item_id','')::uuid, l->>'name', (l->>'qty')::numeric, (l->>'unit_price')::bigint,
            (l->>'discount')::bigint, (l->>'tax_rate')::numeric, (l->>'net')::bigint, (l->>'tax')::bigint, (l->>'total')::bigint,
            (l->>'unit_cost')::bigint, nullif(l->>'note',''), nullif(l->'modifiers', 'null'::jsonb), nullif(l->>'staff_id','')::uuid,
            nullif(l->>'promo_id','')::uuid, (l->>'promo_discount')::bigint, nullif(l->>'customer_package_id','')::uuid);
    if (l->>'track')::boolean then
      insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, created_by)
      values (t.id, v_branch, (l->>'item_id')::uuid, -(l->>'qty')::numeric, 'sale', v_sale, (select cost from items where id = (l->>'item_id')::uuid), auth.uid());
    end if;
    -- add-ons that use stock (oat milk, extra cheese)
    insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
    select t.id, v_branch, o.item_id, -(o.qty * (l->>'qty')::numeric), 'sale', v_sale, oi.cost, 'add-on', auth.uid()
      from jsonb_array_elements((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end)) m join modifier_options o on o.id = (m->>'option_id')::uuid
      join items oi on oi.id = o.item_id and oi.track_stock
     where o.qty > 0;
    if nullif(l->>'customer_package_id','') is not null then
      insert into package_uses(tenant_id, package_id, sale_id, sessions, amount, used_by)
      values (t.id, (l->>'customer_package_id')::uuid, v_sale, (l->>'qty')::numeric::int, (l->>'pkg_value')::bigint, auth.uid());
    end if;
    -- a package sold: the customer gets it; its net value waits in deferred revenue
    if l->>'item_type' = 'package' then
      insert into customer_packages(tenant_id, customer_id, item_id, name, kind, sessions_total, price_paid, covers, sale_id, starts_on, expires_on)
      select t.id, v_customer, d.item_id, l->>'name', d.kind, case when d.kind = 'sessions' then d.sessions * (l->>'qty')::numeric::int end,
             (l->>'net')::bigint, d.covers, v_sale, v_at::date, v_at::date + d.validity_days
        from package_defs d where d.item_id = (l->>'item_id')::uuid;
      if not found then raise exception 'set up what the package % includes first', l->>'name' using errcode = 'ZT422'; end if;
    end if;
    -- a gift card sold: one card per unit, with the code on the pre-printed card or a new one
    if l->>'item_type' = 'gift_card' then
      for v_cnt in 1 .. greatest((l->>'qty')::numeric::int, 1) loop
        v_code := case when v_cnt = 1 and l->>'gift_code' is not null then l->>'gift_code' else 'GC' || upper(encode(gen_random_bytes(5), 'hex')) end;
        begin
          insert into gift_cards(tenant_id, code, initial, balance, customer_id, sale_id, expires_on)
          values (t.id, v_code, (l->>'total')::bigint / greatest((l->>'qty')::numeric::int, 1), (l->>'total')::bigint / greatest((l->>'qty')::numeric::int, 1), v_customer, v_sale,
                  case when coalesce((t.settings->>'gift_card_months')::int, 0) > 0 then v_at::date + make_interval(months => (t.settings->>'gift_card_months')::int) end)
          returning * into gc;
        exception when unique_violation then raise exception 'gift card code % is already used', v_code using errcode = 'ZT422'; end;
        insert into gift_card_moves(tenant_id, card_id, sale_id, amount, kind) values (t.id, gc.id, v_sale, gc.initial, 'issue');
      end loop;
    end if;
  end loop;

  for pay in select * from jsonb_array_elements(v_tender_list) loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    insert into payments(tenant_id, sale_id, tender, amount, reference, method, status, shift_id, created_by)
    values (t.id, v_sale, v_tender, v_amt, nullif(pay->>'reference',''), pay->>'method',
            case when v_tender in ('payment_link','cod') then 'pending' else 'captured' end, v_shift, auth.uid())
    returning id into v_pid;
    if v_tender = 'payment_link' then insert into payment_links(tenant_id, sale_id, payment_id, amount) values (t.id, v_sale, v_pid, v_amt); end if;
    if v_tender not in ('on_account','payment_link','cod') then v_captured := v_captured + v_amt; end if;
    v_je := v_je || jsonb_build_object('key', _tender_account(v_tender), 'debit', v_amt,
              'customer_id', case when v_tender in ('on_account','payment_link','store_credit','deposit') then v_customer end);
  end loop;
  update sales set paid_total = v_captured where id = v_sale;

  v_je := v_je || jsonb_build_array(
    jsonb_build_object('key','sales','credit', v_sub - v_sub_deferred - v_sub_gift),
    jsonb_build_object('key','gift_cards','credit', v_sub_gift),
    jsonb_build_object('key','deferred_revenue','credit', v_sub_deferred),
    jsonb_build_object('key','vat_payable','credit', v_taxsum),
    jsonb_build_object('key','cogs','debit', v_cogs),
    jsonb_build_object('key','inventory','credit', v_cogs));
  perform _post(t.id, v_branch, 'sale', v_sale, v_number, v_je);

  if v_manual > 0 then
    perform _audit(t.id, v_branch, 'sale.discount', 'sale', v_sale, v_manual, nullif(p->>'note',''), v_appr,
                   jsonb_build_object('percent', round(v_manual * 100.0 / nullif(v_list,0), 2)));
  end if;

  -- ---- gift card redemptions
  for pay in select * from jsonb_array_elements(v_gift_use) loop
    update gift_cards set balance = balance - (pay->>'amount')::bigint where id = (pay->>'id')::uuid;
    insert into gift_card_moves(tenant_id, card_id, sale_id, amount, kind) values (t.id, (pay->>'id')::uuid, v_sale, -(pay->>'amount')::bigint, 'redeem');
  end loop;

  -- ---- loyalty: redeem, then earn on what was paid with money
  if v_loyalty > 0 then
    insert into loyalty_ledger(tenant_id, customer_id, sale_id, points, kind, created_by) values (t.id, v_customer, v_sale, -v_points, 'redeem', auth.uid());
  end if;
  if v_customer is not null and has_feature(t.id, 'loyalty') and coalesce((t.settings->>'loyalty_earn')::numeric, 0) > 0 then
    v_earn_base := v_total - v_loyalty - v_pkg_total - v_dep - v_sc_use - v_sub_gift - coalesce((select sum((x->>'amount')::bigint) from jsonb_array_elements(v_gift_use) x), 0);
    v_points := floor(v_earn_base / (10 ^ t.currency_decimals) * (t.settings->>'loyalty_earn')::numeric);
    if v_points > 0 then
      insert into loyalty_ledger(tenant_id, customer_id, sale_id, points, kind, created_by) values (t.id, v_customer, v_sale, v_points, 'earn', auth.uid());
    end if;
  end if;

  -- ---- what this sale closes
  if w.id is not null then
    update work_orders set deposit_used = deposit_used + v_dep, status = 'collected', collected_at = now(), sale_id = v_sale where id = w.id;
  end if;
  if nullif(p->>'appointment_id','') is not null then
    update appointments set status = 'completed', sale_id = v_sale, updated_at = now()
     where id = (p->>'appointment_id')::uuid and tenant_id = t.id and status not in ('cancelled','completed');
  end if;
  if nullif(p->>'open_order_id','') is not null then
    select * into oo from open_orders where id = (p->>'open_order_id')::uuid and tenant_id = t.id and status = 'open' for update;
    if found then
      update open_orders set
        lines = case when p ? 'open_order_keys'
                     then coalesce((select jsonb_agg(x) from jsonb_array_elements(lines) x where not (x->>'key') in (select jsonb_array_elements_text(p->'open_order_keys'))), '[]')
                     else '[]' end,
        sale_ids = sale_ids || v_sale, updated_at = now()
       where id = oo.id;
      update open_orders set status = 'closed', closed_at = now() where id = oo.id and jsonb_array_length(lines) = 0;
    end if;
  end if;

  if nullif(p->>'online_order_id','') is not null then
    update online_orders set status = 'paid', sale_id = v_sale where id = (p->>'online_order_id')::uuid and tenant_id = t.id and status in ('pending','accepted');
  end if;
  -- own delivery: the order goes to a driver; cash on delivery is collected by the driver
  if jsonb_typeof(p->'delivery') = 'object' then
    perform _require_feature(t.id, 'own_delivery');
    insert into deliveries(tenant_id, branch_id, sale_id, customer_id, address, phone, note, driver_id, status, cash_to_collect, assigned_at)
    values (t.id, v_branch, v_sale, v_customer, coalesce(nullif(p->'delivery'->>'address',''), (select address from customers where id = v_customer)),
            coalesce(nullif(p->'delivery'->>'phone',''), (select phone from customers where id = v_customer)), nullif(p->'delivery'->>'note',''),
            nullif(p->'delivery'->>'driver_id','')::uuid, case when nullif(p->'delivery'->>'driver_id','') is not null then 'assigned' else 'pending' end, v_cod,
            case when nullif(p->'delivery'->>'driver_id','') is not null then now() end);
  end if;

  perform _consume_recipes(v_sale);
  if nullif(p->>'open_order_id','') is null then perform _kitchen_from_sale(v_sale, p); end if;
  return sale_json(v_sale);
end $$;
grant execute on function public.complete_sale(jsonb) to authenticated;

-- Z Trust · item images, ingredients & recipes, detailed inventory, receipt settings, delivery platforms
--  * items.item_type: standard (sold + stocked) | ingredient (stocked, never sold) | recipe (sold, consumes ingredients)
--  * selling a recipe deducts each ingredient from stock at its moving-average cost; COGS = ingredient cost
--  * stock counts post the difference to the ledger; stock card shows every movement with a running balance
--  * tenants.settings holds POS display and receipt header/footer (phones, address, CR, terms)
--  * delivery channels (Keeta, Talabat, Jahez, …): orders arrive via webhook or are keyed at the POS;
--    they post to a platform receivable that is cleared by the platform settlement (commission as expense)

-- ================================================================ settings & images
alter table public.tenants add column settings jsonb not null default '{}';
alter table public.items add column item_type text not null default 'standard' check (item_type in ('standard','ingredient','recipe'));
alter table public.items add column unit text not null default 'pcs' check (unit in ('pcs','kg','g','l','ml','box','pack'));
alter table public.items add column reorder_point numeric(14,3);

do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('item-images', 'item-images', true, 2097152, array['image/webp','image/jpeg','image/png'])
    on conflict (id) do nothing;
    -- path: <tenant_id>/<file>; only people who manage the catalog of that business can write
    execute $p$create policy item_images_write on storage.objects for insert to authenticated
      with check (bucket_id = 'item-images' and public.has_perm(((storage.foldername(name))[1])::uuid, 'catalog.manage'))$p$;
    execute $p$create policy item_images_update on storage.objects for update to authenticated
      using (bucket_id = 'item-images' and public.has_perm(((storage.foldername(name))[1])::uuid, 'catalog.manage'))$p$;
    execute $p$create policy item_images_delete on storage.objects for delete to authenticated
      using (bucket_id = 'item-images' and public.has_perm(((storage.foldername(name))[1])::uuid, 'catalog.manage'))$p$;
  end if;
end $$;

-- ================================================================ recipes
create table public.recipe_lines (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  item_id       uuid not null references public.items(id) on delete cascade,     -- the menu item
  ingredient_id uuid not null references public.items(id),                       -- consumed item
  qty           numeric(14,4) not null check (qty > 0),                          -- in the ingredient's unit, per 1 menu item
  unique (item_id, ingredient_id),
  check (item_id <> ingredient_id)
);
alter table public.recipe_lines enable row level security;
create policy rl_read on public.recipe_lines for select to authenticated using (public.is_member(tenant_id));
create policy rl_write on public.recipe_lines for all to authenticated
  using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));

create or replace function public.recipe_cost(p_item uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(round(sum(r.qty * i.cost)), 0)::bigint from recipe_lines r join items i on i.id = r.ingredient_id where r.item_id = p_item;
$$;

-- after a sale: recipe lines consume their ingredients (append-only movements, valued at moving-average cost)
create or replace function public._consume_recipes(p_sale uuid) returns void
language sql security definer set search_path = public as $$
  insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
  select s.tenant_id, s.branch_id, r.ingredient_id, -(l.qty * r.qty), 'sale', s.id, ing.cost, 'recipe: ' || l.name, auth.uid()
    from sales s join sale_lines l on l.sale_id = s.id join items it on it.id = l.item_id and it.item_type = 'recipe'
    join recipe_lines r on r.item_id = it.id join items ing on ing.id = r.ingredient_id
   where s.id = p_sale;
$$;

-- recipe items are never stocked themselves; ingredients are never on the till
create or replace function public.normalize_item_type() returns trigger language plpgsql as $$
begin
  if new.item_type = 'recipe' then new.track_stock := false; end if;
  if new.item_type = 'ingredient' then new.track_stock := true; end if;
  return new;
end $$;
create trigger items_type_guard before insert or update of item_type, track_stock on public.items for each row execute function public.normalize_item_type();

-- complete_sale: recipes consume ingredients; COGS from ingredient cost; ingredients cannot be sold
create or replace function public.complete_sale(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t tenants%rowtype;
  v_branch uuid := (p->>'branch_id')::uuid;
  v_shift uuid := nullif(p->>'shift_id','')::uuid;
  v_client uuid := (p->>'client_id')::uuid;
  v_customer uuid := nullif(p->>'customer_id','')::uuid;
  v_existing uuid; v_sale uuid; v_number text; v_appr uuid;
  l jsonb; it items%rowtype; pay jsonb;
  v_qty numeric; v_price bigint; v_disc bigint; v_rate numeric; v_gross bigint; v_tax bigint; v_net bigint; v_total_line bigint;
  v_list bigint := 0; v_discount_total bigint := 0;
  v_sub bigint := 0; v_taxsum bigint := 0; v_total bigint := 0; v_cogs bigint := 0;
  v_paysum bigint := 0; v_captured bigint := 0; v_credit_use bigint := 0; v_sc_use bigint := 0;
  v_lines jsonb := '[]'; v_je jsonb := '[]'; v_pid uuid; v_tender tender_type; v_amt bigint; v_ucost bigint; v_track boolean;
begin
  select * into t from tenants where id = (p->>'tenant_id')::uuid;
  if not found or not is_member(t.id) then raise exception 'not a member of this business' using errcode = '42501'; end if;
  if not can_see_branch(t.id, v_branch) or not exists (select 1 from branches where id = v_branch and tenant_id = t.id) then
    raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(t.id, 'sale.create', null, null);

  -- idempotency: replays from the offline outbox return the original sale
  select id into v_existing from sales where tenant_id = t.id and client_id = v_client;
  if v_existing is not null then return sale_json(v_existing); end if;

  if v_shift is not null and not exists (select 1 from shifts where id = v_shift and branch_id = v_branch and closed_at is null) then
    v_shift := null;   -- shift closed while offline: keep the sale, detach from the shift
  end if;
  if v_customer is not null and not exists (select 1 from customers where id = v_customer and tenant_id = t.id) then
    raise exception 'unknown customer'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'empty sale'; end if;

  -- ---- price lines
  for l in select * from jsonb_array_elements(p->'lines') loop
    it := null;
    if nullif(l->>'item_id','') is not null then
      select * into it from items where id = (l->>'item_id')::uuid and tenant_id = t.id;
      if not found then raise exception 'unknown item %', l->>'item_id'; end if;
    end if;
    if it.item_type = 'ingredient' then raise exception 'ingredients are not sold directly: %', it.name using errcode = 'ZT422'; end if;
    v_ucost := case when it.item_type = 'recipe' then recipe_cost(it.id) else coalesce(it.cost, 0) end;
    v_track := coalesce(it.track_stock, false) and coalesce(it.item_type, 'standard') = 'standard';
    v_qty   := (l->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'quantity must be positive'; end if;
    v_price := coalesce((l->>'unit_price')::bigint, it.price, 0);
    v_disc  := coalesce((l->>'discount')::bigint, 0);
    if v_price < 0 or v_disc < 0 then raise exception 'negative price or discount'; end if;
    v_gross := round(v_qty * v_price)::bigint - v_disc;
    if v_gross < 0 then raise exception 'discount larger than line'; end if;
    v_rate  := coalesce(it.tax_rate, t.vat_rate);
    if t.prices_include_tax then
      v_tax := round(v_gross * v_rate / (100 + v_rate))::bigint; v_net := v_gross - v_tax; v_total_line := v_gross;
    else
      v_net := v_gross; v_tax := round(v_net * v_rate / 100)::bigint; v_total_line := v_net + v_tax;
    end if;
    v_list := v_list + round(v_qty * coalesce(it.price, v_price))::bigint;
    v_discount_total := v_discount_total + v_disc + greatest(round(v_qty * (coalesce(it.price, v_price) - v_price))::bigint, 0);
    v_sub := v_sub + v_net; v_taxsum := v_taxsum + v_tax; v_total := v_total + v_total_line;
    if it.id is not null and (v_track or it.item_type = 'recipe') then v_cogs := v_cogs + round(v_qty * v_ucost)::bigint; end if;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'name', coalesce(nullif(l->>'name',''), it.name, 'Item'),
      'qty', v_qty, 'unit_price', v_price, 'discount', v_disc, 'tax_rate', v_rate, 'net', v_net, 'tax', v_tax,
      'total', v_total_line, 'unit_cost', v_ucost, 'track', v_track, 'note', nullif(l->>'note',''));
  end loop;

  -- ---- discount / price override approval
  if v_discount_total > 0 then
    v_appr := _require(t.id, 'sale.discount', round(v_discount_total * 100.0 / nullif(v_list,0), 2), p->>'approver_pin');
  end if;

  -- ---- tenders
  for pay in select * from jsonb_array_elements(coalesce(p->'payments','[]')) loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    if v_amt is null or v_amt <= 0 then raise exception 'payment amounts must be positive'; end if;
    v_paysum := v_paysum + v_amt;
    if v_tender in ('on_account','payment_link','store_credit') and v_customer is null then
      raise exception 'choose a customer for % payments', v_tender; end if;
    if v_tender = 'on_account' then v_credit_use := v_credit_use + v_amt; end if;
    if v_tender = 'store_credit' then v_sc_use := v_sc_use + v_amt; end if;
  end loop;
  if v_paysum <> v_total then
    raise exception 'payments (%) must equal the total (%)', v_paysum, v_total using errcode = 'ZT422'; end if;
  if v_credit_use > 0 and customer_balance(v_customer) + v_credit_use > (select credit_limit from customers where id = v_customer) then
    v_appr := coalesce(_require(t.id, 'sale.over_credit', null, p->>'approver_pin'), v_appr);
  end if;
  if v_sc_use > customer_store_credit(v_customer) then raise exception 'not enough store credit'; end if;

  -- ---- write documents
  v_number := _next_number(t.id, v_branch, 'invoice');
  insert into sales(tenant_id, branch_id, shift_id, client_id, doc_type, number, customer_id, subtotal, discount_total,
                    tax_total, total, paid_total, approved_by, created_by, device_created_at, reason, channel_id, external_ref)
  values (t.id, v_branch, v_shift, v_client, 'invoice', v_number, v_customer, v_sub, v_discount_total, v_taxsum, v_total, 0,
          v_appr, auth.uid(), nullif(p->>'device_created_at','')::timestamptz, nullif(p->>'note',''),
          (select id from delivery_channels where id = nullif(p->>'channel_id','')::uuid and tenant_id = t.id),
          case when nullif(p->>'channel_id','') is not null then nullif(p->>'external_ref','') end)
  returning id into v_sale;

  for l in select * from jsonb_array_elements(v_lines) loop
    insert into sale_lines(tenant_id, sale_id, item_id, name, qty, unit_price, discount, tax_rate, net_amount, tax_amount, line_total, unit_cost, note)
    values (t.id, v_sale, nullif(l->>'item_id','')::uuid, l->>'name', (l->>'qty')::numeric, (l->>'unit_price')::bigint,
            (l->>'discount')::bigint, (l->>'tax_rate')::numeric, (l->>'net')::bigint, (l->>'tax')::bigint, (l->>'total')::bigint,
            (l->>'unit_cost')::bigint, nullif(l->>'note',''));
    if (l->>'track')::boolean then
      insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, created_by)
      values (t.id, v_branch, (l->>'item_id')::uuid, -(l->>'qty')::numeric, 'sale', v_sale, (l->>'unit_cost')::bigint, auth.uid());
    end if;
  end loop;

  for pay in select * from jsonb_array_elements(p->'payments') loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    insert into payments(tenant_id, sale_id, tender, amount, reference, status, shift_id, created_by)
    values (t.id, v_sale, v_tender, v_amt, nullif(pay->>'reference',''),
            case when v_tender in ('payment_link') then 'pending' else 'captured' end, v_shift, auth.uid())
    returning id into v_pid;
    if v_tender = 'payment_link' then
      insert into payment_links(tenant_id, sale_id, payment_id, amount) values (t.id, v_sale, v_pid, v_amt);
    end if;
    if v_tender not in ('on_account','payment_link') then v_captured := v_captured + v_amt; end if;
    v_je := v_je || jsonb_build_object('key', _tender_account(v_tender), 'debit', v_amt,
              'customer_id', case when v_tender in ('on_account','payment_link','store_credit') then v_customer end);
  end loop;
  update sales set paid_total = v_captured where id = v_sale;

  v_je := v_je || jsonb_build_array(
    jsonb_build_object('key','sales','credit', v_sub),
    jsonb_build_object('key','vat_payable','credit', v_taxsum),
    jsonb_build_object('key','cogs','debit', v_cogs),
    jsonb_build_object('key','inventory','credit', v_cogs));
  perform _post(t.id, v_branch, 'sale', v_sale, v_number, v_je);

  if v_discount_total > 0 then
    perform _audit(t.id, v_branch, 'sale.discount', 'sale', v_sale, v_discount_total, nullif(p->>'note',''), v_appr,
                   jsonb_build_object('percent', round(v_discount_total * 100.0 / nullif(v_list,0), 2)));
  end if;
  perform _consume_recipes(v_sale);
  perform _kitchen_from_sale(v_sale, p);
  return sale_json(v_sale);
end $$;


-- ================================================================ detailed inventory
create or replace view public.v_inventory with (security_invoker = true) as
select i.tenant_id, b.id as branch_id, i.id as item_id, i.name, i.name_ar, i.sku, i.barcode, i.item_type, i.unit, i.cost, i.reorder_point, i.category_id,
       coalesce(sum(m.qty), 0) as on_hand,
       (coalesce(sum(m.qty), 0) * i.cost)::bigint as value,
       max(m.created_at) as last_movement,
       coalesce(sum(-m.qty) filter (where m.reason = 'sale' and m.created_at > now() - interval '30 days'), 0) as used_30d
  from public.items i
  join public.branches b on b.tenant_id = i.tenant_id
  left join public.stock_movements m on m.item_id = i.id and m.branch_id = b.id
 where i.track_stock and i.item_type <> 'recipe'
 group by i.id, b.id;
grant select on public.v_inventory to authenticated;

create or replace function public.stock_card(p_item uuid, p_branch uuid, p_from date, p_to date)
returns table(created_at timestamptz, reason text, qty numeric, unit_cost bigint, balance numeric, note text, ref_id uuid, by_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_tenant uuid; v_open numeric;
begin
  select tenant_id into v_tenant from items where id = p_item;
  if v_tenant is null or not can_see_branch(v_tenant, p_branch) or not (has_perm(v_tenant,'inventory.view') or has_perm(v_tenant,'catalog.manage')) then
    raise exception 'not allowed' using errcode = '42501'; end if;
  select coalesce(sum(m.qty), 0) into v_open from stock_movements m where m.item_id = p_item and m.branch_id = p_branch and m.created_at < p_from;
  return query
  select p_from::timestamptz, 'opening'::text, null::numeric, null::bigint, v_open, null::text, null::uuid, null::text
  union all
  select m.created_at, m.reason, m.qty, m.unit_cost, v_open + sum(m.qty) over (order by m.created_at, m.id), m.note, m.ref_id, mb.display_name
    from stock_movements m left join memberships mb on mb.tenant_id = m.tenant_id and mb.user_id = m.created_by
   where m.item_id = p_item and m.branch_id = p_branch and m.created_at >= p_from and m.created_at < p_to + 1
   order by 1, 2 desc;
end $$;

-- p_lines: [{item_id, counted}]  → posts only the differences, valued at average cost
create or replace function public.post_stock_count(p_branch uuid, p_lines jsonb, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; l jsonb; it items%rowtype; v_onhand numeric; v_diff numeric; v_plus bigint := 0; v_minus bigint := 0; n int := 0; v_ref uuid := gen_random_uuid();
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if v_tenant is null or not can_see_branch(v_tenant, p_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'inventory.adjust', null, null);
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    select * into it from items where id = (l->>'item_id')::uuid and tenant_id = v_tenant and track_stock and item_type <> 'recipe';
    if not found or (l->>'counted') is null then continue; end if;
    select coalesce(sum(qty), 0) into v_onhand from stock_movements where item_id = it.id and branch_id = p_branch;
    v_diff := (l->>'counted')::numeric - v_onhand;
    if v_diff = 0 then continue; end if;
    insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
    values (v_tenant, p_branch, it.id, v_diff, 'count', v_ref, it.cost, coalesce(p_note, 'Stock count'), auth.uid());
    if v_diff > 0 then v_plus := v_plus + round(v_diff * it.cost); else v_minus := v_minus + round(-v_diff * it.cost); end if;
    n := n + 1;
  end loop;
  perform _post(v_tenant, p_branch, 'stock_count', v_ref, coalesce(p_note, 'Stock count'), jsonb_build_array(
    jsonb_build_object('key','inventory','debit', v_plus), jsonb_build_object('key','inventory_adjustments','credit', v_plus),
    jsonb_build_object('key','inventory_adjustments','debit', v_minus), jsonb_build_object('key','inventory','credit', v_minus)));
  if n > 0 then perform _audit(v_tenant, p_branch, 'inventory.count', 'branch', p_branch, v_minus - v_plus, p_note, null, jsonb_build_object('lines', n)); end if;
  return jsonb_build_object('adjusted_lines', n, 'gain', v_plus, 'loss', v_minus);
end $$;

-- ================================================================ delivery platforms
alter type public.tender_type add value if not exists 'platform';
insert into public.coa_template(system_key, code, name_en, name_ar, type, section) values
  ('platform_clearing', '1060', 'Delivery platforms receivable', 'مستحقات منصات التوصيل', 'asset', 'current_asset'),
  ('exp_platform_fees', '6350', 'Delivery platform commissions', 'عمولات منصات التوصيل', 'expense', 'operating_expense')
on conflict (system_key) do nothing;
insert into public.accounts(tenant_id, code, name_en, name_ar, type, system_key)
select t.id, c.code, c.name_en, c.name_ar, c.type, c.system_key from public.tenants t cross join public.coa_template c
 where c.system_key in ('platform_clearing','exp_platform_fees')
on conflict do nothing;

create or replace function public._tender_account(p_tender public.tender_type) returns text
language sql immutable as $$
  select case p_tender::text
    when 'cash' then 'cash' when 'card' then 'card_clearing' when 'bank_transfer' then 'bank' when 'store_credit' then 'store_credit'
    when 'on_account' then 'ar' when 'payment_link' then 'ar' when 'platform' then 'platform_clearing' else 'other_clearing' end;
$$;

create table public.delivery_channels (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  branch_id       uuid not null references public.branches(id) on delete cascade,
  platform        text not null check (platform in ('keeta','talabat','jahez','hungerstation','deliveroo','careem','noon_food','mrsool','toyou','other')),
  display_name    text not null,
  store_ref       text,                        -- the store id on the platform
  is_active       boolean not null default true,
  auto_accept     boolean not null default true,
  prep_minutes    integer not null default 15,
  commission_pct  numeric(5,2) not null default 0,
  webhook_token_hash text,                     -- inbound orders authenticate with this token
  created_at      timestamptz not null default now(),
  unique (branch_id, platform)
);
alter table public.delivery_channels enable row level security;
create policy dc_read on public.delivery_channels for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy dc_write on public.delivery_channels for all to authenticated
  using (public.has_perm(tenant_id, 'settings.manage')) with check (public.has_perm(tenant_id, 'settings.manage'));

alter table public.sales add column channel_id uuid references public.delivery_channels(id);
alter table public.sales add column external_ref text;
create unique index sales_channel_ext_uq on public.sales(channel_id, external_ref) where external_ref is not null;

create table public.platform_settlements (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  channel_id  uuid not null references public.delivery_channels(id),
  period_from date, period_to date,
  gross       bigint not null check (gross >= 0),
  commission  bigint not null check (commission >= 0),
  net         bigint not null,
  reference   text,
  entry_id    bigint references public.journal_entries(id),
  created_by  uuid not null,
  created_at  timestamptz not null default now()
);
alter table public.platform_settlements enable row level security;
create policy ps_read on public.platform_settlements for select to authenticated using (public.has_perm(tenant_id, 'finance.view'));
revoke insert, update, delete on public.platform_settlements from anon, authenticated;

-- the token is returned once (to paste into the platform's webhook settings or the integration partner)
create or replace function public.rotate_channel_token(p_channel uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare c delivery_channels%rowtype; v_token text := 'ztd_' || encode(gen_random_bytes(24), 'hex');
begin
  select * into c from delivery_channels where id = p_channel;
  if not found then raise exception 'channel not found'; end if;
  perform _require(c.tenant_id, 'settings.manage', null, null);
  update delivery_channels set webhook_token_hash = encode(digest(v_token, 'sha256'), 'hex') where id = c.id;
  return v_token;
end $$;

-- Normalised order from any platform adapter:
-- { external_ref, customer_name?, customer_phone?, note?, items:[{item_id? | sku? | name, qty, unit_price, note?}], total? }
-- Idempotent on (channel, external_ref). Creates the sale (tender = platform) and kitchen tickets.
create or replace function public.ingest_delivery_order(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c delivery_channels%rowtype; v_sale uuid; v_lines jsonb := '[]'; l jsonb; it items%rowtype; v_total bigint := 0; v_res jsonb; v_owner uuid;
begin
  select * into c from delivery_channels where webhook_token_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex') and is_active;
  if not found then raise exception 'invalid channel token' using errcode = '42501'; end if;
  if coalesce(p->>'external_ref','') = '' then raise exception 'external_ref required'; end if;
  select id into v_sale from sales where channel_id = c.id and external_ref = p->>'external_ref';
  if v_sale is not null then return jsonb_build_object('sale_id', v_sale, 'duplicate', true); end if;

  for l in select * from jsonb_array_elements(coalesce(p->'items','[]')) loop
    it := null;
    select * into it from items i where i.tenant_id = c.tenant_id and i.item_type <> 'ingredient'
       and (i.id = nullif(l->>'item_id','')::uuid or (l->>'sku' is not null and i.sku = l->>'sku') or lower(i.name) = lower(l->>'name')) limit 1;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'name', coalesce(it.name, l->>'name'), 'qty', (l->>'qty')::numeric,
                                             'unit_price', (l->>'unit_price')::bigint, 'note', l->>'note');
    v_total := v_total + round((l->>'qty')::numeric * (l->>'unit_price')::bigint);
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'order has no items'; end if;

  -- the platform order is booked by the system on behalf of the business owner (audited as such)
  select user_id into v_owner from memberships where tenant_id = c.tenant_id and role = 'owner' limit 1;
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  v_res := complete_sale(jsonb_build_object(
    'tenant_id', c.tenant_id, 'branch_id', c.branch_id, 'client_id', gen_random_uuid(), 'note', p->>'note',
    'kitchen', jsonb_build_object('order_type', 'delivery', 'customer_name', coalesce(p->>'customer_name', c.display_name)),
    'lines', v_lines, 'payments', jsonb_build_array(jsonb_build_object('tender', 'platform', 'amount', v_total, 'reference', c.platform || ':' || (p->>'external_ref')))));
  update sales set channel_id = c.id, external_ref = p->>'external_ref' where id = (v_res->>'id')::uuid;
  perform _audit(c.tenant_id, c.branch_id, 'delivery.order', 'sale', (v_res->>'id')::uuid, v_total, c.platform || ' ' || (p->>'external_ref'), null);
  return jsonb_build_object('sale_id', v_res->>'id', 'number', v_res->>'number', 'total', v_total, 'prep_minutes', c.prep_minutes);
end $$;

-- platform pays out: gross sales less commission. Dr bank (net), Dr commission expense, Cr platform receivable (gross)
create or replace function public.record_platform_settlement(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare c delivery_channels%rowtype; v_id uuid := gen_random_uuid(); v_gross bigint := (p->>'gross')::bigint; v_comm bigint := (p->>'commission')::bigint; v_entry bigint;
begin
  select * into c from delivery_channels where id = (p->>'channel_id')::uuid;
  if not found then raise exception 'channel not found'; end if;
  perform _require(c.tenant_id, 'payments.receive', null, null);
  if v_gross <= 0 or v_comm < 0 or v_comm > v_gross then raise exception 'check the amounts' using errcode = 'ZT422'; end if;
  v_entry := _post_ex(c.tenant_id, c.branch_id, 'platform_settlement', v_id, c.display_name || ' settlement', jsonb_build_array(
      jsonb_build_object('key','bank','debit', v_gross - v_comm),
      jsonb_build_object('key','exp_platform_fees','debit', v_comm),
      jsonb_build_object('key','platform_clearing','credit', v_gross)), current_date, nullif(p->>'reference',''));
  insert into platform_settlements(id, tenant_id, channel_id, period_from, period_to, gross, commission, net, reference, entry_id, created_by)
  values (v_id, c.tenant_id, c.id, nullif(p->>'period_from','')::date, nullif(p->>'period_to','')::date, v_gross, v_comm, v_gross - v_comm,
          nullif(p->>'reference',''), v_entry, auth.uid());
  perform _audit(c.tenant_id, c.branch_id, 'delivery.settlement', 'channel', c.id, v_gross, p->>'reference', null);
  return v_id;
end $$;

create or replace view public.v_channel_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day, coalesce(dc.display_name, 'In store') as channel, dc.platform,
       count(*) filter (where s.doc_type = 'invoice') as orders,
       coalesce(sum(case when s.doc_type = 'invoice' then s.total else -s.total end), 0) as net_sales
  from public.sales s join public.branches b on b.id = s.branch_id left join public.delivery_channels dc on dc.id = s.channel_id
 group by 1, 2, 3, 4, 5;
grant select on public.v_channel_sales to authenticated;

grant execute on function public.recipe_cost(uuid), public.stock_card(uuid,uuid,date,date), public.post_stock_count(uuid,jsonb,text),
  public.rotate_channel_token(uuid), public.record_platform_settlement(jsonb) to authenticated;
grant execute on function public.ingest_delivery_order(text, jsonb) to anon, authenticated, service_role;
revoke execute on function public._consume_recipes(uuid), public._tender_account(public.tender_type) from public, anon, authenticated;

-- ================================================================ kitchen timing: report and live monitoring
-- managers/owners with report access can read kitchen tickets for performance reports
create policy kt_read_reports on public.kitchen_tickets for select to authenticated using (public.has_perm(tenant_id, 'reports.all'));
create policy kti_read_reports on public.kitchen_ticket_items for select to authenticated
  using (exists (select 1 from public.kitchen_tickets k where k.id = ticket_id and public.has_perm(k.tenant_id, 'reports.all')));

-- seconds per stage: waiting (received → started), preparing (started → ready), total (received → ready), pickup (ready → served)
create or replace view public.v_kitchen_times with (security_invoker = true) as
select k.id, k.tenant_id, k.branch_id, k.station_id, s.name as station, s.alert_minutes, k.order_ref, k.order_type, k.status, k.source,
       k.created_at, (k.created_at at time zone b.timezone)::date as day, extract(hour from k.created_at at time zone b.timezone)::int as hour,
       extract(epoch from (coalesce(k.started_at, k.ready_at) - k.created_at))::int as wait_s,
       extract(epoch from (k.ready_at - coalesce(k.started_at, k.created_at)))::int as prep_s,
       extract(epoch from (k.ready_at - k.created_at))::int as total_s,
       extract(epoch from (k.served_at - k.ready_at))::int as pickup_s,
       (k.ready_at is not null and k.ready_at - k.created_at > make_interval(mins => s.alert_minutes)) as late,
       (select count(*) from public.kitchen_ticket_items i where i.ticket_id = k.id) as item_lines,
       (select coalesce(sum(i.qty), 0) from public.kitchen_ticket_items i where i.ticket_id = k.id) as item_qty
  from public.kitchen_tickets k join public.kitchen_stations s on s.id = k.station_id join public.branches b on b.id = k.branch_id;
grant select on public.v_kitchen_times to authenticated;

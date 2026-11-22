-- Z Trust · restaurants (Foodics-level) and retail (Dynamics 365 Commerce-level) features
--   discounts: quantity tiers and spend thresholds (mix-and-match "cheapest free" is the existing buy X get Y)
--   loyalty tiers (earning multiplier by spend in the last 12 months), punch cards (buy N, the reward is free)
--   coursing (later courses held in the kitchen until fired), delivery zones (fee + minimum order)
--   digital receipt link, brands (multi-brand / cloud kitchen), clienteling (birthday, tags, notes), store checklists

-- ================================================================ discounts
alter table public.promotions drop constraint if exists promotions_kind_check;
alter table public.promotions add constraint promotions_kind_check check (kind in ('percent','amount','bxgy','bundle','qty_tier','threshold'));

-- ================================================================ loyalty tiers
create table public.loyalty_tiers (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  name            text not null,
  name_ar         text,
  min_spend       bigint not null default 0,      -- net purchases in the last 12 months
  earn_multiplier numeric(5,2) not null default 1 check (earn_multiplier > 0),
  color           text
);
alter table public.loyalty_tiers enable row level security;
create policy lt_read on public.loyalty_tiers for select using (is_member(tenant_id));
create policy lt_write on public.loyalty_tiers for all using (has_perm(tenant_id, 'catalog.manage')) with check (has_perm(tenant_id, 'catalog.manage'));
grant select, insert, update, delete on public.loyalty_tiers to authenticated;

create or replace function public.customer_tier(p_customer uuid)
returns table(id uuid, name text, name_ar text, earn_multiplier numeric, spend bigint, next_name text, next_min bigint)
language sql stable security definer set search_path = public as $$
  with c as (select c.id, c.tenant_id from customers c where c.id = p_customer and is_member(c.tenant_id)),
  s as (select coalesce(sum(case when x.doc_type = 'invoice' then x.total else -x.total end), 0)::bigint spend
          from sales x join c on x.customer_id = c.id where x.created_at > now() - interval '12 months' and x.status <> 'cancelled')
  select t.id, t.name, t.name_ar, t.earn_multiplier, s.spend,
         (select n.name from loyalty_tiers n join c on n.tenant_id = c.tenant_id where n.min_spend > s.spend order by n.min_spend limit 1),
         (select n.min_spend from loyalty_tiers n join c on n.tenant_id = c.tenant_id where n.min_spend > s.spend order by n.min_spend limit 1)
    from s left join lateral (select lt.* from loyalty_tiers lt join c on lt.tenant_id = c.tenant_id where lt.min_spend <= s.spend order by lt.min_spend desc limit 1) t on true;
$$;
grant execute on function public.customer_tier(uuid) to authenticated;

-- ================================================================ punch cards
create table public.punch_programs (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  name           text not null,
  name_ar        text,
  item_ids       uuid[],
  category_ids   uuid[],
  punches_needed int not null check (punches_needed between 2 and 100),
  reward_item_id uuid not null references public.items(id),
  is_active      boolean not null default true
);
create table public.punch_moves (
  id         bigint generated always as identity primary key,
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  program_id uuid not null references public.punch_programs(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  sale_id    uuid references public.sales(id),
  punches    int not null,
  created_at timestamptz not null default now()
);
create index on public.punch_moves(customer_id, program_id);
alter table public.punch_programs enable row level security;
alter table public.punch_moves enable row level security;
create policy pp_read on public.punch_programs for select using (is_member(tenant_id));
create policy pp_write on public.punch_programs for all using (has_perm(tenant_id, 'catalog.manage')) with check (has_perm(tenant_id, 'catalog.manage'));
create policy pm_read on public.punch_moves for select using (is_member(tenant_id));
grant select, insert, update, delete on public.punch_programs to authenticated;
grant select on public.punch_moves to authenticated;

create or replace function public.customer_punches(p_customer uuid)
returns table(program_id uuid, name text, name_ar text, punches bigint, punches_needed int, reward_item_id uuid)
language sql stable security definer set search_path = public as $$
  select pp.id, pp.name, pp.name_ar, coalesce((select sum(m.punches) from punch_moves m where m.program_id = pp.id and m.customer_id = p_customer), 0),
         pp.punches_needed, pp.reward_item_id
    from punch_programs pp join customers c on c.tenant_id = pp.tenant_id
   where c.id = p_customer and pp.is_active and is_member(c.tenant_id);
$$;
grant execute on function public.customer_punches(uuid) to authenticated;

/** After a sale: redeem the rewards claimed (checking the balance) and earn one punch per qualifying unit. */
create or replace function public._punch_apply(p_tenant uuid, p_sale uuid, p_customer uuid, p_lines jsonb, p_used jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare u jsonb; pp punch_programs%rowtype; v_have bigint; v_earn numeric;
begin
  for u in select * from jsonb_array_elements(p_used) loop
    select * into pp from punch_programs where id = (u->>'program')::uuid;
    select coalesce(sum(punches), 0) into v_have from punch_moves where program_id = pp.id and customer_id = p_customer;
    if v_have < pp.punches_needed * (u->>'qty')::numeric then raise exception 'not enough punches on the % card', pp.name using errcode = 'ZT422'; end if;
    insert into punch_moves(tenant_id, program_id, customer_id, sale_id, punches) values (p_tenant, pp.id, p_customer, p_sale, -(pp.punches_needed * (u->>'qty')::numeric)::int);
  end loop;
  if p_customer is null then return; end if;
  for pp in select * from punch_programs where tenant_id = p_tenant and is_active loop
    select coalesce(sum(floor((x->>'qty')::numeric)), 0) into v_earn
      from jsonb_array_elements(p_lines) x left join items i on i.id = (x->>'item_id')::uuid
     where x->>'punch_program_id' is null and i.id is not null
       and (i.id = any(coalesce(pp.item_ids, '{}')) or i.parent_id = any(coalesce(pp.item_ids, '{}')) or i.category_id = any(coalesce(pp.category_ids, '{}')));
    if v_earn > 0 then insert into punch_moves(tenant_id, program_id, customer_id, sale_id, punches) values (p_tenant, pp.id, p_customer, p_sale, v_earn::int); end if;
  end loop;
end $$;
revoke execute on function public._punch_apply(uuid, uuid, uuid, jsonb, jsonb) from public, anon, authenticated;

-- ================================================================ coursing
alter table public.items add column if not exists course smallint check (course between 1 and 5);
alter table public.kitchen_ticket_items add column if not exists course smallint;
alter table public.kitchen_ticket_items add column if not exists held boolean not null default false;

/** Fire the next course of an order: its held items appear on the kitchen screens. */
create or replace function public.fire_course(p_branch uuid, p_order_ref text, p_course smallint) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int; v_tenant uuid := (select tenant_id from branches where id = p_branch);
begin
  if not can_see_branch(v_tenant, p_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  if not (has_perm(v_tenant, 'kds.bump') or has_perm(v_tenant, 'sale.create')) then raise exception 'not allowed' using errcode = '42501'; end if;
  update kitchen_ticket_items i set held = false from kitchen_tickets k
   where k.id = i.ticket_id and k.branch_id = p_branch and k.order_ref = p_order_ref and i.course = p_course and i.held;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.fire_course(uuid, text, smallint) to authenticated;

-- ================================================================ delivery zones
create table public.delivery_zones (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  branch_id  uuid references public.branches(id),
  name       text not null,
  name_ar    text,
  fee        bigint not null default 0 check (fee >= 0),
  min_order  bigint not null default 0 check (min_order >= 0),
  eta_min    int,
  is_active  boolean not null default true
);
alter table public.delivery_zones enable row level security;
create policy dz_read on public.delivery_zones for select using (is_member(tenant_id));
create policy dz_write on public.delivery_zones for all using (has_perm(tenant_id, 'settings.manage') or my_role(tenant_id) = 'owner') with check (has_perm(tenant_id, 'settings.manage') or my_role(tenant_id) = 'owner');
grant select, insert, update, delete on public.delivery_zones to authenticated;
alter table public.deliveries add column if not exists zone_id uuid references public.delivery_zones(id);
alter table public.deliveries add column if not exists fee bigint not null default 0;

-- ================================================================ digital receipts
alter table public.sales add column if not exists public_token uuid not null default gen_random_uuid();
create unique index if not exists sales_public_token on public.sales(public_token);
/** The receipt behind a link or QR (no login): business name and logo, lines, totals, payments. */
create or replace function public.receipt_public(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('number', s.number, 'doc_type', s.doc_type, 'created_at', s.created_at, 'subtotal', s.subtotal, 'tax_total', s.tax_total,
           'total', s.total, 'discount_total', s.discount_total, 'note', s.reason,
           'lines', (select coalesce(jsonb_agg(jsonb_build_object('name', l.name, 'qty', l.qty, 'line_total', l.line_total) order by l.name), '[]') from sale_lines l where l.sale_id = s.id),
           'payments', (select coalesce(jsonb_agg(jsonb_build_object('tender', p.tender, 'amount', p.amount, 'method', p.method, 'status', p.status)), '[]') from payments p where p.sale_id = s.id),
           'tenant', jsonb_build_object('name', t.name, 'name_ar', t.name_ar, 'tax_number', t.tax_number, 'logo_url', t.logo_url, 'currency', t.currency,
                                        'currency_decimals', t.currency_decimals, 'country_code', t.country_code, 'settings', t.settings - 'hr_annual_leave_days'),
           'branch', jsonb_build_object('name', b.name, 'name_ar', b.name_ar, 'address', b.address))
    from sales s join tenants t on t.id = s.tenant_id join branches b on b.id = s.branch_id where s.public_token = p_token;
$$;
revoke execute on function public.receipt_public(uuid) from public;
grant execute on function public.receipt_public(uuid) to anon, authenticated;

-- ================================================================ brands (multi-brand / cloud kitchen)
create table public.brands (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name      text not null,
  name_ar   text,
  logo_url  text,
  is_active boolean not null default true
);
alter table public.brands enable row level security;
create policy br_read on public.brands for select using (is_member(tenant_id));
create policy br_write on public.brands for all using (has_perm(tenant_id, 'catalog.manage')) with check (has_perm(tenant_id, 'catalog.manage'));
grant select, insert, update, delete on public.brands to authenticated;
alter table public.items add column if not exists brand_id uuid references public.brands(id) on delete set null;

-- ================================================================ clienteling
alter table public.customers add column if not exists birthday date;
alter table public.customers add column if not exists tags text[];
alter table public.customers add column if not exists preferences text;
create table public.customer_notes (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  note        text not null,
  follow_up   date,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
alter table public.customer_notes enable row level security;
create policy cn_read on public.customer_notes for select using (is_member(tenant_id));
create policy cn_write on public.customer_notes for insert with check (is_member(tenant_id) and (has_perm(tenant_id, 'customers.manage') or has_perm(tenant_id, 'sale.create')));
grant select, insert on public.customer_notes to authenticated;

-- ================================================================ store checklists (opening / closing / custom)
create table public.checklists (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name      text not null,
  name_ar   text,
  items     text[] not null,
  is_active boolean not null default true
);
create table public.checklist_runs (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  branch_id    uuid not null references public.branches(id),
  checklist_id uuid not null references public.checklists(id) on delete cascade,
  run_date     date not null,
  done         jsonb not null default '{}',       -- item index → {by, at}
  completed_at timestamptz,
  unique (checklist_id, branch_id, run_date)
);
alter table public.checklists enable row level security;
alter table public.checklist_runs enable row level security;
create policy ck_read on public.checklists for select using (is_member(tenant_id));
create policy ck_write on public.checklists for all using (has_perm(tenant_id, 'settings.manage') or my_role(tenant_id) = 'owner') with check (has_perm(tenant_id, 'settings.manage') or my_role(tenant_id) = 'owner');
create policy cr_read on public.checklist_runs for select using (can_see_branch(tenant_id, branch_id));
grant select, insert, update, delete on public.checklists to authenticated;
grant select on public.checklist_runs to authenticated;

/** Tick (or untick) one item of today's checklist for this branch. */
create or replace function public.tick_checklist(p_checklist uuid, p_branch uuid, p_index int, p_done boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c checklists%rowtype; r checklist_runs%rowtype; v_day date;
begin
  select * into c from checklists where id = p_checklist;
  if not found or not can_see_branch(c.tenant_id, p_branch) then raise exception 'not allowed' using errcode = '42501'; end if;
  v_day := _today(c.tenant_id, p_branch);
  insert into checklist_runs(tenant_id, branch_id, checklist_id, run_date) values (c.tenant_id, p_branch, c.id, v_day)
  on conflict (checklist_id, branch_id, run_date) do nothing;
  update checklist_runs set done = case when p_done then done || jsonb_build_object(p_index::text, jsonb_build_object('by', (select display_name from memberships where tenant_id = c.tenant_id and user_id = auth.uid()), 'at', now()))
                                        else done - p_index::text end
   where checklist_id = c.id and branch_id = p_branch and run_date = v_day returning * into r;
  update checklist_runs set completed_at = case when (select count(*) from jsonb_object_keys(r.done)) >= array_length(c.items, 1) then now() end where id = r.id returning * into r;
  return to_jsonb(r);
end $$;
grant execute on function public.tick_checklist(uuid, uuid, int, boolean) to authenticated;

-- ================================================================ re-issued: checkout (tiers, punch cards, delivery zones), promotions engine, kitchen tickets (courses)
CREATE OR REPLACE FUNCTION public.complete_sale(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
  v_punch jsonb := '[]'; v_mult numeric := 1; v_zone delivery_zones%rowtype;
  v_override boolean := false; v_cashsum bigint := 0; v_slid uuid; v_ser text[]; v_n int;
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
              'gross', round((l->>'qty')::numeric * coalesce((l->>'unit_price')::bigint, coalesce(_list_price(t.id, v_customer, it.id), it.price, 0) + v_mod_add)));
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
    v_list_price := coalesce(_list_price(t.id, v_customer, it.id), it.price, 0) + v_mod_add;
    v_price := coalesce((l->>'unit_price')::bigint, v_list_price);
    -- a typed price on a catalogue item is a price change (gift cards and open items are priced at the till)
    if it.id is not null and it.item_type <> 'gift_card' and v_price <> v_list_price then v_override := true; end if;
    -- serial / IMEI: one in-stock number per unit
    v_ser := null;
    if coalesce(it.track_serial, false) then
      v_ser := array(select upper(trim(x)) from jsonb_array_elements_text(case when jsonb_typeof(l->'serials') = 'array' then l->'serials' else '[]'::jsonb end) x where trim(x) <> '');
      if v_qty <> floor(v_qty) or coalesce(array_length(v_ser, 1), 0) <> v_qty or (select count(distinct x) from unnest(v_ser) x) <> v_qty then
        raise exception 'scan one serial number per unit of %', it.name using errcode = 'ZT422'; end if;
      if (select count(*) from item_serials where tenant_id = t.id and item_id = it.id and status = 'in_stock' and upper(serial) = any(v_ser)) <> v_qty then
        raise exception 'serial number not in stock for %', it.name using errcode = 'ZT422'; end if;
    end if;
    v_disc  := coalesce((l->>'discount')::bigint, 0);
    if v_price < 0 or v_disc < 0 then raise exception 'negative price or discount'; end if;
    -- promotion: what the POS claims, capped at what the rules allow for this line
    v_promo := least(greatest(coalesce((l->>'promo_discount')::bigint, 0), 0),
                     coalesce((select (x->>'discount')::bigint from jsonb_array_elements(v_allow) x where (x->>'idx')::int = v_idx), 0));
    v_rate  := coalesce(it.tax_rate, t.vat_rate);
    -- a gift card is a voucher for later purchases: no VAT now, the money is owed to the holder
    if it.item_type = 'gift_card' then v_rate := 0; v_promo := 0; end if;
    -- punch-card reward: the whole line is free; the punches are checked and used after pricing
    if nullif(l->>'punch_program_id','') is not null then
      if v_customer is null then raise exception 'choose the customer whose card is used' using errcode = 'ZT422'; end if;
      if not exists (select 1 from punch_programs pp where pp.id = (l->>'punch_program_id')::uuid and pp.tenant_id = t.id and pp.is_active and pp.reward_item_id = it.id) then
        raise exception 'this item is not the reward of that card' using errcode = 'ZT422'; end if;
      v_promo := round(v_qty * v_price)::bigint - v_disc;
      v_punch := v_punch || jsonb_build_object('program', l->>'punch_program_id', 'qty', v_qty);
    end if;

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
      'promo_discount', v_promo, 'customer_package_id', cp.id, 'pkg_value', v_pkg_value, 'gift_code', nullif(upper(trim(l->>'gift_code')),''), 'serials', to_jsonb(v_ser), 'warranty', it.warranty_months, 'punch_program_id', nullif(l->>'punch_program_id',''));
  end loop;

  -- ---- manual discount / price override approval (promotions and package sessions need none)
  if v_manual > 0 then
    v_appr := _require(t.id, 'sale.discount', round(v_manual * 100.0 / nullif(v_list,0), 2), p->>'approver_pin');
  end if;

  if v_override then
    v_appr := coalesce(_require(t.id, 'sale.price', null, p->>'approver_pin'), v_appr);
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
    if v_tender = 'cash' then v_cashsum := v_cashsum + v_amt; end if;
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
  -- cash ceiling per invoice (a setting: off / warn on the till / block here)
  if coalesce(t.settings->>'cash_limit_mode', 'off') = 'block' and coalesce((t.settings->>'cash_limit')::bigint, 0) > 0
     and v_cashsum > (t.settings->>'cash_limit')::bigint then
    raise exception 'CASH_LIMIT: cash above % is not accepted on one invoice; use card or K-Net for the rest', (t.settings->>'cash_limit') using errcode = 'ZT422'; end if;
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
            nullif(l->>'promo_id','')::uuid, (l->>'promo_discount')::bigint, nullif(l->>'customer_package_id','')::uuid)
    returning id into v_slid;
    if jsonb_typeof(l->'serials') = 'array' then
      update item_serials set status = 'sold', sale_id = v_sale, sale_line_id = v_slid, sold_at = now(), branch_id = v_branch,
             warranty_until = case when (l->>'warranty')::int > 0 then current_date + make_interval(months => (l->>'warranty')::int) end
       where tenant_id = t.id and item_id = (l->>'item_id')::uuid and status = 'in_stock'
         and upper(serial) in (select jsonb_array_elements_text(l->'serials'));
    end if;
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
    -- loyalty tier (silver, gold…) multiplies the points earned
    v_mult := coalesce((select earn_multiplier from customer_tier(v_customer)), 1);
    v_points := floor(v_earn_base / (10 ^ t.currency_decimals) * (t.settings->>'loyalty_earn')::numeric * v_mult);
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

  -- a quotation, sales order or delivery note invoiced from the till
  if nullif(p->>'sales_doc_id','') is not null then
    update sales_docs set status = 'invoiced', sale_id = v_sale, updated_at = now()
     where tenant_id = t.id and status not in ('invoiced','cancelled','rejected')
       and (id = (p->>'sales_doc_id')::uuid or id = (select source_id from sales_docs where id = (p->>'sales_doc_id')::uuid));
  end if;

  if nullif(p->>'online_order_id','') is not null then
    update online_orders set status = 'paid', sale_id = v_sale where id = (p->>'online_order_id')::uuid and tenant_id = t.id and status in ('pending','accepted');
  end if;
  -- own delivery: the order goes to a driver; cash on delivery is collected by the driver
  if jsonb_typeof(p->'delivery') = 'object' then
    perform _require_feature(t.id, 'own_delivery');
    -- delivery zone: minimum order (before the fee line)
    if nullif(p->'delivery'->>'zone_id','') is not null then
      select * into v_zone from delivery_zones where id = (p->'delivery'->>'zone_id')::uuid and tenant_id = t.id and is_active;
      if not found then raise exception 'unknown delivery zone' using errcode = 'ZT422'; end if;
      if v_total - v_zone.fee < v_zone.min_order then raise exception 'the minimum order for % is %', v_zone.name, v_zone.min_order using errcode = 'ZT422'; end if;
    end if;
    insert into deliveries(tenant_id, branch_id, sale_id, customer_id, address, phone, note, driver_id, status, cash_to_collect, assigned_at)
    values (t.id, v_branch, v_sale, v_customer, coalesce(nullif(p->'delivery'->>'address',''), (select address from customers where id = v_customer)),
            coalesce(nullif(p->'delivery'->>'phone',''), (select phone from customers where id = v_customer)), nullif(p->'delivery'->>'note',''),
            nullif(p->'delivery'->>'driver_id','')::uuid, case when nullif(p->'delivery'->>'driver_id','') is not null then 'assigned' else 'pending' end, v_cod,
            case when nullif(p->'delivery'->>'driver_id','') is not null then now() end);
    update deliveries set zone_id = v_zone.id, fee = coalesce(v_zone.fee, 0) where sale_id = v_sale and v_zone.id is not null;
  end if;

  perform _punch_apply(t.id, v_sale, v_customer, v_lines, v_punch);
  perform _consume_recipes(v_sale);
  if nullif(p->>'open_order_id','') is null then perform _kitchen_from_sale(v_sale, p); end if;
  return sale_json(v_sale);
end $function$;

CREATE OR REPLACE FUNCTION public.promo_allowance(p_tenant uuid, p_at timestamp with time zone, p_lines jsonb, p_coupon text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  pr promotions%rowtype; v_tz text; v_local timestamp; best jsonb := '{}'; d jsonb; l jsonb; c jsonb;
  v_q numeric; v_sum bigint; v_disc bigint; v_sets numeric; v_set_value bigint; v_share bigint; v_given bigint;
  v_units jsonb; v_chunk int; v_i int; v_n int; u jsonb;
begin
  select b.timezone into v_tz from branches b where b.tenant_id = p_tenant order by code limit 1;
  v_local := p_at at time zone coalesce(v_tz, 'UTC');
  for pr in select * from promotions where tenant_id = p_tenant and is_active
      and (starts_on is null or v_local::date >= starts_on) and (ends_on is null or v_local::date <= ends_on)
      and (weekdays is null or extract(isodow from v_local)::int = any(weekdays))
      and (time_from is null or v_local::time >= time_from) and (time_to is null or v_local::time < time_to)
      and (coupon_code is null or upper(coupon_code) = upper(coalesce(p_coupon, '')))
  loop
    d := '{}';   -- idx → discount for this promotion
    -- qualifying lines
    with q as (
      select (x->>'idx')::int idx, (x->>'item_id')::uuid item_id, (x->>'qty')::numeric qty, (x->>'gross')::bigint gross, i.category_id, i.parent_id
        from jsonb_array_elements(p_lines) x left join items i on i.id = (x->>'item_id')::uuid
       where pr.kind = 'bundle'
          or (pr.item_ids is null and pr.category_ids is null)
          or (x->>'item_id')::uuid = any(coalesce(pr.item_ids, '{}')) or i.parent_id = any(coalesce(pr.item_ids, '{}'))
          or i.category_id = any(coalesce(pr.category_ids, '{}')))
    select jsonb_agg(jsonb_build_object('idx', idx, 'item_id', item_id, 'qty', qty, 'gross', gross)) into l from q;
    if l is null then continue; end if;
    select coalesce(sum((x->>'qty')::numeric), 0), coalesce(sum((x->>'gross')::bigint), 0) into v_q, v_sum from jsonb_array_elements(l) x;
    if pr.kind <> 'bundle' and v_q < pr.min_qty then continue; end if;

    if pr.kind = 'percent' then
      select jsonb_object_agg(x->>'idx', round((x->>'gross')::bigint * (pr.params->>'percent')::numeric / 100)) into d from jsonb_array_elements(l) x;
    elsif pr.kind = 'amount' then
      if v_sum <= 0 or v_sum < coalesce((pr.params->>'min_amount')::bigint, 0) then continue; end if;
      v_disc := least((pr.params->>'amount')::bigint, v_sum); v_given := 0; v_n := jsonb_array_length(l); v_i := 0;
      for c in select x from jsonb_array_elements(l) x order by (x->>'idx')::int loop
        v_i := v_i + 1;
        v_share := case when v_i = v_n then v_disc - v_given else round(v_disc * (c->>'gross')::bigint / v_sum::numeric) end;
        v_given := v_given + v_share; d := d || jsonb_build_object(c->>'idx', v_share);
      end loop;
    elsif pr.kind = 'bxgy' then
      -- whole units, dearest first; in every group of buy+get units the cheapest "get" units are discounted
      select jsonb_agg(jsonb_build_object('idx', x->>'idx', 'unit', round((x->>'gross')::bigint / (x->>'qty')::numeric)) order by (x->>'gross')::bigint / (x->>'qty')::numeric desc, (x->>'idx')::int)
        into v_units from jsonb_array_elements(l) x cross join generate_series(1, floor((x->>'qty')::numeric)::int);
      v_chunk := (pr.params->>'buy')::int + (pr.params->>'get')::int;
      v_n := coalesce(jsonb_array_length(v_units), 0);
      for v_i in 0 .. (v_n / v_chunk) * v_chunk - 1 loop
        if v_i % v_chunk >= (pr.params->>'buy')::int then
          u := v_units -> v_i;
          d := d || jsonb_build_object(u->>'idx', coalesce((d->>(u->>'idx'))::bigint, 0) + round((u->>'unit')::bigint * coalesce((pr.params->>'percent')::numeric, 100) / 100));
        end if;
      end loop;
    elsif pr.kind = 'qty_tier' then
      -- quantity tiers on the qualifying lines together: the highest tier reached applies to all of them
      select (x->>'percent')::numeric into v_share from jsonb_array_elements(pr.params->'tiers') x
       where (x->>'qty')::numeric <= v_q order by (x->>'qty')::numeric desc limit 1;
      if v_share is null then continue; end if;
      select jsonb_object_agg(x->>'idx', round((x->>'gross')::bigint * v_share / 100)) into d from jsonb_array_elements(l) x;
    elsif pr.kind = 'threshold' then
      -- spend thresholds on the qualifying lines: the highest threshold reached gives % or an amount, spread by value
      select x into c from jsonb_array_elements(pr.params->'tiers') x where (x->>'min')::bigint <= v_sum order by (x->>'min')::bigint desc limit 1;
      if c is null or v_sum <= 0 then continue; end if;
      v_disc := least(case when c ? 'percent' then round(v_sum * (c->>'percent')::numeric / 100) else coalesce((c->>'amount')::bigint, 0) end, v_sum);
      v_given := 0; v_n := jsonb_array_length(l); v_i := 0;
      for c in select x from jsonb_array_elements(l) x order by (x->>'idx')::int loop
        v_i := v_i + 1;
        v_share := case when v_i = v_n then v_disc - v_given else round(v_disc * (c->>'gross')::bigint / v_sum::numeric) end;
        v_given := v_given + v_share; d := d || jsonb_build_object(c->>'idx', v_share);
      end loop;
    elsif pr.kind = 'bundle' then
      -- complete sets of the components; the saving is spread over the component lines by value
      v_sets := null; v_set_value := 0;
      for c in select * from jsonb_array_elements(pr.params->'components') loop
        select coalesce(sum((x->>'qty')::numeric), 0), coalesce(sum((x->>'gross')::bigint)::numeric / nullif(sum((x->>'qty')::numeric), 0), 0)
          into v_q, v_share from jsonb_array_elements(l) x where (x->>'item_id') = c->>'item_id';
        v_sets := least(coalesce(v_sets, 1e9), floor(v_q / (c->>'qty')::numeric));
        v_set_value := v_set_value + round(v_share * (c->>'qty')::numeric);
      end loop;
      if coalesce(v_sets, 0) < 1 or v_set_value <= (pr.params->>'price')::bigint then continue; end if;
      v_disc := round(v_sets * (v_set_value - (pr.params->>'price')::bigint)); v_given := 0;
      v_n := jsonb_array_length(pr.params->'components'); v_i := 0;
      for c in select * from jsonb_array_elements(pr.params->'components') loop
        v_i := v_i + 1;
        select min((x->>'idx')::int), coalesce(sum((x->>'gross')::bigint)::numeric / nullif(sum((x->>'qty')::numeric), 0), 0)
          into v_n, v_share from jsonb_array_elements(l) x where (x->>'item_id') = c->>'item_id';
        v_share := case when v_i = jsonb_array_length(pr.params->'components') then v_disc - v_given
                        else round(v_disc * v_share * (c->>'qty')::numeric / v_set_value) end;
        v_given := v_given + v_share;
        d := d || jsonb_build_object(v_n::text, coalesce((d->>v_n::text)::bigint, 0) + v_share);
      end loop;
    end if;

    -- keep the best promotion per line
    for c in select jsonb_build_object('k', key, 'v', value) from jsonb_each(coalesce(d, '{}')) loop
      if (c->>'v')::bigint > 0 and (c->>'v')::bigint > coalesce((best->(c->>'k')->>'discount')::bigint, 0) then
        best := best || jsonb_build_object(c->>'k', jsonb_build_object('idx', (c->>'k')::int, 'promo_id', pr.id, 'discount',
                  least((c->>'v')::bigint, (select (x->>'gross')::bigint from jsonb_array_elements(p_lines) x where x->>'idx' = c->>'k'))));
      end if;
    end loop;
  end loop;
  return coalesce((select jsonb_agg(value order by (value->>'idx')::int) from jsonb_each(best)), '[]');
end $function$;

CREATE OR REPLACE FUNCTION public._kitchen_from_lines(p_tenant uuid, p_branch uuid, p_order uuid, p_ref text, p_type text, p_table text, p_lines jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_default uuid; v_ticket uuid; n int := 0; v_first smallint;
begin
  if not has_feature(p_tenant, 'kitchen') or jsonb_array_length(p_lines) = 0 then return 0; end if;
  select id into v_default from kitchen_stations where branch_id = p_branch and is_active order by is_default desc, sort, name limit 1;
  if v_default is null then return 0; end if;
  -- coursing: later courses wait until the kitchen (or the waiter) fires them
  select min(i.course) into v_first from jsonb_array_elements(p_lines) x join items i on i.id = (x->>'item_id')::uuid where i.course is not null;
  for r in
    select coalesce(ks.id, v_default) as station_id,
           jsonb_agg(jsonb_build_object('name', x->>'name', 'name_ar', i.name_ar, 'qty', (x->>'qty')::numeric, 'note', x->>'note', 'course', i.course) order by i.course nulls first, x->>'name') as items
      from jsonb_array_elements(p_lines) x
      left join items i on i.id = (x->>'item_id')::uuid
      left join categories c on c.id = i.category_id
      left join kitchen_stations ks on ks.id = c.station_id and ks.is_active and ks.branch_id = p_branch
     group by 1
  loop
    insert into kitchen_tickets(tenant_id, branch_id, station_id, open_order_id, order_ref, order_type, table_no)
    values (p_tenant, p_branch, r.station_id, p_order, p_ref, p_type, p_table) returning id into v_ticket;
    insert into kitchen_ticket_items(tenant_id, ticket_id, name, name_ar, qty, note, course, held)
    select p_tenant, v_ticket, x->>'name', x->>'name_ar', (x->>'qty')::numeric, x->>'note', nullif(x->>'course','')::smallint,
           coalesce(nullif(x->>'course','')::smallint > v_first, false) from jsonb_array_elements(r.items) x;
    n := n + 1;
  end loop;
  return n;
end $function$;

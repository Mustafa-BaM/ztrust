-- Z Trust · more business types open, and: gift cards, reservations & waitlist, branch transfers & production,
-- QR table ordering & kiosk, own delivery with drivers, attendance by geofence; checkout v5.

-- ================================================================ business types
update public.business_profiles set launch = true where key in ('bakery','florist','spa','car_wash','gym');
insert into public.business_profiles(key, name_en, name_ar, family, pos_mode, launch, sort, modules) values
  ('hypermarket','Central market & co-op','سوق مركزي وجمعيات','retail','scan',true,6,
   '{"weighed":2,"batches":2,"promotions":2,"loyalty":2,"credit":2,"purchasing":2,"transfers":2,"gift_cards":1,"consignment":1,"own_delivery":1,"variants":1,"quotations":1,"attendance":1}')
on conflict (key) do nothing;

-- ================================================================ new modules
insert into public.feature_modules(key, name_en, name_ar, built, sort, universal) values
  ('gift_cards','Gift cards','بطاقات الهدايا', true, 30, true),
  ('reservations','Reservations & waitlist','حجز الطاولات وقائمة الانتظار', true, 31, false),
  ('transfers','Branch transfers','التحويل بين الفروع', true, 32, true),
  ('production','Production (central kitchen)','الإنتاج (المطبخ المركزي)', true, 33, false),
  ('qr_ordering','QR table ordering & kiosk','الطلب من الطاولة QR والكشك', true, 34, false),
  ('own_delivery','Own delivery drivers','التوصيل بسائقين', true, 35, false),
  ('attendance','Staff attendance','حضور الموظفين', true, 36, true),
  ('customer_display','Customer display','شاشة العميل', true, 37, true)
on conflict (key) do nothing;
-- which business types use them
update public.business_profiles set modules = modules || '{"reservations":1,"qr_ordering":1,"own_delivery":1,"production":1}' where key in ('restaurant');
update public.business_profiles set modules = modules || '{"qr_ordering":1,"own_delivery":1,"production":1,"reservations":1}' where key in ('cafe');
update public.business_profiles set modules = modules || '{"qr_ordering":1,"own_delivery":1,"production":1}' where key in ('quick_service');
update public.business_profiles set modules = modules || '{"production":2,"own_delivery":1}' where key in ('bakery');
update public.business_profiles set modules = modules || '{"own_delivery":1}' where key in ('grocery','florist','laundry');
update public.business_profiles set modules = modules || '{"gift_cards":1}' where key in ('fashion','perfume','stationery','spa','salon','florist','electronics','jewelry');
update public.business_profiles set modules = modules || '{"customer_display":1}' where key in ('grocery','hypermarket','fashion','electronics','perfume','stationery','restaurant','cafe','quick_service','bakery');
-- the business types that were already built switch on what they now expect
update public.tenants t set features = t.features || coalesce((
  select jsonb_object_agg(m.key, true) from public.feature_modules m join public.business_profiles bp on bp.key = t.business_profile
   where m.built and bp.modules->>m.key = '2' and not t.features ? m.key), '{}');

alter table public.stock_movements drop constraint if exists stock_movements_reason_check;
alter table public.stock_movements add constraint stock_movements_reason_check
  check (reason in ('sale','refund','adjustment','receipt','count','transfer_in','transfer_out','production'));
alter table public.items drop constraint if exists items_item_type_check;
alter table public.items add constraint items_item_type_check check (item_type in ('standard','ingredient','recipe','service','package','gift_card'));
create or replace function public.normalize_item_type() returns trigger language plpgsql as $$
begin
  if new.item_type in ('recipe','service','package','gift_card') or new.is_template then new.track_stock := false; end if;
  if new.item_type = 'ingredient' then new.track_stock := true; end if;
  if new.item_type = 'service' and new.duration_min is null then new.duration_min := 30; end if;
  return new;
end $$;

insert into public.coa_template(system_key, code, name_en, name_ar, type, section) values
  ('gift_cards', '2270', 'Gift cards outstanding', 'بطاقات هدايا غير مستخدمة', 'liability', 'current_liability'),
  ('cod_clearing', '1070', 'Cash with drivers (cash on delivery)', 'نقدية لدى السائقين (الدفع عند الاستلام)', 'asset', 'current_asset')
on conflict (system_key) do nothing;
insert into public.accounts(tenant_id, code, name_en, name_ar, type, system_key)
select t.id, c.code, c.name_en, c.name_ar, c.type, c.system_key from public.tenants t cross join public.coa_template c
 where c.system_key in ('gift_cards','cod_clearing') on conflict do nothing;

create or replace function public._tender_account(p_tender public.tender_type) returns text
language sql immutable as $$
  select case p_tender::text
    when 'cash' then 'cash' when 'card' then 'card_clearing' when 'bank_transfer' then 'bank' when 'store_credit' then 'store_credit'
    when 'on_account' then 'ar' when 'payment_link' then 'ar' when 'platform' then 'platform_clearing'
    when 'package' then 'deferred_revenue' when 'deposit' then 'customer_deposits' when 'loyalty' then 'exp_loyalty'
    when 'gift_card' then 'gift_cards' when 'cod' then 'cod_clearing'
    else 'other_clearing' end;
$$;

-- ================================================================ gift cards
create table public.gift_cards (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  code        text not null,
  initial     bigint not null check (initial > 0),
  balance     bigint not null check (balance >= 0),
  customer_id uuid references public.customers(id),
  sale_id     uuid references public.sales(id),
  expires_on  date,
  status      text not null default 'active' check (status in ('active','void')),
  created_at  timestamptz not null default now(),
  unique (tenant_id, code)
);
create table public.gift_card_moves (
  id         bigint generated always as identity primary key,
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  card_id    uuid not null references public.gift_cards(id),
  sale_id    uuid references public.sales(id),
  amount     bigint not null,
  kind       text not null check (kind in ('issue','redeem','void')),
  created_at timestamptz not null default now()
);
alter table public.gift_cards enable row level security;
alter table public.gift_card_moves enable row level security;
create policy gc_read on public.gift_cards for select to authenticated using (public.is_member(tenant_id));
create policy gcm_read on public.gift_card_moves for select to authenticated using (public.is_member(tenant_id));
revoke insert, update, delete on public.gift_cards, public.gift_card_moves from authenticated;
create or replace function public.gift_card_check(p_tenant uuid, p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when is_member(p_tenant) then (select jsonb_build_object('code', code, 'balance', balance, 'status', status, 'expires_on', expires_on)
    from gift_cards where tenant_id = p_tenant and code = upper(trim(p_code))) end;
$$;

-- ================================================================ reservations & waitlist
create table public.reservations (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  branch_id    uuid not null references public.branches(id),
  table_id     uuid references public.dining_tables(id),
  customer_id  uuid references public.customers(id),
  name         text not null,
  phone        text,
  party        integer not null check (party between 1 and 200),
  starts_at    timestamptz not null,
  duration_min integer not null default 90 check (duration_min between 15 and 600),
  ends_at      timestamptz not null,
  status       text not null default 'booked' check (status in ('booked','confirmed','seated','finished','no_show','cancelled')),
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  check (ends_at > starts_at),
  constraint reservations_no_overlap exclude using gist (table_id with =, tstzrange(starts_at, ends_at) with &&)
    where (table_id is not null and status in ('booked','confirmed','seated'))
);
create index on public.reservations(branch_id, starts_at);
create table public.waitlist (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  branch_id  uuid not null references public.branches(id),
  name       text not null,
  phone      text,
  party      integer not null check (party between 1 and 200),
  status     text not null default 'waiting' check (status in ('waiting','notified','seated','left')),
  note       text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.reservations enable row level security;
alter table public.waitlist enable row level security;
create policy rs_read on public.reservations for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy wl_read on public.waitlist for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
revoke insert, update, delete on public.reservations, public.waitlist from authenticated;

create or replace function public.save_reservation(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_tenant uuid; v_id uuid := nullif(p->>'id','')::uuid;
begin
  select tenant_id into v_tenant from branches where id = v_branch;
  if v_tenant is null or not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'sale.create', null, null);
  perform _require_feature(v_tenant, 'reservations');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'enter the guest name' using errcode = 'ZT422'; end if;
  begin
    if v_id is null then
      insert into reservations(tenant_id, branch_id, table_id, customer_id, name, phone, party, starts_at, duration_min, ends_at, note, created_by)
      values (v_tenant, v_branch, nullif(p->>'table_id','')::uuid, nullif(p->>'customer_id','')::uuid, trim(p->>'name'), nullif(p->>'phone',''),
              (p->>'party')::int, (p->>'starts_at')::timestamptz, coalesce((p->>'duration_min')::int, 90),
              (p->>'starts_at')::timestamptz + make_interval(mins => coalesce((p->>'duration_min')::int, 90)), nullif(p->>'note',''), auth.uid())
      returning id into v_id;
    else
      update reservations set table_id = nullif(p->>'table_id','')::uuid, name = trim(p->>'name'), phone = nullif(p->>'phone',''), party = (p->>'party')::int,
             starts_at = (p->>'starts_at')::timestamptz, duration_min = coalesce((p->>'duration_min')::int, 90),
             ends_at = (p->>'starts_at')::timestamptz + make_interval(mins => coalesce((p->>'duration_min')::int, 90)), note = nullif(p->>'note','')
       where id = v_id and tenant_id = v_tenant and status in ('booked','confirmed');
      if not found then raise exception 'this reservation can no longer be changed' using errcode = 'ZT422'; end if;
    end if;
  exception when exclusion_violation then raise exception 'That table is already reserved at that time' using errcode = 'ZT422';
  end;
  return v_id;
end $$;

create or replace function public.set_reservation_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  select * into r from reservations where id = p_id for update;
  if not found or not can_see_branch(r.tenant_id, r.branch_id) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(r.tenant_id, 'sale.create', null, null);
  if p_status not in ('booked','confirmed','seated','finished','no_show','cancelled') then raise exception 'unknown status' using errcode = 'ZT422'; end if;
  update reservations set status = p_status where id = p_id;
end $$;

create or replace function public.waitlist_add(p_branch uuid, p_name text, p_phone text, p_party int, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v uuid;
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if v_tenant is null or not can_see_branch(v_tenant, p_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require_feature(v_tenant, 'reservations');
  insert into waitlist(tenant_id, branch_id, name, phone, party, note) values (v_tenant, p_branch, trim(p_name), nullif(p_phone,''), p_party, nullif(p_note,'')) returning id into v;
  return v;
end $$;
create or replace function public.waitlist_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare w waitlist%rowtype;
begin
  select * into w from waitlist where id = p_id for update;
  if not found or not can_see_branch(w.tenant_id, w.branch_id) then raise exception 'not found' using errcode = '42501'; end if;
  if p_status not in ('waiting','notified','seated','left') then raise exception 'unknown status' using errcode = 'ZT422'; end if;
  update waitlist set status = p_status, updated_at = now() where id = p_id;
end $$;

-- ================================================================ branch transfers & production
create table public.stock_transfers (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  number      text not null,
  from_branch uuid not null references public.branches(id),
  to_branch   uuid not null references public.branches(id),
  status      text not null default 'sent' check (status in ('sent','received','cancelled')),
  lines       jsonb not null,            -- [{item_id, name, qty, received_qty}]
  note        text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  received_by uuid,
  received_at timestamptz,
  check (from_branch <> to_branch),
  unique (tenant_id, number)
);
alter table public.stock_transfers enable row level security;
create policy st_read on public.stock_transfers for select to authenticated using (public.can_see_branch(tenant_id, from_branch) or public.can_see_branch(tenant_id, to_branch));
revoke insert, update, delete on public.stock_transfers from authenticated;

-- send: stock leaves the source branch now; it arrives when the other branch confirms
create or replace function public.send_transfer(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from uuid := (p->>'from_branch')::uuid; v_to uuid := (p->>'to_branch')::uuid; v_tenant uuid; l jsonb; it items%rowtype; v_lines jsonb := '[]'; v_id uuid; v_no int;
begin
  select tenant_id into v_tenant from branches where id = v_from;
  if v_tenant is null or not can_see_branch(v_tenant, v_from) or not exists (select 1 from branches where id = v_to and tenant_id = v_tenant) then
    raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'inventory.adjust', null, null);
  perform _require_feature(v_tenant, 'transfers');
  select count(*) + 1 into v_no from stock_transfers where tenant_id = v_tenant;
  insert into stock_transfers(tenant_id, number, from_branch, to_branch, lines, note, created_by)
  values (v_tenant, 'TR-' || lpad(v_no::text, 5, '0'), v_from, v_to, '[]', nullif(p->>'note',''), auth.uid()) returning id into v_id;
  for l in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    select * into it from items where id = (l->>'item_id')::uuid and tenant_id = v_tenant and track_stock;
    if not found or coalesce((l->>'qty')::numeric, 0) <= 0 then raise exception 'check the items and quantities' using errcode = 'ZT422'; end if;
    insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
    values (v_tenant, v_from, it.id, -(l->>'qty')::numeric, 'transfer_out', v_id, it.cost, 'TR to ' || (select name from branches where id = v_to), auth.uid());
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'name', it.name, 'qty', (l->>'qty')::numeric, 'cost', it.cost);
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'add at least one item' using errcode = 'ZT422'; end if;
  update stock_transfers set lines = v_lines where id = v_id;
  return (select to_jsonb(x) from stock_transfers x where id = v_id);
end $$;

-- receive: what arrived goes into the receiving branch; anything short is written off as a transfer loss
create or replace function public.receive_transfer(p_id uuid, p_received jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tr stock_transfers%rowtype; l jsonb; v_got numeric; v_lines jsonb := '[]'; v_loss bigint := 0;
begin
  select * into tr from stock_transfers where id = p_id for update;
  if not found or not can_see_branch(tr.tenant_id, tr.to_branch) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(tr.tenant_id, 'inventory.receive', null, null);
  if tr.status <> 'sent' then raise exception 'this transfer is closed' using errcode = 'ZT422'; end if;
  for l in select * from jsonb_array_elements(tr.lines) loop
    v_got := coalesce((p_received->>(l->>'item_id'))::numeric, (l->>'qty')::numeric);
    if v_got < 0 or v_got > (l->>'qty')::numeric then raise exception 'received quantity must be between 0 and what was sent' using errcode = 'ZT422'; end if;
    if v_got > 0 then
      insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
      values (tr.tenant_id, tr.to_branch, (l->>'item_id')::uuid, v_got, 'transfer_in', tr.id, (l->>'cost')::bigint, tr.number, auth.uid());
    end if;
    v_loss := v_loss + round(((l->>'qty')::numeric - v_got) * (l->>'cost')::bigint)::bigint;
    v_lines := v_lines || (l || jsonb_build_object('received_qty', v_got));
  end loop;
  update stock_transfers set status = 'received', lines = v_lines, received_by = auth.uid(), received_at = now() where id = tr.id;
  if v_loss > 0 then
    perform _post(tr.tenant_id, tr.to_branch, 'transfer_loss', tr.id, tr.number, jsonb_build_array(
      jsonb_build_object('key','inventory_adjustments','debit', v_loss), jsonb_build_object('key','inventory','credit', v_loss)));
  end if;
  return (select to_jsonb(x) from stock_transfers x where id = tr.id);
end $$;

-- production: make stocked items from their recipe (bread, sauces, cakes); ingredients out, finished goods in at recipe cost
create or replace function public.produce(p_branch uuid, p_item uuid, p_qty numeric, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare it items%rowtype; r record; v_cost bigint := 0; v_ref uuid := gen_random_uuid();
begin
  select * into it from items where id = p_item;
  if not found or not can_see_branch(it.tenant_id, p_branch) then raise exception 'not allowed' using errcode = '42501'; end if;
  perform _require(it.tenant_id, 'inventory.adjust', null, null);
  perform _require_feature(it.tenant_id, 'production');
  if not it.track_stock then raise exception 'only stocked items can be produced; switch on "Track stock"' using errcode = 'ZT422'; end if;
  if p_qty <= 0 then raise exception 'quantity must be positive' using errcode = 'ZT422'; end if;
  if not exists (select 1 from recipe_lines where item_id = p_item) then raise exception 'add a recipe to % first', it.name using errcode = 'ZT422'; end if;
  for r in select rl.ingredient_id, rl.qty, i.cost from recipe_lines rl join items i on i.id = rl.ingredient_id where rl.item_id = p_item loop
    insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
    values (it.tenant_id, p_branch, r.ingredient_id, -(r.qty * p_qty), 'production', v_ref, r.cost, coalesce(p_note, 'Production · ' || it.name), auth.uid());
    v_cost := v_cost + round(r.qty * p_qty * r.cost)::bigint;
  end loop;
  insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
  values (it.tenant_id, p_branch, p_item, p_qty, 'production', v_ref, round(v_cost / p_qty)::bigint, coalesce(p_note, 'Production'), auth.uid());
  update items set cost = round(v_cost / p_qty)::bigint where id = p_item;
  return jsonb_build_object('item', it.name, 'qty', p_qty, 'unit_cost', round(v_cost / p_qty), 'total_cost', v_cost);
end $$;

-- ================================================================ QR table ordering & kiosk
alter table public.dining_tables add column qr_token text unique default encode(extensions.gen_random_bytes(6), 'hex');
update public.dining_tables set qr_token = encode(extensions.gen_random_bytes(6), 'hex') where qr_token is null;
create table public.online_orders (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  branch_id     uuid not null references public.branches(id),
  table_id      uuid references public.dining_tables(id),
  source        text not null check (source in ('qr','kiosk')),
  number        integer not null,
  name          text,
  phone         text,
  note          text,
  lines         jsonb not null,
  total         bigint not null,
  status        text not null default 'pending' check (status in ('pending','accepted','rejected','paid')),
  open_order_id uuid references public.open_orders(id),
  sale_id       uuid references public.sales(id),
  created_at    timestamptz not null default now(),
  handled_by    uuid
);
create index on public.online_orders(branch_id, status, created_at);
alter table public.online_orders enable row level security;
create policy oq_read on public.online_orders for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
revoke insert, update, delete on public.online_orders from authenticated;
insert into public.event_types values ('order.received','QR or kiosk order received','طلب من QR أو الكشك',10) on conflict do nothing;

-- the menu for the table / kiosk page (no sign-in)
create or replace function public.menu_info(p_slug text, p_table text default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'business', t.name, 'business_ar', t.name_ar, 'logo_url', t.logo_url, 'brand_color', t.brand_color, 'currency', t.currency, 'decimals', t.currency_decimals,
    'prices_include_tax', t.prices_include_tax, 'vat_rate', t.vat_rate,
    'table', (select jsonb_build_object('id', d.id, 'name', d.name, 'branch_id', d.branch_id) from dining_tables d where d.tenant_id = t.id and d.qr_token = p_table and d.is_active),
    'branch_id', (select id from branches where tenant_id = t.id and is_active order by code limit 1),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'name_ar', c.name_ar) order by c.sort, c.name), '[]') from categories c where c.tenant_id = t.id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'name_ar', i.name_ar, 'price', i.price, 'image_url', i.image_url, 'category_id', i.category_id,
                'groups', (select coalesce(jsonb_agg(ig.group_id order by ig.sort), '[]') from item_modifier_groups ig where ig.item_id = i.id)) order by i.name), '[]')
                from items i where i.tenant_id = t.id and i.is_active and not i.is_template and i.parent_id is null and i.item_type in ('standard','recipe')),
    'groups', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'name_ar', g.name_ar, 'min_select', g.min_select, 'max_select', g.max_select,
                'options', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'name_ar', o.name_ar, 'price', o.price) order by o.sort), '[]') from modifier_options o where o.group_id = g.id and o.is_active))
                order by g.sort), '[]') from modifier_groups g where g.tenant_id = t.id))
  from tenants t where t.booking_slug = lower(p_slug) and has_feature(t.id, 'qr_ordering');
$$;

-- p = { table?: qr token, kiosk?: bool, lines:[{item_id, qty, modifiers, note}], name?, phone?, note? }
create or replace function public.place_order(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_branch uuid; v_table dining_tables%rowtype; v_lines jsonb; v_total bigint; v_no int; v_id uuid; v_src text;
begin
  select id into v_tenant from tenants where booking_slug = lower(p_slug) and has_feature(id, 'qr_ordering');
  if v_tenant is null then raise exception 'ordering is not available' using errcode = '42501'; end if;
  if nullif(p->>'table','') is not null then
    select * into v_table from dining_tables where tenant_id = v_tenant and qr_token = p->>'table' and is_active;
    if not found then raise exception 'this table code is not valid' using errcode = 'ZT422'; end if;
    v_branch := v_table.branch_id; v_src := 'qr';
    -- a table cannot flood the kitchen: at most 6 orders waiting for staff
    if (select count(*) from online_orders where table_id = v_table.id and status = 'pending') >= 6 then
      raise exception 'Please wait for staff to confirm your earlier orders' using errcode = 'ZT422'; end if;
  elsif coalesce((p->>'kiosk')::boolean, false) then
    select id into v_branch from branches where tenant_id = v_tenant and is_active order by code limit 1; v_src := 'kiosk';
  else raise exception 'scan the code on your table' using errcode = 'ZT422'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 or jsonb_array_length(p->'lines') > 50 then raise exception 'add something to your order' using errcode = 'ZT422'; end if;
  v_lines := _price_lines(v_tenant, p->'lines');
  select sum(round((x->>'qty')::numeric * (x->>'unit_price')::bigint)) into v_total from jsonb_array_elements(v_lines) x;
  select coalesce(max(number), 0) % 999 + 1 into v_no from online_orders where branch_id = v_branch and created_at > now() - interval '1 day';
  insert into online_orders(tenant_id, branch_id, table_id, source, number, name, phone, note, lines, total)
  values (v_tenant, v_branch, v_table.id, v_src, v_no, nullif(trim(p->>'name'),''), nullif(trim(p->>'phone'),''), left(nullif(p->>'note',''), 200), v_lines, v_total)
  returning id into v_id;
  perform _emit(v_tenant, 'order.received', jsonb_build_object('id', v_id, 'number', v_no, 'source', v_src, 'table', v_table.name, 'total', v_total));
  return jsonb_build_object('id', v_id, 'number', v_no, 'total', v_total);
end $$;

create or replace function public.order_status(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('number', number, 'status', status) from online_orders where id = p_id;
$$;

-- staff: accept a QR order into the table's open order (sent to the kitchen), or reject it
create or replace function public.handle_online_order(p_id uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o online_orders%rowtype; oo open_orders%rowtype; v_tb dining_tables%rowtype;
begin
  select * into o from online_orders where id = p_id for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(o.tenant_id, 'sale.create', null, null);
  if o.status <> 'pending' then raise exception 'this order was already handled' using errcode = 'ZT422'; end if;
  if not p_accept then update online_orders set status = 'rejected', handled_by = auth.uid() where id = o.id; return to_jsonb(o); end if;
  if o.table_id is not null then
    select * into v_tb from dining_tables where id = o.table_id;
    select * into oo from open_orders where table_id = o.table_id and status = 'open' for update;
    if oo.id is null then
      insert into open_orders(tenant_id, branch_id, table_id, label, lines, opened_by) values (o.tenant_id, o.branch_id, o.table_id, v_tb.name, '[]', auth.uid()) returning * into oo;
    end if;
    update open_orders set lines = lines || (select jsonb_agg(x || '{"fired": true}') from jsonb_array_elements(o.lines) x), updated_at = now() where id = oo.id;
    perform _kitchen_from_lines(o.tenant_id, o.branch_id, oo.id, v_tb.name || ' · QR ' || o.number, 'dine_in', v_tb.name, o.lines);
    update online_orders set status = 'accepted', open_order_id = oo.id, handled_by = auth.uid() where id = o.id;
  else
    update online_orders set status = 'accepted', handled_by = auth.uid() where id = o.id;
  end if;
  return (select to_jsonb(x) from online_orders x where id = o.id);
end $$;

-- ================================================================ own delivery
alter table public.customers add column address text;
alter table public.memberships add column is_driver boolean not null default false;
create table public.deliveries (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  branch_id       uuid not null references public.branches(id),
  sale_id         uuid not null references public.sales(id),
  customer_id     uuid references public.customers(id),
  address         text,
  phone           text,
  note            text,
  driver_id       uuid,
  status          text not null default 'pending' check (status in ('pending','assigned','picked_up','delivered','failed')),
  cash_to_collect bigint not null default 0,
  cash_settled    boolean not null default false,
  created_at      timestamptz not null default now(),
  assigned_at     timestamptz,
  picked_at       timestamptz,
  delivered_at    timestamptz
);
create index on public.deliveries(branch_id, status);
create index on public.deliveries(driver_id, status);
alter table public.deliveries enable row level security;
create policy dl_read on public.deliveries for select to authenticated using (public.can_see_branch(tenant_id, branch_id) or driver_id = auth.uid());
revoke insert, update, delete on public.deliveries from authenticated;
alter table public.payments add column delivery_id uuid references public.deliveries(id);
alter table public.payments drop constraint if exists payments_owner;
alter table public.payments add constraint payments_owner check (sale_id is not null or work_order_id is not null or delivery_id is not null);

create or replace function public.delivery_status(p_id uuid, p_status text, p_driver uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d deliveries%rowtype;
begin
  select * into d from deliveries where id = p_id for update;
  if not found then raise exception 'not found' using errcode = '42501'; end if;
  -- the driver moves their own deliveries; the branch assigns and can change anything
  if not (d.driver_id = auth.uid() and p_status in ('picked_up','delivered','failed')) then
    if not can_see_branch(d.tenant_id, d.branch_id) then raise exception 'not allowed' using errcode = '42501'; end if;
    perform _require(d.tenant_id, 'sale.create', null, null);
  end if;
  if p_status = 'assigned' then
    if not exists (select 1 from memberships where tenant_id = d.tenant_id and user_id = p_driver and is_driver and is_active) then
      raise exception 'choose a driver' using errcode = 'ZT422'; end if;
    update deliveries set driver_id = p_driver, status = 'assigned', assigned_at = now() where id = d.id;
  elsif p_status in ('picked_up','delivered','failed','pending') then
    update deliveries set status = p_status, picked_at = case when p_status = 'picked_up' then now() else picked_at end,
           delivered_at = case when p_status = 'delivered' then now() else delivered_at end where id = d.id;
  else raise exception 'unknown status' using errcode = 'ZT422'; end if;
  return (select to_jsonb(x) from deliveries x where id = d.id);
end $$;

-- the driver hands in the cash collected on delivered orders: it enters the drawer of the open shift
create or replace function public.settle_driver_cash(p_branch uuid, p_driver uuid, p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; d deliveries%rowtype; v_total bigint := 0; n int := 0;
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if v_tenant is null or not can_see_branch(v_tenant, p_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'payments.receive', null, null);
  if p_shift is not null and not exists (select 1 from shifts where id = p_shift and closed_at is null) then p_shift := null; end if;
  for d in select * from deliveries where branch_id = p_branch and driver_id = p_driver and status = 'delivered' and cash_to_collect > 0 and not cash_settled for update loop
    insert into payments(tenant_id, sale_id, delivery_id, tender, amount, reference, status, shift_id, created_by)
    values (d.tenant_id, d.sale_id, d.id, 'cash', d.cash_to_collect, 'Driver cash', 'captured', p_shift, auth.uid());
    update sales set paid_total = paid_total + d.cash_to_collect where id = d.sale_id;
    update deliveries set cash_settled = true where id = d.id;
    perform _post(d.tenant_id, d.branch_id, 'driver_cash', d.id, (select number from sales where id = d.sale_id), jsonb_build_array(
      jsonb_build_object('key','cash','debit', d.cash_to_collect), jsonb_build_object('key','cod_clearing','credit', d.cash_to_collect)));
    v_total := v_total + d.cash_to_collect; n := n + 1;
  end loop;
  return jsonb_build_object('orders', n, 'cash', v_total);
end $$;

-- ================================================================ attendance (geofence)
alter table public.branches add column if not exists lat numeric(9,6), add column if not exists lng numeric(9,6), add column if not exists geofence_m integer not null default 150 check (geofence_m between 20 and 5000);
create table public.attendance (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  branch_id    uuid not null references public.branches(id),
  user_id      uuid not null,
  clock_in     timestamptz not null default now(),
  clock_out    timestamptz,
  in_distance  integer,
  out_distance integer,
  note         text
);
create unique index attendance_one_open on public.attendance(tenant_id, user_id) where clock_out is null;
alter table public.attendance enable row level security;
create policy at_read on public.attendance for select to authenticated using (user_id = auth.uid() or public.has_perm(tenant_id, 'staff.manage') or public.has_perm(tenant_id, 'reports.all'));
revoke insert, update, delete on public.attendance from authenticated;

-- metres between two points (haversine)
create or replace function public._distance_m(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric) returns integer
language sql immutable as $$
  select round(2 * 6371000 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2) + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))::int;
$$;

-- clock in, or out if already in; the phone's location must be inside the branch circle when the branch has one
create or replace function public.clock(p_branch uuid, p_lat numeric, p_lng numeric, p_accuracy numeric default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b branches%rowtype; v_dist int; a attendance%rowtype;
begin
  select * into b from branches where id = p_branch;
  if not found or not is_member(b.tenant_id) or not can_see_branch(b.tenant_id, p_branch) then raise exception 'not allowed' using errcode = '42501'; end if;
  perform _require_feature(b.tenant_id, 'attendance');
  if b.lat is not null then
    if p_lat is null then raise exception 'allow location on this device to clock in' using errcode = 'ZT422'; end if;
    v_dist := _distance_m(b.lat::numeric, b.lng::numeric, p_lat, p_lng);
    if v_dist > b.geofence_m + least(coalesce(p_accuracy, 0), 100) then
      raise exception 'You are % m from the branch; clock in at the branch', v_dist using errcode = 'ZT422'; end if;
  end if;
  select * into a from attendance where tenant_id = b.tenant_id and user_id = auth.uid() and clock_out is null for update;
  if found then
    update attendance set clock_out = now(), out_distance = v_dist where id = a.id returning * into a;
    return jsonb_build_object('action', 'out', 'at', a.clock_out, 'hours', round(extract(epoch from (a.clock_out - a.clock_in)) / 3600.0, 2));
  end if;
  insert into attendance(tenant_id, branch_id, user_id, in_distance) values (b.tenant_id, p_branch, auth.uid(), v_dist) returning * into a;
  return jsonb_build_object('action', 'in', 'at', a.clock_in, 'distance', v_dist);
end $$;

create or replace view public.v_attendance with (security_invoker = true) as
select a.id, a.tenant_id, a.branch_id, a.user_id, m.display_name, (a.clock_in at time zone b.timezone)::date as day, a.clock_in, a.clock_out,
       round(extract(epoch from (coalesce(a.clock_out, now()) - a.clock_in)) / 3600.0, 2) as hours, a.in_distance, a.out_distance
  from public.attendance a join public.branches b on b.id = a.branch_id left join public.memberships m on m.tenant_id = a.tenant_id and m.user_id = a.user_id;
grant select on public.v_attendance to authenticated;

-- ================================================================ gates and grants
create trigger reservations_gate before insert on public.reservations for each row execute function public.module_gate('reservations');
grant execute on function public.gift_card_check(uuid, text), public.save_reservation(jsonb), public.set_reservation_status(uuid, text),
  public.waitlist_add(uuid, text, text, int, text), public.waitlist_status(uuid, text), public.send_transfer(jsonb), public.receive_transfer(uuid, jsonb),
  public.produce(uuid, uuid, numeric, text), public.handle_online_order(uuid, boolean), public.delivery_status(uuid, text, uuid),
  public.settle_driver_cash(uuid, uuid, uuid), public.clock(uuid, numeric, numeric, numeric) to authenticated;
grant execute on function public.menu_info(text, text), public.place_order(text, jsonb), public.order_status(uuid) to anon, authenticated;
revoke execute on function public._distance_m(numeric, numeric, numeric, numeric) from public, anon, authenticated;

-- ================================================================ checkout v5: gift cards, cash on delivery, QR/kiosk orders, own delivery
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
    v_tender_list := v_tender_list || jsonb_build_object('tender', v_tender, 'amount', v_amt, 'reference', pay->>'reference');
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
    insert into payments(tenant_id, sale_id, tender, amount, reference, status, shift_id, created_by)
    values (t.id, v_sale, v_tender, v_amt, nullif(pay->>'reference',''),
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

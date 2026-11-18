-- Z Trust · phase D: job cards & pre-orders with deposits, tables & open orders, loyalty points
-- and the checkout (complete_sale v4) that ties phases B–D together.

-- ================================================================ payments can belong to a job/pre-order deposit
alter table public.payments alter column sale_id drop not null;
alter table public.payments add column work_order_id uuid;
alter table public.payments add constraint payments_owner check (sale_id is not null or work_order_id is not null);

create or replace function public._tender_account(p_tender public.tender_type) returns text
language sql immutable as $$
  select case p_tender::text
    when 'cash' then 'cash' when 'card' then 'card_clearing' when 'bank_transfer' then 'bank' when 'store_credit' then 'store_credit'
    when 'on_account' then 'ar' when 'payment_link' then 'ar' when 'platform' then 'platform_clearing'
    when 'package' then 'deferred_revenue' when 'deposit' then 'customer_deposits' when 'loyalty' then 'exp_loyalty'
    else 'other_clearing' end;
$$;

-- ================================================================ job cards & pre-orders
create table public.work_orders (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  branch_id    uuid not null references public.branches(id),
  kind         text not null check (kind in ('job','preorder')),
  number       text not null,
  customer_id  uuid references public.customers(id),
  status       text not null default 'received' check (status in ('received','in_progress','ready','collected','cancelled')),
  due_at       timestamptz,
  reference    text,          -- plate number, device + IMEI, cake message…
  tags         text,          -- laundry tag numbers
  note         text,
  lines        jsonb not null default '[]',   -- [{item_id, name, qty, unit_price, note}]
  total        bigint not null default 0,      -- estimate from the lines (gross)
  deposit_paid bigint not null default 0,
  deposit_used bigint not null default 0,
  sale_id      uuid references public.sales(id),
  created_by   uuid,
  created_at   timestamptz not null default now(),
  ready_at     timestamptz,
  collected_at timestamptz,
  unique (tenant_id, number)
);
create index on public.work_orders(branch_id, status, due_at);
alter table public.payments add constraint payments_work_order_fk foreign key (work_order_id) references public.work_orders(id);
create table public.work_order_seq (
  tenant_id uuid not null, branch_id uuid not null, kind text not null, next_no bigint not null,
  primary key (tenant_id, branch_id, kind)
);
alter table public.work_orders enable row level security;
alter table public.work_order_seq enable row level security;
create policy wo_read on public.work_orders for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
revoke insert, update, delete on public.work_orders, public.work_order_seq from authenticated;

-- p = { id?, branch_id, kind, customer_id?, due_at?, reference?, tags?, note?, lines:[{item_id, qty, note}] }
create or replace function public.save_work_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_tenant uuid; v_id uuid := nullif(p->>'id','')::uuid; v_kind text := coalesce(p->>'kind','job');
  v_lines jsonb := '[]'; l jsonb; it items%rowtype; v_total bigint := 0; v_no bigint; v_number text;
begin
  select tenant_id into v_tenant from branches where id = v_branch;
  if v_tenant is null or not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'sale.create', null, null);
  perform _require_feature(v_tenant, case when v_kind = 'job' then 'job_cards' else 'preorders' end);
  for l in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    select * into it from items where id = (l->>'item_id')::uuid and tenant_id = v_tenant;
    if not found or it.is_template or it.item_type = 'ingredient' then raise exception 'unknown item' using errcode = 'ZT422'; end if;
    if coalesce((l->>'qty')::numeric, 0) <= 0 then raise exception 'quantity must be positive' using errcode = 'ZT422'; end if;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'name', it.name, 'name_ar', it.name_ar, 'qty', (l->>'qty')::numeric,
                                             'unit_price', it.price, 'note', nullif(l->>'note',''));
    v_total := v_total + round((l->>'qty')::numeric * it.price)::bigint;
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'add at least one item' using errcode = 'ZT422'; end if;
  if v_kind = 'preorder' and nullif(p->>'due_at','') is null then raise exception 'choose the date and time for the pre-order' using errcode = 'ZT422'; end if;
  if v_id is null then
    insert into work_order_seq values (v_tenant, v_branch, v_kind, 2)
    on conflict (tenant_id, branch_id, kind) do update set next_no = work_order_seq.next_no + 1 returning next_no - 1 into v_no;
    v_number := (select code from branches where id = v_branch) || '-' || case v_kind when 'job' then 'JOB' else 'PRE' end || '-' || lpad(v_no::text, 5, '0');
    insert into work_orders(tenant_id, branch_id, kind, number, customer_id, due_at, reference, tags, note, lines, total, created_by)
    values (v_tenant, v_branch, v_kind, v_number, nullif(p->>'customer_id','')::uuid, nullif(p->>'due_at','')::timestamptz,
            nullif(p->>'reference',''), nullif(p->>'tags',''), nullif(p->>'note',''), v_lines, v_total, auth.uid())
    returning id into v_id;
  else
    update work_orders set customer_id = nullif(p->>'customer_id','')::uuid, due_at = nullif(p->>'due_at','')::timestamptz,
           reference = nullif(p->>'reference',''), tags = nullif(p->>'tags',''), note = nullif(p->>'note',''), lines = v_lines, total = v_total
     where id = v_id and tenant_id = v_tenant and status in ('received','in_progress','ready');
    if not found then raise exception 'this order can no longer be changed' using errcode = 'ZT422'; end if;
  end if;
  return (select to_jsonb(w) from work_orders w where id = v_id);
end $$;

create or replace function public.set_work_order_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders%rowtype;
begin
  select * into w from work_orders where id = p_id for update;
  if not found or not can_see_branch(w.tenant_id, w.branch_id) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(w.tenant_id, 'sale.create', null, null);
  if p_status not in ('received','in_progress','ready','cancelled') then raise exception 'unknown status' using errcode = 'ZT422'; end if;
  if w.status in ('collected','cancelled') then raise exception 'this order is closed' using errcode = 'ZT422'; end if;
  if p_status = 'cancelled' and w.deposit_paid > w.deposit_used then raise exception 'refund the deposit first' using errcode = 'ZT422'; end if;
  update work_orders set status = p_status, ready_at = case when p_status = 'ready' then now() else ready_at end where id = p_id;
  if p_status = 'ready' and w.status <> 'ready' then
    perform _emit(w.tenant_id, 'job.ready', jsonb_build_object('id', w.id, 'number', w.number, 'kind', w.kind, 'branch_id', w.branch_id,
      'customer', (select jsonb_build_object('name', c.name, 'phone', c.phone) from customers c where c.id = w.customer_id),
      'reference', w.reference, 'balance_due', greatest(w.total - (w.deposit_paid - w.deposit_used), 0)));
  end if;
end $$;

-- deposit on a job or pre-order: cash in the drawer, a liability until the order is collected
create or replace function public.take_deposit(p_order uuid, p_tender public.tender_type, p_amount bigint, p_reference text default null, p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders%rowtype;
begin
  select * into w from work_orders where id = p_order for update;
  if not found or not can_see_branch(w.tenant_id, w.branch_id) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(w.tenant_id, 'payments.receive', null, null);
  if w.status in ('collected','cancelled') then raise exception 'this order is closed' using errcode = 'ZT422'; end if;
  if p_tender not in ('cash','card','bank_transfer','other') then raise exception 'take deposits in cash, card or transfer' using errcode = 'ZT422'; end if;
  if p_amount <= 0 then raise exception 'enter an amount' using errcode = 'ZT422'; end if;
  if p_shift is not null and not exists (select 1 from shifts where id = p_shift and closed_at is null) then p_shift := null; end if;
  insert into payments(tenant_id, work_order_id, tender, amount, reference, status, shift_id, created_by)
  values (w.tenant_id, w.id, p_tender, p_amount, p_reference, 'captured', p_shift, auth.uid());
  update work_orders set deposit_paid = deposit_paid + p_amount where id = w.id;
  perform _post(w.tenant_id, w.branch_id, 'deposit', w.id, w.number, jsonb_build_array(
    jsonb_build_object('key', _tender_account(p_tender), 'debit', p_amount),
    jsonb_build_object('key', 'customer_deposits', 'credit', p_amount, 'customer_id', w.customer_id)));
  return (select to_jsonb(x) from work_orders x where id = w.id);
end $$;

create or replace function public.refund_deposit(p_order uuid, p_tender public.tender_type, p_reason text, p_shift uuid default null, p_approver_pin text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders%rowtype; v bigint; v_appr uuid;
begin
  select * into w from work_orders where id = p_order for update;
  if not found or not can_see_branch(w.tenant_id, w.branch_id) then raise exception 'not found' using errcode = '42501'; end if;
  v := w.deposit_paid - w.deposit_used;
  if v <= 0 then raise exception 'no deposit to refund' using errcode = 'ZT422'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = 'ZT422'; end if;
  v_appr := _require(w.tenant_id, 'sale.refund', v, p_approver_pin);
  if p_shift is not null and not exists (select 1 from shifts where id = p_shift and closed_at is null) then p_shift := null; end if;
  insert into payments(tenant_id, work_order_id, tender, amount, reference, status, shift_id, created_by)
  values (w.tenant_id, w.id, p_tender, -v, p_reason, 'captured', p_shift, auth.uid());
  update work_orders set deposit_paid = deposit_used where id = w.id;
  perform _post(w.tenant_id, w.branch_id, 'deposit_refund', w.id, w.number, jsonb_build_array(
    jsonb_build_object('key', 'customer_deposits', 'debit', v, 'customer_id', w.customer_id),
    jsonb_build_object('key', _tender_account(p_tender), 'credit', v)));
  perform _audit(w.tenant_id, w.branch_id, 'deposit.refund', 'work_order', w.id, v, p_reason, v_appr, '{}');
  return (select to_jsonb(x) from work_orders x where id = w.id);
end $$;

-- ================================================================ tables & open orders (dine-in, pay later)
create table public.dining_tables (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  area      text not null default 'Main',
  name      text not null,
  seats     integer not null default 4 check (seats between 1 and 50),
  x         integer not null default 0,
  y         integer not null default 0,
  shape     text not null default 'square' check (shape in ('square','round','long')),
  is_active boolean not null default true,
  unique (branch_id, name)
);
create table public.open_orders (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  branch_id  uuid not null references public.branches(id),
  table_id   uuid references public.dining_tables(id),
  label      text not null,
  guests     integer,
  customer_id uuid references public.customers(id),
  lines      jsonb not null default '[]',   -- [{key, item_id, name, qty, unit_price, modifiers, note, fired}]
  status     text not null default 'open' check (status in ('open','closed','void')),
  opened_by  uuid,
  opened_at  timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at  timestamptz,
  sale_ids   uuid[] not null default '{}'
);
create unique index open_orders_one_per_table on public.open_orders(table_id) where status = 'open' and table_id is not null;
alter table public.kitchen_tickets add column open_order_id uuid references public.open_orders(id);
alter table public.dining_tables enable row level security;
alter table public.open_orders enable row level security;
create policy dt_read on public.dining_tables for select to authenticated using (public.is_member(tenant_id));
create policy dt_write on public.dining_tables for all to authenticated using (public.has_perm(tenant_id, 'settings.manage')) with check (public.has_perm(tenant_id, 'settings.manage'));
create policy oo_read on public.open_orders for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
revoke insert, update, delete on public.open_orders from authenticated;
create trigger dining_tables_gate before insert on public.dining_tables for each row execute function public.module_gate('tables');

-- kitchen tickets from a list of lines (open orders); routing by category station as for sales
create or replace function public._kitchen_from_lines(p_tenant uuid, p_branch uuid, p_order uuid, p_ref text, p_type text, p_table text, p_lines jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare r record; v_default uuid; v_ticket uuid; n int := 0;
begin
  if not has_feature(p_tenant, 'kitchen') or jsonb_array_length(p_lines) = 0 then return 0; end if;
  select id into v_default from kitchen_stations where branch_id = p_branch and is_active order by is_default desc, sort, name limit 1;
  if v_default is null then return 0; end if;
  for r in
    select coalesce(ks.id, v_default) as station_id,
           jsonb_agg(jsonb_build_object('name', x->>'name', 'name_ar', i.name_ar, 'qty', (x->>'qty')::numeric, 'note', x->>'note') order by x->>'name') as items
      from jsonb_array_elements(p_lines) x
      left join items i on i.id = (x->>'item_id')::uuid
      left join categories c on c.id = i.category_id
      left join kitchen_stations ks on ks.id = c.station_id and ks.is_active and ks.branch_id = p_branch
     group by 1
  loop
    insert into kitchen_tickets(tenant_id, branch_id, station_id, open_order_id, order_ref, order_type, table_no)
    values (p_tenant, p_branch, r.station_id, p_order, p_ref, p_type, p_table) returning id into v_ticket;
    insert into kitchen_ticket_items(tenant_id, ticket_id, name, name_ar, qty, note)
    select p_tenant, v_ticket, x->>'name', x->>'name_ar', (x->>'qty')::numeric, x->>'note' from jsonb_array_elements(r.items) x;
    n := n + 1;
  end loop;
  return n;
end $$;

-- price a line with its add-ons the same way as checkout: [{key?, item_id, qty, modifiers:[option ids], note}] → names and prices
create or replace function public._price_lines(p_tenant uuid, p_lines jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l jsonb; it items%rowtype; v_out jsonb := '[]'; v_mods jsonb; v_add bigint; v_names text;
begin
  for l in select * from jsonb_array_elements(coalesce(p_lines,'[]')) loop
    select * into it from items where id = (l->>'item_id')::uuid and tenant_id = p_tenant;
    if not found or it.is_template or it.item_type = 'ingredient' then raise exception 'unknown item' using errcode = 'ZT422'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('option_id', o.id, 'name', o.name, 'name_ar', o.name_ar, 'price', o.price) order by g.sort, o.sort), '[]'),
           coalesce(sum(o.price), 0), string_agg(o.name, ', ' order by g.sort, o.sort)
      into v_mods, v_add, v_names
      from modifier_options o join modifier_groups g on g.id = o.group_id
     where o.tenant_id = p_tenant and o.is_active and o.id in (select jsonb_array_elements_text((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end))::uuid);
    v_out := v_out || jsonb_build_object('key', coalesce(l->>'key', gen_random_uuid()::text), 'item_id', it.id,
      'name', it.name || coalesce(' (' || v_names || ')', ''), 'qty', (l->>'qty')::numeric, 'unit_price', it.price + v_add,
      'modifiers', (select coalesce(jsonb_agg(x->'option_id'), '[]') from jsonb_array_elements(v_mods) x), 'modifier_names', v_names,
      'note', nullif(l->>'note',''), 'fired', coalesce((l->>'fired')::boolean, false), 'staff_id', l->'staff_id');
  end loop;
  return v_out;
end $$;

-- p = { id?, branch_id, table_id?, label?, guests?, customer_id?, lines:[...], fire?: boolean, approver_pin? }
-- lines already sent to the kitchen keep their quantities unless an approver allows a void
create or replace function public.save_open_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_tenant uuid; o open_orders%rowtype; v_lines jsonb; v_old jsonb; f jsonb; v_new jsonb;
  v_voided numeric := 0; v_fire jsonb; v_label text; v_tablename text;
begin
  select tenant_id into v_tenant from branches where id = v_branch;
  if v_tenant is null or not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'sale.create', null, null);
  perform _require_feature(v_tenant, 'tables');
  v_lines := _price_lines(v_tenant, p->'lines');
  if nullif(p->>'id','') is not null then
    select * into o from open_orders where id = (p->>'id')::uuid and tenant_id = v_tenant for update;
    if not found or o.status <> 'open' then raise exception 'this order is closed' using errcode = 'ZT422'; end if;
    -- fired lines: keep "fired"; reducing them is a void that needs approval
    for f in select * from jsonb_array_elements(o.lines) where (value->>'fired')::boolean loop
      select x into v_new from jsonb_array_elements(v_lines) x where x->>'key' = f->>'key';
      v_voided := v_voided + greatest((f->>'qty')::numeric - coalesce((v_new->>'qty')::numeric, 0), 0);
    end loop;
    if v_voided > 0 then perform _require(v_tenant, 'sale.cancel', null, p->>'approver_pin'); end if;
    select coalesce(jsonb_agg(case when exists (select 1 from jsonb_array_elements(o.lines) f2 where f2->>'key' = x->>'key' and (f2->>'fired')::boolean)
                                   then x || '{"fired": true}' else x end), '[]') into v_lines from jsonb_array_elements(v_lines) x;
  end if;
  select name into v_tablename from dining_tables where id = nullif(p->>'table_id','')::uuid and branch_id = v_branch;
  v_label := coalesce(nullif(p->>'label',''), v_tablename, o.label, 'Tab');
  if o.id is null then
    begin
      insert into open_orders(tenant_id, branch_id, table_id, label, guests, customer_id, lines, opened_by)
      values (v_tenant, v_branch, nullif(p->>'table_id','')::uuid, v_label, nullif(p->>'guests','')::int, nullif(p->>'customer_id','')::uuid, v_lines, auth.uid())
      returning * into o;
    exception when unique_violation then raise exception 'This table already has an open order' using errcode = 'ZT422'; end;
  else
    update open_orders set table_id = nullif(p->>'table_id','')::uuid, label = v_label, guests = nullif(p->>'guests','')::int,
           customer_id = nullif(p->>'customer_id','')::uuid, lines = v_lines, updated_at = now() where id = o.id returning * into o;
  end if;
  if coalesce((p->>'fire')::boolean, false) then
    select coalesce(jsonb_agg(x), '[]') into v_fire from jsonb_array_elements(o.lines) x where not coalesce((x->>'fired')::boolean, false);
    perform _kitchen_from_lines(v_tenant, v_branch, o.id, o.label, 'dine_in', v_tablename, v_fire);
    update open_orders set lines = (select jsonb_agg(x || '{"fired": true}') from jsonb_array_elements(lines) x) where id = o.id returning * into o;
  end if;
  return to_jsonb(o);
end $$;

create or replace function public.void_open_order(p_id uuid, p_reason text, p_approver_pin text default null) returns void
language plpgsql security definer set search_path = public as $$
declare o open_orders%rowtype; v_appr uuid;
begin
  select * into o from open_orders where id = p_id for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) or o.status <> 'open' then raise exception 'not found' using errcode = '42501'; end if;
  if exists (select 1 from jsonb_array_elements(o.lines) x where (x->>'fired')::boolean) then
    v_appr := _require(o.tenant_id, 'sale.cancel', null, p_approver_pin);
  end if;
  update open_orders set status = 'void', closed_at = now() where id = p_id;
  update kitchen_tickets set status = 'cancelled' where open_order_id = p_id and status in ('new','preparing');
  perform _audit(o.tenant_id, o.branch_id, 'open_order.void', 'open_order', o.id, null, p_reason, v_appr, jsonb_build_object('label', o.label));
end $$;

-- ================================================================ loyalty points
create table public.loyalty_ledger (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  customer_id uuid not null references public.customers(id),
  sale_id     uuid references public.sales(id),
  points      integer not null,
  kind        text not null check (kind in ('earn','redeem','reverse','adjust')),
  note        text,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index on public.loyalty_ledger(customer_id);
alter table public.loyalty_ledger enable row level security;
create policy ll_read on public.loyalty_ledger for select to authenticated using (public.is_member(tenant_id));
revoke insert, update, delete on public.loyalty_ledger from authenticated;
create trigger loyalty_ledger_immutable before update or delete on public.loyalty_ledger for each row execute function public.forbid_change();

create or replace function public.customer_points(p_customer uuid) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(sum(points), 0)::int from loyalty_ledger where customer_id = p_customer;
$$;

-- refunds take back the points the refunded share earned
create or replace function public.loyalty_on_refund() returns trigger language plpgsql security definer set search_path = public as $$
declare o sales%rowtype; v_earned int; v_back int;
begin
  if new.doc_type <> 'credit_note' or new.original_sale_id is null then return null; end if;
  select * into o from sales where id = new.original_sale_id;
  select coalesce(sum(points), 0) into v_earned from loyalty_ledger where sale_id = o.id and kind = 'earn';
  if v_earned <= 0 or o.customer_id is null or o.total = 0 then return null; end if;
  v_back := floor(v_earned * new.total::numeric / o.total);
  if v_back > 0 then
    insert into loyalty_ledger(tenant_id, customer_id, sale_id, points, kind, note) values (new.tenant_id, o.customer_id, new.id, -v_back, 'reverse', new.number);
  end if;
  return null;
end $$;
create constraint trigger sales_loyalty_refund after insert on public.sales deferrable initially deferred for each row execute function public.loyalty_on_refund();

-- ================================================================ checkout v4
-- p.lines[]: { item_id, qty, unit_price?, discount?, note?, modifiers?:[option ids], staff_id?, promo_discount?, customer_package_id? }
-- p: coupon?, appointment_id?, work_order_id?, open_order_id?, open_order_keys?:[keys paid now]
-- Server-side tenders (not sent by the POS): 'package' (sessions used from a customer package) and 'deposit' (earlier deposit).
create or replace function public.complete_sale(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
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
    if it.id is not null and (v_track or it.item_type = 'recipe' or v_mod_cost > 0) then v_cogs := v_cogs + round(v_qty * v_ucost)::bigint; end if;
    if nullif(l->>'staff_id','') is not null and not exists (select 1 from memberships where tenant_id = t.id and user_id = (l->>'staff_id')::uuid) then
      raise exception 'unknown staff member'; end if;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'item_type', it.item_type,
      'name', coalesce(nullif(l->>'name',''), it.name, 'Item') || coalesce(' (' || v_mod_names || ')', ''),
      'qty', v_qty, 'unit_price', v_price, 'discount', v_disc + v_pkg_disc, 'tax_rate', v_rate, 'net', v_net, 'tax', v_tax,
      'total', v_total_line, 'unit_cost', v_ucost, 'track', v_track, 'note', nullif(l->>'note',''), 'modifiers', case when jsonb_array_length(v_mods) > 0 then v_mods end,
      'staff_id', nullif(l->>'staff_id',''), 'promo_id', case when v_promo > 0 then (select x->>'promo_id' from jsonb_array_elements(v_allow) x where (x->>'idx')::int = v_idx) end,
      'promo_discount', v_promo, 'customer_package_id', cp.id, 'pkg_value', v_pkg_value);
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
  end loop;

  for pay in select * from jsonb_array_elements(v_tender_list) loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    insert into payments(tenant_id, sale_id, tender, amount, reference, status, shift_id, created_by)
    values (t.id, v_sale, v_tender, v_amt, nullif(pay->>'reference',''),
            case when v_tender = 'payment_link' then 'pending' else 'captured' end, v_shift, auth.uid())
    returning id into v_pid;
    if v_tender = 'payment_link' then insert into payment_links(tenant_id, sale_id, payment_id, amount) values (t.id, v_sale, v_pid, v_amt); end if;
    if v_tender not in ('on_account','payment_link') then v_captured := v_captured + v_amt; end if;
    v_je := v_je || jsonb_build_object('key', _tender_account(v_tender), 'debit', v_amt,
              'customer_id', case when v_tender in ('on_account','payment_link','store_credit','deposit') then v_customer end);
  end loop;
  update sales set paid_total = v_captured where id = v_sale;

  v_je := v_je || jsonb_build_array(
    jsonb_build_object('key','sales','credit', v_sub - v_sub_deferred),
    jsonb_build_object('key','deferred_revenue','credit', v_sub_deferred),
    jsonb_build_object('key','vat_payable','credit', v_taxsum),
    jsonb_build_object('key','cogs','debit', v_cogs),
    jsonb_build_object('key','inventory','credit', v_cogs));
  perform _post(t.id, v_branch, 'sale', v_sale, v_number, v_je);

  if v_manual > 0 then
    perform _audit(t.id, v_branch, 'sale.discount', 'sale', v_sale, v_manual, nullif(p->>'note',''), v_appr,
                   jsonb_build_object('percent', round(v_manual * 100.0 / nullif(v_list,0), 2)));
  end if;

  -- ---- loyalty: redeem, then earn on what was paid with money
  if v_loyalty > 0 then
    insert into loyalty_ledger(tenant_id, customer_id, sale_id, points, kind, created_by) values (t.id, v_customer, v_sale, -v_points, 'redeem', auth.uid());
  end if;
  if v_customer is not null and has_feature(t.id, 'loyalty') and coalesce((t.settings->>'loyalty_earn')::numeric, 0) > 0 then
    v_earn_base := v_total - v_loyalty - v_pkg_total - v_dep - v_sc_use;
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

  perform _consume_recipes(v_sale);
  if nullif(p->>'open_order_id','') is null then perform _kitchen_from_sale(v_sale, p); end if;
  return sale_json(v_sale);
end $$;

-- ================================================================ onboarding with the new defaults
create or replace function public.create_tenant(p jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  c countries%rowtype;
  v_tenant uuid;
  v_profile text;
  v_fam text;
  v_features jsonb;
begin
  if v_uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into c from countries where code = upper(coalesce(p->>'country_code',''));
  if not found then raise exception 'unknown country %', p->>'country_code'; end if;
  v_profile := coalesce(nullif(p->>'business_profile',''),
                 case coalesce(nullif(p->>'business_type',''),'retail') when 'food' then 'restaurant' when 'mixed' then 'restaurant'
                                                                        when 'services' then 'salon' else 'grocery' end);
  select family into v_fam from business_profiles where key = v_profile;
  if v_fam is null then raise exception 'unknown business type %', v_profile using errcode = 'ZT422'; end if;
  -- callers that still send only business_type (older apps, integrations) keep every built module, as before profiles existed
  -- callers that send only business_type (older apps) keep the five modules that existed before business types
  v_features := _profile_features(v_profile) || case when nullif(p->>'business_profile','') is null
                     then '{"kitchen":true,"recipes":true,"delivery":true,"credit":true,"purchasing":true}'::jsonb else '{}'::jsonb end;

  insert into tenants(name, name_ar, country_code, currency, currency_decimals, default_language, business_type, business_profile, features,
                      tax_number, vat_rate, prices_include_tax, brand_color)
  values (p->>'name', p->>'name_ar', c.code,
          coalesce(nullif(p->>'currency',''), c.currency), c.currency_decimals,
          coalesce(nullif(p->>'language',''), c.default_language),
          case when p->>'business_type' = 'mixed' then 'mixed' when v_fam = 'food' then 'food' when v_fam = 'services' then 'services' else 'retail' end::business_type,
          v_profile, v_features,
          nullif(p->>'tax_number',''),
          coalesce((p->>'vat_rate')::numeric, c.vat_rate),
          coalesce((p->>'prices_include_tax')::boolean, c.prices_include_tax),
          coalesce(nullif(p->>'brand_color',''), '#2346D8'))
  returning id into v_tenant;

  insert into branches(tenant_id, code, name, name_ar, address, timezone)
  values (v_tenant, 'B01', coalesce(nullif(p->>'branch_name',''), 'Main branch'), p->>'branch_name_ar',
          p->>'branch_address', c.timezone);

  perform _seed_roles(v_tenant);

  insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
  values (v_tenant, v_uid, 'owner', coalesce(nullif(p->>'display_name',''), 'Owner'),
          case when length(coalesce(p->>'pin','')) >= 4 then crypt(p->>'pin', gen_salt('bf')) end);

  insert into accounts(tenant_id, code, name_en, name_ar, type, system_key)
  select v_tenant, code, name_en, name_ar, type, system_key from coa_template;

  if (v_features->>'kitchen')::boolean then
    insert into kitchen_stations(tenant_id, branch_id, name, name_ar, is_default)
    select v_tenant, id, 'Kitchen', 'المطبخ', true from branches where tenant_id = v_tenant;
  end if;
  return v_tenant;
end $$;

-- ================================================================ the modules are built: switch them on where the business type expects them
update public.feature_modules set built = true
 where key in ('modifiers','variants','batches','weighed','promotions','appointments','commissions','memberships','tables','job_cards','preorders','loyalty');
update public.tenants t set features = t.features || coalesce((
  select jsonb_object_agg(m.key, true) from public.feature_modules m join public.business_profiles bp on bp.key = t.business_profile
   where m.built and bp.modules->>m.key = '2' and not t.features ? m.key), '{}');

grant execute on function public.save_work_order(jsonb), public.set_work_order_status(uuid, text),
  public.take_deposit(uuid, public.tender_type, bigint, text, uuid), public.refund_deposit(uuid, public.tender_type, text, uuid, text),
  public.save_open_order(jsonb), public.void_open_order(uuid, text, text), public.customer_points(uuid), public.complete_sale(jsonb) to authenticated;
revoke execute on function public._kitchen_from_lines(uuid, uuid, uuid, text, text, text, jsonb), public._price_lines(uuid, jsonb),
  public.loyalty_on_refund() from public, anon, authenticated;

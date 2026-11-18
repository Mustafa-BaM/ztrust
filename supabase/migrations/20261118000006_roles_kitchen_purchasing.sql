-- Z Trust MVP · role packages, kitchen display (KDS), purchasing
-- 1) Roles become per-business "packages" built from templates; the owner can add custom packages.
-- 2) Kitchen stations + tickets created atomically with the sale; KDS status flow with timestamps.
-- 3) Suppliers, purchase orders with amount-limited approval and segregation of duties, goods receipts.
-- 4) Security: internal helper functions are no longer executable by API roles.

-- ================================================================ 1. permission catalogue & role templates
create table public.permission_catalog (
  key        text primary key,
  module     text not null,
  name_en    text not null,
  name_ar    text not null,
  limit_kind text check (limit_kind in ('pct','money')),
  sort       integer not null default 0
);
insert into public.permission_catalog(key, module, name_en, name_ar, limit_kind, sort) values
  ('sale.create','sales','Sell at the POS','البيع في نقطة البيع',null,10),
  ('sale.discount','sales','Give discounts (max %)','منح خصومات (الحد الأقصى ٪)','pct',11),
  ('sale.refund','sales','Refund (max amount)','الاسترجاع (حد أقصى)','money',12),
  ('sale.cancel','sales','Cancel paid invoices (max amount)','إلغاء فواتير مدفوعة (حد أقصى)','money',13),
  ('sale.over_credit','sales','Sell above customer credit limit','البيع فوق حد ائتمان العميل',null,14),
  ('drawer.no_sale','sales','Open drawer without a sale','فتح الدرج بدون بيع',null,15),
  ('payments.receive','sales','Receive payments and send payment links','استلام دفعات وإرسال روابط الدفع',null,16),
  ('shift.view_expected','sales','See expected cash before counting','رؤية النقد المتوقع قبل العدّ',null,17),
  ('kds.view','kitchen','See the kitchen display','رؤية شاشة المطبخ',null,20),
  ('kds.bump','kitchen','Update kitchen tickets','تحديث طلبات المطبخ',null,21),
  ('catalog.manage','catalog','Manage products and prices','إدارة المنتجات والأسعار',null,30),
  ('customers.manage','catalog','Manage customers and credit limits','إدارة العملاء وحدود الائتمان',null,31),
  ('inventory.view','inventory','See stock levels','رؤية المخزون',null,40),
  ('inventory.receive','inventory','Receive goods','استلام البضاعة',null,41),
  ('inventory.adjust','inventory','Adjust stock and counts','تسوية وجرد المخزون',null,42),
  ('suppliers.manage','purchasing','Manage suppliers','إدارة الموردين',null,50),
  ('purchase.create','purchasing','Create purchase orders','إنشاء أوامر شراء',null,51),
  ('purchase.approve','purchasing','Approve purchase orders (max amount)','اعتماد أوامر الشراء (حد أقصى)','money',52),
  ('reports.all','reports','See reports for all branches','رؤية تقارير كل الفروع',null,60),
  ('reports.costs','reports','See costs and margins','رؤية التكلفة والهامش',null,61),
  ('reports.exceptions','reports','See exceptions report','رؤية تقرير الاستثناءات',null,62),
  ('finance.view','finance','See ledger and trial balance','رؤية القيود وميزان المراجعة',null,70),
  ('staff.manage','admin','Manage staff','إدارة الموظفين',null,80),
  ('settings.manage','admin','Manage business settings','إدارة إعدادات النشاط',null,81);

-- perms: {"permission": limit}. Money limits are in whole currency units and scaled per tenant when seeded.
create table public.role_templates (
  key            text primary key,
  name_en        text not null,
  name_ar        text not null,
  description_en text not null,
  description_ar text not null,
  sort           integer not null,
  perms          jsonb not null
);
insert into public.role_templates values
 ('owner','Owner','المالك','Everything, including roles and permissions','كل الصلاحيات بما فيها الأدوار',0,'{}'),
 ('manager','Branch manager','مدير فرع','Runs the branch: sales, stock, purchasing approval, staff, reports','يدير الفرع: المبيعات والمخزون واعتماد المشتريات والموظفين والتقارير',10,
  '{"sale.create":null,"sale.discount":30,"sale.refund":null,"sale.cancel":null,"sale.over_credit":null,"drawer.no_sale":null,"payments.receive":null,"shift.view_expected":null,"kds.view":null,"kds.bump":null,"catalog.manage":null,"customers.manage":null,"inventory.view":null,"inventory.receive":null,"inventory.adjust":null,"suppliers.manage":null,"purchase.create":null,"purchase.approve":1000,"reports.all":null,"reports.costs":null,"reports.exceptions":null,"finance.view":null,"staff.manage":null}'),
 ('supervisor','Shift supervisor','مشرف وردية','Approves discounts and refunds on the floor','يعتمد الخصومات والاسترجاع في الصالة',20,
  '{"sale.create":null,"sale.discount":15,"sale.refund":50,"sale.cancel":50,"drawer.no_sale":null,"payments.receive":null,"shift.view_expected":null,"kds.view":null,"kds.bump":null,"customers.manage":null,"inventory.view":null}'),
 ('cashier','Cashier','كاشير','Sells and takes payments; small discounts and refunds','يبيع ويستلم المدفوعات؛ خصم واسترجاع بحدود صغيرة',30,
  '{"sale.create":null,"sale.discount":5,"sale.refund":10,"payments.receive":null}'),
 ('waiter','Waiter','نادل','Takes orders and sends them to the kitchen','يأخذ الطلبات ويرسلها للمطبخ',40,'{"sale.create":null,"kds.view":null}'),
 ('kitchen','Kitchen / barista','مطبخ / باريستا','Sees and updates kitchen tickets only','يرى ويحدّث طلبات المطبخ فقط',50,'{"kds.view":null,"kds.bump":null}'),
 ('accountant','Accountant','محاسب','Ledger, reports, collections, suppliers','القيود والتقارير والتحصيل والموردين',60,
  '{"finance.view":null,"reports.all":null,"reports.costs":null,"reports.exceptions":null,"payments.receive":null,"suppliers.manage":null,"inventory.view":null}'),
 ('purchasing','Purchasing officer','مسؤول مشتريات','Suppliers and purchase orders; cannot approve or receive','الموردون وأوامر الشراء؛ لا يعتمد ولا يستلم',70,
  '{"suppliers.manage":null,"purchase.create":null,"inventory.view":null,"reports.costs":null}'),
 ('storekeeper','Storekeeper','أمين مخزن','Receives goods, counts and adjusts stock','يستلم البضاعة ويجرد ويسوّي المخزون',80,
  '{"inventory.view":null,"inventory.receive":null,"inventory.adjust":null}'),
 ('hr','HR','الموارد البشرية','Staff accounts and roles','حسابات الموظفين وأدوارهم',90,'{"staff.manage":null}'),
 ('auditor','Auditor','مدقق','Read-only access to every report and the ledger','اطلاع فقط على كل التقارير والقيود',100,
  '{"reports.all":null,"reports.costs":null,"reports.exceptions":null,"finance.view":null,"inventory.view":null}'),
 ('staff','Staff','موظف','No system access beyond their own profile','بدون صلاحيات على النظام',110,'{}');

create table public.roles (
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  key            text not null check (key ~ '^[a-z][a-z0-9_]{1,30}$'),
  name_en        text not null,
  name_ar        text not null,
  description_en text,
  description_ar text,
  template       text references public.role_templates(key),
  is_system      boolean not null default false,
  sort           integer not null default 100,
  created_at     timestamptz not null default now(),
  primary key (tenant_id, key)
);

-- ================================================================ 2. switch role columns from enum to role packages
drop policy memberships_write on public.memberships;
drop policy perms_write on public.role_permissions;
drop policy dl_write on public.dashboard_layouts;
drop function public.my_role(uuid);
drop function public.role_has(uuid, public.member_role, text);
drop function public.role_limit(uuid, public.member_role, text);

alter table public.memberships alter column role drop default;
alter table public.memberships alter column role type text using role::text;
alter table public.memberships alter column role set default 'cashier';
alter table public.role_permissions alter column role type text using role::text;
alter table public.dashboard_layouts alter column role type text using role::text;

create or replace function public._seed_roles(p_tenant uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u bigint;
begin
  select power(10, currency_decimals)::bigint into u from tenants where id = p_tenant;
  insert into roles(tenant_id, key, name_en, name_ar, description_en, description_ar, template, is_system, sort)
  select p_tenant, key, name_en, name_ar, description_en, description_ar, key, true, sort from role_templates
  on conflict do nothing;
  insert into role_permissions(tenant_id, role, permission, limit_value)
  select p_tenant, rt.key, p.key,
         case when pc.limit_kind = 'money' and p.value <> 'null'::jsonb then (p.value::text)::numeric * u
              when p.value = 'null'::jsonb then null else (p.value::text)::numeric end
    from role_templates rt cross join lateral jsonb_each(rt.perms) p
    join permission_catalog pc on pc.key = p.key
  on conflict do nothing;
end $$;

do $$ begin perform public._seed_roles(id) from public.tenants; end $$;

alter table public.memberships add constraint memberships_role_fk
  foreign key (tenant_id, role) references public.roles(tenant_id, key) on update cascade;
alter table public.role_permissions add constraint role_permissions_role_fk
  foreign key (tenant_id, role) references public.roles(tenant_id, key) on update cascade on delete cascade;
alter table public.role_permissions add constraint role_permissions_perm_fk
  foreign key (permission) references public.permission_catalog(key);
alter table public.dashboard_layouts add constraint dashboard_layouts_role_fk
  foreign key (tenant_id, role) references public.roles(tenant_id, key) on update cascade on delete cascade;
drop type public.member_role;

create or replace function public.my_role(p_tenant uuid) returns text
language sql stable security definer set search_path = public as $$
  select m.role from memberships m where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.is_active;
$$;
create or replace function public.role_has(p_tenant uuid, p_role text, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_role = 'owner' or exists (select 1 from role_permissions rp
    where rp.tenant_id = p_tenant and rp.role = p_role and rp.permission = p_perm);
$$;
create or replace function public.role_limit(p_tenant uuid, p_role text, p_perm text) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p_role = 'owner' then null
              else (select rp.limit_value from role_permissions rp
                    where rp.tenant_id = p_tenant and rp.role = p_role and rp.permission = p_perm) end;
$$;
create or replace function public.has_perm(p_tenant uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.role_has(p_tenant, public.my_role(p_tenant), p_perm), false);
$$;

create or replace function public._require(p_tenant uuid, p_perm text, p_value numeric, p_pin text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := my_role(p_tenant);
  v_lim numeric;
  v_approver uuid;
begin
  if v_role is null then raise exception 'not a member of this business' using errcode = '42501'; end if;
  if role_has(p_tenant, v_role, p_perm) then
    v_lim := role_limit(p_tenant, v_role, p_perm);
    if v_lim is null or p_value is null or p_value <= v_lim then return null; end if;
  end if;
  if p_pin is null or length(p_pin) < 4 then
    raise exception 'APPROVAL_REQUIRED:%', p_perm using errcode = 'ZT401';
  end if;
  select m.user_id into v_approver
    from memberships m
   where m.tenant_id = p_tenant and m.is_active and m.pin_hash is not null
     and m.pin_hash = crypt(p_pin, m.pin_hash)
     and role_has(p_tenant, m.role, p_perm)
     and (role_limit(p_tenant, m.role, p_perm) is null or p_value is null
          or p_value <= role_limit(p_tenant, m.role, p_perm))
   limit 1;
  if v_approver is null then
    raise exception 'APPROVAL_DENIED:%', p_perm using errcode = 'ZT403';
  end if;
  return v_approver;
end $$;

-- roles: members read; only the owner creates, renames or deletes custom packages
alter table public.roles enable row level security;
alter table public.permission_catalog enable row level security;
alter table public.role_templates enable row level security;
create policy roles_read on public.roles for select to authenticated using (public.is_member(tenant_id));
create policy roles_insert on public.roles for insert to authenticated
  with check (public.my_role(tenant_id) = 'owner' and not is_system);
create policy roles_update on public.roles for update to authenticated
  using (public.my_role(tenant_id) = 'owner' and key <> 'owner') with check (public.my_role(tenant_id) = 'owner' and key <> 'owner');
create policy roles_delete on public.roles for delete to authenticated
  using (public.my_role(tenant_id) = 'owner' and not is_system);
create policy pc_read on public.permission_catalog for select to authenticated using (true);
create policy rt_read on public.role_templates for select to authenticated using (true);

create policy memberships_write on public.memberships for all to authenticated
  using (public.has_perm(tenant_id, 'staff.manage') and role <> 'owner')
  with check (public.has_perm(tenant_id, 'staff.manage') and role <> 'owner');
create policy perms_write on public.role_permissions for all to authenticated
  using (public.my_role(tenant_id) = 'owner') with check (public.my_role(tenant_id) = 'owner' and role <> 'owner');
create policy dl_write on public.dashboard_layouts for all to authenticated
  using (public.my_role(tenant_id) = 'owner') with check (public.my_role(tenant_id) = 'owner');

-- the role key cannot be renamed once created (names can)
create or replace function public.guard_role_key() returns trigger language plpgsql as $$
begin
  if new.key <> old.key or new.tenant_id <> old.tenant_id or new.is_system <> old.is_system then
    raise exception 'role key and type cannot change' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger roles_guard before update on public.roles for each row execute function public.guard_role_key();

-- onboarding now seeds the role packages
create or replace function public.create_tenant(p jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  c countries%rowtype;
  v_tenant uuid;
begin
  if v_uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into c from countries where code = upper(coalesce(p->>'country_code',''));
  if not found then raise exception 'unknown country %', p->>'country_code'; end if;

  insert into tenants(name, name_ar, country_code, currency, currency_decimals, default_language, business_type,
                      tax_number, vat_rate, prices_include_tax, brand_color)
  values (p->>'name', p->>'name_ar', c.code,
          coalesce(nullif(p->>'currency',''), c.currency), c.currency_decimals,
          coalesce(nullif(p->>'language',''), c.default_language),
          coalesce(nullif(p->>'business_type','')::business_type, 'retail'),
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

  -- food businesses start with one kitchen station so the KDS works immediately
  if coalesce(nullif(p->>'business_type',''),'retail') in ('food','mixed') then
    insert into kitchen_stations(tenant_id, branch_id, name, name_ar, is_default)
    select v_tenant, id, 'Kitchen', 'المطبخ', true from branches where tenant_id = v_tenant;
  end if;
  return v_tenant;
end $$;

-- ================================================================ 3. kitchen
create table public.kitchen_stations (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  branch_id     uuid not null references public.branches(id) on delete cascade,
  name          text not null,
  name_ar       text,
  mode          text not null default 'kds' check (mode in ('kds','printer','both')),
  alert_minutes integer not null default 10 check (alert_minutes between 1 and 240),
  is_default    boolean not null default false,
  is_active     boolean not null default true,
  sort          integer not null default 0
);
create unique index kitchen_one_default on public.kitchen_stations(branch_id) where is_default;

alter table public.categories add column station_id uuid references public.kitchen_stations(id) on delete set null;
alter table public.sale_lines add column note text;

create table public.kitchen_tickets (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  station_id  uuid not null references public.kitchen_stations(id),
  sale_id     uuid references public.sales(id),
  order_ref   text not null,
  order_type  text not null default 'takeaway' check (order_type in ('dine_in','takeaway','delivery','pickup')),
  table_no    text,
  customer_name text,
  note        text,
  status      text not null default 'new' check (status in ('new','preparing','ready','served','cancelled')),
  created_at  timestamptz not null default now(),
  started_at  timestamptz,
  ready_at    timestamptz,
  served_at   timestamptz,
  updated_by  uuid
);
create index on public.kitchen_tickets(branch_id, status, created_at);

create table public.kitchen_ticket_items (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  ticket_id uuid not null references public.kitchen_tickets(id) on delete cascade,
  name      text not null,
  name_ar   text,
  qty       numeric(14,3) not null,
  note      text,
  done      boolean not null default false
);
create index on public.kitchen_ticket_items(ticket_id);

alter table public.kitchen_stations enable row level security;
alter table public.kitchen_tickets enable row level security;
alter table public.kitchen_ticket_items enable row level security;
create policy ks_read on public.kitchen_stations for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy ks_write on public.kitchen_stations for all to authenticated
  using (public.has_perm(tenant_id, 'settings.manage')) with check (public.has_perm(tenant_id, 'settings.manage'));
create policy kt_read on public.kitchen_tickets for select to authenticated
  using (public.can_see_branch(tenant_id, branch_id) and public.has_perm(tenant_id, 'kds.view'));
create policy kti_read on public.kitchen_ticket_items for select to authenticated
  using (exists (select 1 from public.kitchen_tickets k where k.id = ticket_id
                 and public.can_see_branch(k.tenant_id, k.branch_id) and public.has_perm(k.tenant_id, 'kds.view')));
revoke insert, update, delete on public.kitchen_tickets, public.kitchen_ticket_items from anon, authenticated;

-- one ticket per station for the lines of a sale; routing: category station → branch default → first active station
create or replace function public._kitchen_from_sale(p_sale uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s sales%rowtype; k jsonb := p->'kitchen'; r record; v_ticket uuid; v_default uuid;
begin
  if k is null or jsonb_typeof(k) <> 'object' then return; end if;
  select * into s from sales where id = p_sale;
  select id into v_default from kitchen_stations where branch_id = s.branch_id and is_active
   order by is_default desc, sort, name limit 1;
  if v_default is null then return; end if;
  for r in
    select coalesce(ks.id, v_default) as station_id,
           jsonb_agg(jsonb_build_object('name', l.name, 'name_ar', i.name_ar, 'qty', l.qty, 'note', l.note) order by l.name) as items
      from sale_lines l
      left join items i on i.id = l.item_id
      left join categories c on c.id = i.category_id
      left join kitchen_stations ks on ks.id = c.station_id and ks.is_active and ks.branch_id = s.branch_id
     where l.sale_id = s.id
     group by 1
  loop
    insert into kitchen_tickets(tenant_id, branch_id, station_id, sale_id, order_ref, order_type, table_no, customer_name, note)
    values (s.tenant_id, s.branch_id, r.station_id, s.id, s.number,
            coalesce(nullif(k->>'order_type',''),'takeaway'), nullif(k->>'table_no',''),
            coalesce(nullif(k->>'customer_name',''), (select name from customers where id = s.customer_id)),
            nullif(k->>'note',''))
    returning id into v_ticket;
    insert into kitchen_ticket_items(tenant_id, ticket_id, name, name_ar, qty, note)
    select s.tenant_id, v_ticket, x->>'name', x->>'name_ar', (x->>'qty')::numeric, x->>'note'
      from jsonb_array_elements(r.items) x;
  end loop;
end $$;

create or replace function public.kds_set_status(p_ticket uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k kitchen_tickets%rowtype;
begin
  select * into k from kitchen_tickets where id = p_ticket for update;
  if not found or not can_see_branch(k.tenant_id, k.branch_id) then raise exception 'ticket not found'; end if;
  perform _require(k.tenant_id, 'kds.bump', null, null);
  if not ((k.status, p_status) in (('new','preparing'),('new','ready'),('preparing','ready'),('ready','served'),
                                   ('ready','preparing'),('served','ready'),('new','cancelled'),('preparing','cancelled'))) then
    raise exception 'cannot move a % ticket to %', k.status, p_status using errcode = 'ZT422';
  end if;
  update kitchen_tickets set status = p_status, updated_by = auth.uid(),
         started_at = case when p_status = 'preparing' then coalesce(started_at, now()) else started_at end,
         ready_at   = case when p_status = 'ready' then now() when p_status = 'preparing' then null else ready_at end,
         served_at  = case when p_status = 'served' then now() when p_status = 'ready' then null else served_at end
   where id = k.id returning * into k;
  return to_jsonb(k);
end $$;

create or replace function public.kds_toggle_item(p_item uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_done boolean; v_tenant uuid; v_branch uuid;
begin
  select k.tenant_id, k.branch_id into v_tenant, v_branch
    from kitchen_ticket_items i join kitchen_tickets k on k.id = i.ticket_id where i.id = p_item;
  if v_tenant is null or not can_see_branch(v_tenant, v_branch) then raise exception 'item not found'; end if;
  perform _require(v_tenant, 'kds.bump', null, null);
  update kitchen_ticket_items set done = not done where id = p_item returning done into v_done;
  return v_done;
end $$;

-- a cancelled invoice pulls its open tickets from the kitchen
create or replace function public.cancel_kitchen_on_sale_cancel() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    update kitchen_tickets set status = 'cancelled' where sale_id = new.id and status in ('new','preparing');
  end if;
  return new;
end $$;
create trigger sales_cancel_kitchen after update of status on public.sales
  for each row execute function public.cancel_kitchen_on_sale_cancel();

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.kitchen_tickets;
  end if;
end $$;

-- complete_sale: line notes + kitchen tickets (same transaction as the sale)
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
  v_lines jsonb := '[]'; v_je jsonb := '[]'; v_pid uuid; v_tender tender_type; v_amt bigint;
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
    if it.id is not null and it.track_stock then v_cogs := v_cogs + round(v_qty * it.cost)::bigint; end if;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'name', coalesce(nullif(l->>'name',''), it.name, 'Item'),
      'qty', v_qty, 'unit_price', v_price, 'discount', v_disc, 'tax_rate', v_rate, 'net', v_net, 'tax', v_tax,
      'total', v_total_line, 'unit_cost', coalesce(it.cost,0), 'track', coalesce(it.track_stock,false), 'note', nullif(l->>'note',''));
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
                    tax_total, total, paid_total, approved_by, created_by, device_created_at, reason)
  values (t.id, v_branch, v_shift, v_client, 'invoice', v_number, v_customer, v_sub, v_discount_total, v_taxsum, v_total, 0,
          v_appr, auth.uid(), nullif(p->>'device_created_at','')::timestamptz, nullif(p->>'note',''))
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
  perform _kitchen_from_sale(v_sale, p);
  return sale_json(v_sale);
end $$;


-- ================================================================ 4. purchasing
alter type public.doc_type add value if not exists 'purchase_order';
alter table public.journal_lines add column supplier_id uuid;

create table public.suppliers (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  name          text not null,
  name_ar       text,
  phone         text,
  email         text,
  tax_number    text,
  payment_terms_days integer not null default 30,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
alter table public.journal_lines add constraint journal_lines_supplier_fk foreign key (supplier_id) references public.suppliers(id);

-- journal posting now also carries an optional supplier dimension
create or replace function public._post(p_tenant uuid, p_branch uuid, p_source text, p_source_id uuid,
                                        p_memo text, p_lines jsonb) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_dr bigint := 0; v_cr bigint := 0; v_prev text; v_hash text; v_id bigint; l jsonb;
begin
  -- drop zero lines, check balance
  select coalesce(sum((x->>'debit')::bigint),0), coalesce(sum((x->>'credit')::bigint),0)
    into v_dr, v_cr
    from jsonb_array_elements(p_lines) x;
  if v_dr <> v_cr then
    raise exception 'unbalanced journal: debit % credit %', v_dr, v_cr;
  end if;
  if v_dr = 0 then return null; end if;

  perform pg_advisory_xact_lock(hashtext('je:' || p_tenant::text));
  select hash into v_prev from journal_entries where tenant_id = p_tenant order by id desc limit 1;
  v_hash := encode(digest(coalesce(v_prev,'') || p_source || coalesce(p_source_id::text,'') || p_lines::text || clock_timestamp()::text, 'sha256'), 'hex');

  insert into journal_entries(tenant_id, branch_id, source_type, source_id, memo, prev_hash, hash, created_by)
  values (p_tenant, p_branch, p_source, p_source_id, p_memo, v_prev, v_hash, auth.uid())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'debit')::bigint,0) = 0 and coalesce((l->>'credit')::bigint,0) = 0 then continue; end if;
    insert into journal_lines(tenant_id, entry_id, account_id, branch_id, debit, credit, customer_id, supplier_id)
    values (p_tenant, v_id, _acct(p_tenant, l->>'key'), p_branch,
            coalesce((l->>'debit')::bigint,0), coalesce((l->>'credit')::bigint,0),
            nullif(l->>'customer_id','')::uuid, nullif(l->>'supplier_id','')::uuid);
  end loop;
  return v_id;
end $$;

create table public.purchase_orders (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  supplier_id uuid not null references public.suppliers(id),
  number      text not null,
  status      text not null default 'draft' check (status in ('draft','approved','partially_received','received','cancelled')),
  total       bigint not null default 0,
  note        text,
  expected_at date,
  created_by  uuid not null,
  approved_by uuid,
  approved_at timestamptz,
  cancelled_reason text,
  created_at  timestamptz not null default now(),
  unique (tenant_id, number)
);
create index on public.purchase_orders(tenant_id, status, created_at desc);

create table public.purchase_order_lines (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  po_id        uuid not null references public.purchase_orders(id) on delete cascade,
  item_id      uuid not null references public.items(id),
  qty          numeric(14,3) not null check (qty > 0),
  unit_cost    bigint not null check (unit_cost >= 0),
  received_qty numeric(14,3) not null default 0
);
create index on public.purchase_order_lines(po_id);

create table public.goods_receipts (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  po_id        uuid not null references public.purchase_orders(id),
  branch_id    uuid not null references public.branches(id),
  supplier_ref text,
  note         text,
  total        bigint not null,
  received_by  uuid not null,
  created_at   timestamptz not null default now()
);

create or replace function public.can_purchasing(p_tenant uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select has_perm(p_tenant,'suppliers.manage') or has_perm(p_tenant,'purchase.create') or has_perm(p_tenant,'purchase.approve')
      or has_perm(p_tenant,'inventory.receive') or has_perm(p_tenant,'finance.view');
$$;

alter table public.suppliers enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.goods_receipts enable row level security;
create policy sup_read  on public.suppliers for select to authenticated using (public.can_purchasing(tenant_id));
create policy sup_write on public.suppliers for all to authenticated
  using (public.has_perm(tenant_id,'suppliers.manage')) with check (public.has_perm(tenant_id,'suppliers.manage'));
create policy po_read  on public.purchase_orders for select to authenticated
  using (public.can_purchasing(tenant_id) and public.can_see_branch(tenant_id, branch_id));
create policy pol_read on public.purchase_order_lines for select to authenticated
  using (exists (select 1 from public.purchase_orders o where o.id = po_id and public.can_purchasing(o.tenant_id) and public.can_see_branch(o.tenant_id, o.branch_id)));
create policy gr_read  on public.goods_receipts for select to authenticated
  using (public.can_purchasing(tenant_id) and public.can_see_branch(tenant_id, branch_id));
revoke insert, update, delete on public.purchase_orders, public.purchase_order_lines, public.goods_receipts from anon, authenticated;

create or replace function public._next_number(p_tenant uuid, p_branch uuid, p_doc public.doc_type) returns text
language plpgsql security definer set search_path = public as $$
declare v_no bigint; v_code text;
begin
  insert into doc_sequences(tenant_id, branch_id, doc_type, next_no) values (p_tenant, p_branch, p_doc, 2)
  on conflict (tenant_id, branch_id, doc_type) do update set next_no = doc_sequences.next_no + 1
  returning next_no - 1 into v_no;
  select code into v_code from branches where id = p_branch;
  return v_code || '-' || case p_doc::text when 'invoice' then 'INV' when 'credit_note' then 'CN' else 'PO' end
         || '-' || lpad(v_no::text, 6, '0');
end $$;

-- p = { id?, tenant_id, branch_id, supplier_id, note?, expected_at?, lines: [{ item_id, qty, unit_cost }] }
create or replace function public.save_po(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid := (p->>'tenant_id')::uuid; v_branch uuid := (p->>'branch_id')::uuid;
  v_id uuid := nullif(p->>'id','')::uuid; o purchase_orders%rowtype; l jsonb; v_total bigint := 0;
begin
  if not is_member(v_tenant) or not can_see_branch(v_tenant, v_branch) then raise exception 'not allowed' using errcode='42501'; end if;
  perform _require(v_tenant, 'purchase.create', null, null);
  if not exists (select 1 from suppliers where id = (p->>'supplier_id')::uuid and tenant_id = v_tenant and is_active) then
    raise exception 'choose a supplier'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'add at least one item'; end if;
  for l in select * from jsonb_array_elements(p->'lines') loop
    if not exists (select 1 from items where id = (l->>'item_id')::uuid and tenant_id = v_tenant) then raise exception 'unknown item'; end if;
    if (l->>'qty')::numeric <= 0 or (l->>'unit_cost')::bigint < 0 then raise exception 'quantity and cost must be positive'; end if;
    v_total := v_total + round((l->>'qty')::numeric * (l->>'unit_cost')::bigint)::bigint;
  end loop;

  if v_id is null then
    insert into purchase_orders(tenant_id, branch_id, supplier_id, number, note, expected_at, created_by, total)
    values (v_tenant, v_branch, (p->>'supplier_id')::uuid, _next_number(v_tenant, v_branch, 'purchase_order'),
            nullif(p->>'note',''), nullif(p->>'expected_at','')::date, auth.uid(), v_total)
    returning id into v_id;
  else
    select * into o from purchase_orders where id = v_id and tenant_id = v_tenant for update;
    if not found then raise exception 'purchase order not found'; end if;
    if o.status <> 'draft' then raise exception 'only draft orders can be edited' using errcode = 'ZT422'; end if;
    update purchase_orders set supplier_id = (p->>'supplier_id')::uuid, note = nullif(p->>'note',''),
           expected_at = nullif(p->>'expected_at','')::date, total = v_total where id = v_id;
    delete from purchase_order_lines where po_id = v_id;
  end if;
  insert into purchase_order_lines(tenant_id, po_id, item_id, qty, unit_cost)
  select v_tenant, v_id, (x->>'item_id')::uuid, (x->>'qty')::numeric, (x->>'unit_cost')::bigint
    from jsonb_array_elements(p->'lines') x;
  return v_id;
end $$;

-- segregation of duties: the creator of an order can never be its approver (the owner is exempt)
create or replace function public.approve_po(p_po uuid, p_pin text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare o purchase_orders%rowtype; v_appr uuid; v_actor uuid; v_self boolean;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'purchase order not found'; end if;
  if o.status <> 'draft' then raise exception 'only draft orders can be approved' using errcode = 'ZT422'; end if;
  v_self := o.created_by = auth.uid() and my_role(o.tenant_id) <> 'owner';
  if v_self then
    -- the creator cannot approve: another person with enough limit must enter their PIN
    if coalesce(p_pin,'') = '' then raise exception 'APPROVAL_REQUIRED:purchase.approve' using errcode = 'ZT401'; end if;
    select m.user_id into v_appr from memberships m
     where m.tenant_id = o.tenant_id and m.is_active and m.user_id <> o.created_by
       and m.pin_hash is not null and m.pin_hash = crypt(p_pin, m.pin_hash)
       and role_has(o.tenant_id, m.role, 'purchase.approve')
       and (role_limit(o.tenant_id, m.role, 'purchase.approve') is null or o.total <= role_limit(o.tenant_id, m.role, 'purchase.approve'))
     limit 1;
    if v_appr is null then raise exception 'APPROVAL_DENIED:purchase.approve' using errcode = 'ZT403'; end if;
  else
    v_appr := _require(o.tenant_id, 'purchase.approve', o.total, p_pin);
  end if;
  v_actor := coalesce(v_appr, auth.uid());
  if v_actor = o.created_by and (select role from memberships where tenant_id = o.tenant_id and user_id = v_actor) <> 'owner' then
    raise exception 'APPROVAL_DENIED:purchase.approve' using errcode = 'ZT403';
  end if;
  update purchase_orders set status = 'approved', approved_by = v_actor, approved_at = now() where id = o.id returning * into o;
  perform _audit(o.tenant_id, o.branch_id, 'purchase.approve', 'purchase_order', o.id, o.total, o.number, v_appr);
  return to_jsonb(o);
end $$;

create or replace function public.cancel_po(p_po uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare o purchase_orders%rowtype;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'purchase order not found'; end if;
  if not (has_perm(o.tenant_id,'purchase.create') or has_perm(o.tenant_id,'purchase.approve')) then
    raise exception 'not allowed' using errcode = '42501'; end if;
  if o.status not in ('draft','approved') then raise exception 'orders with receipts cannot be cancelled' using errcode = 'ZT422'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'a reason is required' using errcode = 'ZT422'; end if;
  update purchase_orders set status = 'cancelled', cancelled_reason = p_reason where id = o.id;
  perform _audit(o.tenant_id, o.branch_id, 'purchase.cancel', 'purchase_order', o.id, o.total, p_reason, null);
end $$;

-- p = { po_id, supplier_ref?, note?, lines: [{ line_id, qty }] }
create or replace function public.receive_po(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  o purchase_orders%rowtype; ol purchase_order_lines%rowtype; it items%rowtype;
  e jsonb; v_qty numeric; v_onhand numeric; v_gr uuid; v_total bigint := 0; v_any boolean := false;
begin
  select * into o from purchase_orders where id = (p->>'po_id')::uuid for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'purchase order not found'; end if;
  perform _require(o.tenant_id, 'inventory.receive', null, null);
  if o.status not in ('approved','partially_received') then raise exception 'the order must be approved before receiving' using errcode = 'ZT422'; end if;

  insert into goods_receipts(tenant_id, po_id, branch_id, supplier_ref, note, total, received_by)
  values (o.tenant_id, o.id, o.branch_id, nullif(p->>'supplier_ref',''), nullif(p->>'note',''), 0, auth.uid())
  returning id into v_gr;

  for e in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    v_qty := (e->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then continue; end if;
    select * into ol from purchase_order_lines where id = (e->>'line_id')::uuid and po_id = o.id for update;
    if not found then raise exception 'line not on this order'; end if;
    if v_qty > ol.qty - ol.received_qty then raise exception 'cannot receive more than ordered' using errcode = 'ZT422'; end if;
    select * into it from items where id = ol.item_id for update;
    select coalesce(sum(qty),0) into v_onhand from stock_movements where item_id = it.id;
    update items set cost = case when greatest(v_onhand,0) + v_qty = 0 then ol.unit_cost
                     else round((greatest(v_onhand,0) * it.cost + v_qty * ol.unit_cost) / (greatest(v_onhand,0) + v_qty)) end
     where id = it.id;
    insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
    values (o.tenant_id, o.branch_id, it.id, v_qty, 'receipt', v_gr, ol.unit_cost, o.number, auth.uid());
    update purchase_order_lines set received_qty = received_qty + v_qty where id = ol.id;
    v_total := v_total + round(v_qty * ol.unit_cost)::bigint; v_any := true;
  end loop;
  if not v_any then raise exception 'enter at least one received quantity' using errcode = 'ZT422'; end if;

  update goods_receipts set total = v_total where id = v_gr;
  update purchase_orders set status = case when exists (select 1 from purchase_order_lines where po_id = o.id and received_qty < qty)
                                           then 'partially_received' else 'received' end where id = o.id;
  perform _post(o.tenant_id, o.branch_id, 'goods_receipt', v_gr, o.number, jsonb_build_array(
    jsonb_build_object('key','inventory','debit', v_total),
    jsonb_build_object('key','ap','credit', v_total, 'supplier_id', o.supplier_id)));
  return v_gr;
end $$;

-- ad-hoc receipts (without a PO) now need inventory.receive
create or replace function public.receive_stock(p_branch uuid, p_item uuid, p_qty numeric, p_unit_cost bigint, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare it items%rowtype; v_onhand numeric; v_val bigint;
begin
  select * into it from items where id = p_item for update;
  if not found or not can_see_branch(it.tenant_id, p_branch) then raise exception 'not allowed' using errcode='42501'; end if;
  perform _require(it.tenant_id, 'inventory.receive', null, null);
  if p_qty <= 0 or p_unit_cost < 0 then raise exception 'quantity must be positive'; end if;
  select coalesce(sum(qty),0) into v_onhand from stock_movements where item_id = p_item;
  update items set cost = case when greatest(v_onhand,0) + p_qty = 0 then p_unit_cost
                   else round((greatest(v_onhand,0) * it.cost + p_qty * p_unit_cost) / (greatest(v_onhand,0) + p_qty)) end
   where id = p_item;
  insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost, note, created_by)
  values (it.tenant_id, p_branch, p_item, p_qty, 'receipt', p_unit_cost, p_note, auth.uid());
  v_val := round(p_qty * p_unit_cost)::bigint;
  perform _post(it.tenant_id, p_branch, 'stock_receipt', p_item, coalesce(p_note, it.name), jsonb_build_array(
    jsonb_build_object('key','inventory','debit',v_val), jsonb_build_object('key','ap','credit',v_val)));
end $$;

-- ================================================================ 5. function privileges (deny by default)
-- Internal helpers (_post, _require, _seed_roles, …) run only inside SECURITY DEFINER functions.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.create_tenant(jsonb), public.set_my_pin(uuid,text), public.open_shift(uuid,bigint), public.close_shift(uuid,bigint),
  public.shift_summary(uuid), public.log_drawer_open(uuid,text,text), public.complete_sale(jsonb), public.refund_sale(jsonb),
  public.receive_payment(uuid,public.tender_type,bigint,text,uuid), public.create_payment_link(uuid,bigint),
  public.adjust_stock(uuid,uuid,numeric,text), public.receive_stock(uuid,uuid,numeric,bigint,text), public.sale_json(uuid),
  public.customer_balance(uuid), public.customer_store_credit(uuid),
  public.is_member(uuid), public.my_role(uuid), public.can_see_branch(uuid,uuid), public.has_perm(uuid,text),
  public.role_has(uuid,text,text), public.role_limit(uuid,text,text), public.can_purchasing(uuid),
  public.kds_set_status(uuid,text), public.kds_toggle_item(uuid),
  public.save_po(jsonb), public.approve_po(uuid,text), public.cancel_po(uuid,text), public.receive_po(jsonb)
  to authenticated;
grant execute on function public.payment_link_info(text) to anon, authenticated;
grant execute on function public.mark_payment_link_paid(text,text) to service_role;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

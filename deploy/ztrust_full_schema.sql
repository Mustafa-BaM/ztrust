-- Z Trust: full database for a new Supabase project. Paste into SQL Editor and Run once.

-- ===== 20261118000001_core.sql
-- Z Trust MVP · core schema
-- Money is stored as bigint minor units (fils, halalas, cents). Each tenant has currency_decimals (KWD/BHD/OMR = 3).
-- Every tenant table carries tenant_id and is protected by RLS through memberships.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- enums
create type public.business_type as enum ('retail','food','services','mixed');
create type public.member_role   as enum ('owner','manager','supervisor','cashier','accountant','staff');
create type public.tender_type   as enum ('cash','card','on_account','payment_link','bank_transfer','store_credit','other');
create type public.doc_type      as enum ('invoice','credit_note');
create type public.account_type  as enum ('asset','liability','equity','income','expense');

-- ---------------------------------------------------------------- reference data
create table public.countries (
  code              char(2) primary key,
  name_en           text not null,
  name_ar           text not null,
  currency          char(3) not null,
  currency_decimals smallint not null default 2,
  vat_rate          numeric(5,2) not null default 0,
  prices_include_tax boolean not null default true,
  einvoice_regime   text,               -- 'zatca' | 'uae_asp' | 'oman_fawtara' | null
  default_language  text not null default 'en',
  timezone          text not null default 'UTC'
);

create table public.coa_template (
  system_key text primary key,
  code       text not null,
  name_en    text not null,
  name_ar    text not null,
  type       public.account_type not null
);

-- ---------------------------------------------------------------- tenants & people
create table public.tenants (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  name_ar           text,
  country_code      char(2) not null references public.countries(code),
  currency          char(3) not null,
  currency_decimals smallint not null,
  default_language  text not null default 'en',
  business_type     public.business_type not null default 'retail',
  tax_number        text,
  vat_rate          numeric(5,2) not null default 0,
  prices_include_tax boolean not null default true,
  brand_color       text default '#2346D8',
  logo_url          text,
  plan              text not null default 'trial',
  trial_ends_at     timestamptz not null default now() + interval '7 days',
  created_at        timestamptz not null default now()
);

create table public.memberships (
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  user_id      uuid not null,
  role         public.member_role not null default 'cashier',
  display_name text not null default '',
  pin_hash     text,                -- bcrypt of the 4–6 digit POS / approval PIN
  branch_ids   uuid[],              -- null = all branches
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  primary key (tenant_id, user_id)
);
create index on public.memberships(user_id);

-- permission rows: limit_value meaning depends on the permission
--   sale.discount        → max discount % of the sale
--   sale.refund          → max refund amount (minor units)
--   sale.cancel          → max invoice amount (minor units)
--   other permissions    → null = allowed
create table public.role_permissions (
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  role        public.member_role not null,
  permission  text not null,
  limit_value numeric,
  primary key (tenant_id, role, permission)
);

create table public.branches (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  code        text not null,
  name        text not null,
  name_ar     text,
  address     text,
  lat         double precision,
  lng         double precision,
  geofence_m  integer not null default 150,
  timezone    text not null default 'UTC',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (tenant_id, code)
);

-- ---------------------------------------------------------------- catalog
create table public.categories (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name      text not null,
  name_ar   text,
  color     text,
  sort      integer not null default 0
);

create table public.items (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  category_id uuid references public.categories(id) on delete set null,
  name        text not null,
  name_ar     text,
  sku         text,
  barcode     text,
  price       bigint not null default 0 check (price >= 0),
  cost        bigint not null default 0 check (cost >= 0),
  tax_rate    numeric(5,2),              -- null = tenant default
  track_stock boolean not null default true,
  is_active   boolean not null default true,
  image_url   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index items_barcode_uq on public.items(tenant_id, barcode) where barcode is not null;
create unique index items_sku_uq     on public.items(tenant_id, sku)     where sku is not null;
create index on public.items(tenant_id, category_id);

create table public.customers (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  name         text not null,
  phone        text,
  email        text,
  credit_limit bigint not null default 0 check (credit_limit >= 0),
  created_at   timestamptz not null default now()
);
create unique index customers_phone_uq on public.customers(tenant_id, phone) where phone is not null;

-- ---------------------------------------------------------------- inventory (append-only movements)
create table public.stock_movements (
  id         bigint generated always as identity primary key,
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  branch_id  uuid not null references public.branches(id),
  item_id    uuid not null references public.items(id),
  qty        numeric(14,3) not null,
  reason     text not null check (reason in ('sale','refund','adjustment','receipt','count','transfer_in','transfer_out')),
  ref_id     uuid,
  unit_cost  bigint not null default 0,
  note       text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index on public.stock_movements(tenant_id, branch_id, item_id);

-- ---------------------------------------------------------------- shifts
create table public.shifts (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  branch_id     uuid not null references public.branches(id),
  opened_by     uuid not null,
  opened_at     timestamptz not null default now(),
  opening_float bigint not null default 0,
  closed_by     uuid,
  closed_at     timestamptz,
  expected_cash bigint,
  counted_cash  bigint,
  variance      bigint
);
create unique index shifts_one_open_per_user on public.shifts(tenant_id, branch_id, opened_by) where closed_at is null;

-- ---------------------------------------------------------------- sales documents
create table public.doc_sequences (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  doc_type  public.doc_type not null,
  next_no   bigint not null default 1,
  primary key (tenant_id, branch_id, doc_type)
);

create table public.sales (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  branch_id        uuid not null references public.branches(id),
  shift_id         uuid references public.shifts(id),
  client_id        uuid not null,                 -- idempotency key generated on the device
  doc_type         public.doc_type not null default 'invoice',
  number           text not null,
  original_sale_id uuid references public.sales(id),
  customer_id      uuid references public.customers(id),
  subtotal         bigint not null,               -- net of tax, after discounts
  discount_total   bigint not null default 0,
  tax_total        bigint not null,
  total            bigint not null,
  paid_total       bigint not null default 0,     -- captured payments (pending links excluded)
  refunded_total   bigint not null default 0,
  status           text not null default 'completed' check (status in ('completed','partially_refunded','refunded','cancelled')),
  reason           text,
  approved_by      uuid,
  created_by       uuid not null,
  device_created_at timestamptz,
  created_at       timestamptz not null default now(),
  unique (tenant_id, client_id),
  unique (tenant_id, number)
);
create index on public.sales(tenant_id, branch_id, created_at desc);
create index on public.sales(tenant_id, customer_id);

create table public.sale_lines (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  sale_id       uuid not null references public.sales(id) on delete cascade,
  original_line_id uuid references public.sale_lines(id),
  item_id       uuid references public.items(id),
  name          text not null,
  qty           numeric(14,3) not null check (qty > 0),
  unit_price    bigint not null,
  discount      bigint not null default 0,
  tax_rate      numeric(5,2) not null,
  net_amount    bigint not null,
  tax_amount    bigint not null,
  line_total    bigint not null,
  unit_cost     bigint not null default 0
);
create index on public.sale_lines(sale_id);

create table public.payments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  sale_id     uuid not null references public.sales(id) on delete cascade,
  tender      public.tender_type not null,
  amount      bigint not null,                    -- negative for refunds
  reference   text,
  status      text not null default 'captured' check (status in ('captured','pending','expired')),
  shift_id    uuid references public.shifts(id),
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index on public.payments(tenant_id, sale_id);

create table public.payment_links (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  sale_id    uuid not null references public.sales(id),
  payment_id uuid not null references public.payments(id),
  token      text not null unique default encode(extensions.gen_random_bytes(18),'hex'),
  amount     bigint not null check (amount > 0),
  status     text not null default 'pending' check (status in ('pending','paid','expired','cancelled')),
  expires_at timestamptz not null default now() + interval '3 days',
  paid_at    timestamptz,
  gateway_ref text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- ledger (append-only, hash-chained)
create table public.accounts (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  code       text not null,
  name_en    text not null,
  name_ar    text not null,
  type       public.account_type not null,
  system_key text,
  unique (tenant_id, code),
  unique (tenant_id, system_key)
);

create table public.journal_entries (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid references public.branches(id),
  entry_date  date not null default current_date,
  source_type text not null,
  source_id   uuid,
  memo        text,
  prev_hash   text,
  hash        text not null,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index on public.journal_entries(tenant_id, entry_date);

create table public.journal_lines (
  id         bigint generated always as identity primary key,
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  entry_id   bigint not null references public.journal_entries(id),
  account_id uuid not null references public.accounts(id),
  branch_id  uuid references public.branches(id),
  debit      bigint not null default 0 check (debit  >= 0),
  credit     bigint not null default 0 check (credit >= 0),
  check (debit = 0 or credit = 0)
);
create index on public.journal_lines(tenant_id, account_id);

-- ---------------------------------------------------------------- audit
create table public.audit_log (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid,
  user_id     uuid,
  approved_by uuid,
  action      text not null,       -- e.g. sale.discount, sale.refund, sale.cancel, shift.variance, drawer.no_sale
  entity      text,
  entity_id   uuid,
  amount      bigint,
  reason      text,
  meta        jsonb not null default '{}',
  created_at  timestamptz not null default now()
);
create index on public.audit_log(tenant_id, created_at desc);

-- ---------------------------------------------------------------- immutability guards
create or replace function public.forbid_change() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = 'P0001';
end $$;

create trigger journal_entries_immutable before update or delete on public.journal_entries for each row execute function public.forbid_change();
create trigger journal_lines_immutable   before update or delete on public.journal_lines   for each row execute function public.forbid_change();
create trigger audit_log_immutable       before update or delete on public.audit_log       for each row execute function public.forbid_change();
create trigger stock_movements_immutable before update or delete on public.stock_movements for each row execute function public.forbid_change();
create trigger sale_lines_immutable      before update or delete on public.sale_lines      for each row execute function public.forbid_change();

-- sales: only status / paid / refunded fields may change, and only inside SECURITY DEFINER functions
create or replace function public.guard_sales_update() returns trigger language plpgsql as $$
begin
  if (new.total, new.subtotal, new.tax_total, new.number, new.tenant_id, new.client_id, new.created_at)
     is distinct from (old.total, old.subtotal, old.tax_total, old.number, old.tenant_id, old.client_id, old.created_at) then
    raise exception 'posted sales cannot be edited; issue a credit note' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger sales_guard before update on public.sales for each row execute function public.guard_sales_update();
create trigger sales_no_delete before delete on public.sales for each row execute function public.forbid_change();

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger items_touch before update on public.items for each row execute function public.touch_updated_at();

-- ===== 20261118000002_security.sql
-- Z Trust MVP · access helpers and row-level security
-- Reads: any active member of the tenant (branch-scoped for sales data).
-- Writes to money tables happen only through SECURITY DEFINER functions (see pos migration).

create or replace function public.is_member(p_tenant uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships m
                 where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.is_active);
$$;

create or replace function public.my_role(p_tenant uuid) returns public.member_role
language sql stable security definer set search_path = public as $$
  select m.role from memberships m
  where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.is_active;
$$;

create or replace function public.can_see_branch(p_tenant uuid, p_branch uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships m
                 where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.is_active
                   and (m.branch_ids is null or p_branch = any(m.branch_ids)));
$$;

-- returns true when the role has the permission; limit is returned through perm_limit()
create or replace function public.role_has(p_tenant uuid, p_role public.member_role, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_role = 'owner' or exists (select 1 from role_permissions rp
    where rp.tenant_id = p_tenant and rp.role = p_role and rp.permission = p_perm);
$$;

create or replace function public.role_limit(p_tenant uuid, p_role public.member_role, p_perm text) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p_role = 'owner' then null
              else (select rp.limit_value from role_permissions rp
                    where rp.tenant_id = p_tenant and rp.role = p_role and rp.permission = p_perm) end;
$$;

create or replace function public.has_perm(p_tenant uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.role_has(p_tenant, public.my_role(p_tenant), p_perm), false);
$$;

-- ---------------------------------------------------------------- enable RLS
alter table public.countries        enable row level security;
alter table public.coa_template     enable row level security;
alter table public.tenants          enable row level security;
alter table public.memberships      enable row level security;
alter table public.role_permissions enable row level security;
alter table public.branches         enable row level security;
alter table public.categories       enable row level security;
alter table public.items            enable row level security;
alter table public.customers        enable row level security;
alter table public.stock_movements  enable row level security;
alter table public.shifts           enable row level security;
alter table public.doc_sequences    enable row level security;
alter table public.sales            enable row level security;
alter table public.sale_lines       enable row level security;
alter table public.payments         enable row level security;
alter table public.payment_links    enable row level security;
alter table public.accounts         enable row level security;
alter table public.journal_entries  enable row level security;
alter table public.journal_lines    enable row level security;
alter table public.audit_log        enable row level security;

-- reference data: readable by everyone signed in
create policy countries_read on public.countries    for select to authenticated using (true);
create policy coa_read       on public.coa_template for select to authenticated using (true);

-- tenants
create policy tenants_read   on public.tenants for select to authenticated using (public.is_member(id));
create policy tenants_update on public.tenants for update to authenticated
  using (public.has_perm(id, 'settings.manage')) with check (public.has_perm(id, 'settings.manage'));

-- memberships: members see colleagues; staff managers edit
create policy memberships_read  on public.memberships for select to authenticated using (public.is_member(tenant_id));
create policy memberships_write on public.memberships for all to authenticated
  using (public.has_perm(tenant_id, 'staff.manage') and role <> 'owner')
  with check (public.has_perm(tenant_id, 'staff.manage') and role <> 'owner');

create policy perms_read  on public.role_permissions for select to authenticated using (public.is_member(tenant_id));
create policy perms_write on public.role_permissions for all to authenticated
  using (public.my_role(tenant_id) = 'owner') with check (public.my_role(tenant_id) = 'owner' and role <> 'owner');

-- branches
create policy branches_read  on public.branches for select to authenticated using (public.can_see_branch(tenant_id, id));
create policy branches_write on public.branches for all to authenticated
  using (public.has_perm(tenant_id, 'settings.manage')) with check (public.has_perm(tenant_id, 'settings.manage'));

-- catalog
create policy categories_read  on public.categories for select to authenticated using (public.is_member(tenant_id));
create policy categories_write on public.categories for all to authenticated
  using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy items_read  on public.items for select to authenticated using (public.is_member(tenant_id));
create policy items_write on public.items for all to authenticated
  using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));

-- customers: any member can add at the till
create policy customers_read   on public.customers for select to authenticated using (public.is_member(tenant_id));
create policy customers_insert on public.customers for insert to authenticated with check (public.is_member(tenant_id));
create policy customers_update on public.customers for update to authenticated
  using (public.has_perm(tenant_id, 'customers.manage')) with check (public.has_perm(tenant_id, 'customers.manage'));

-- read-only, branch-scoped money and stock data (writes only via functions)
create policy stock_read    on public.stock_movements for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy shifts_read   on public.shifts          for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy sales_read    on public.sales           for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy lines_read    on public.sale_lines      for select to authenticated
  using (exists (select 1 from public.sales s where s.id = sale_id and public.can_see_branch(s.tenant_id, s.branch_id)));
create policy payments_read on public.payments        for select to authenticated
  using (exists (select 1 from public.sales s where s.id = sale_id and public.can_see_branch(s.tenant_id, s.branch_id)));
create policy links_read    on public.payment_links   for select to authenticated using (public.is_member(tenant_id));

-- finance: accountants, managers and owners
create policy accounts_read on public.accounts        for select to authenticated using (public.has_perm(tenant_id, 'finance.view'));
create policy je_read       on public.journal_entries for select to authenticated using (public.has_perm(tenant_id, 'finance.view'));
create policy jl_read       on public.journal_lines   for select to authenticated using (public.has_perm(tenant_id, 'finance.view'));
create policy audit_read    on public.audit_log       for select to authenticated using (public.has_perm(tenant_id, 'reports.exceptions'));

-- table privileges: money tables are read-only for clients
revoke insert, update, delete on public.stock_movements, public.shifts, public.doc_sequences, public.sales,
  public.sale_lines, public.payments, public.payment_links, public.accounts, public.journal_entries,
  public.journal_lines, public.audit_log from anon, authenticated;
revoke all on public.tenants from anon;

-- ===== 20261118000003_pos.sql
-- Z Trust MVP · POS money functions, ledger posting, onboarding
-- All money-moving operations are atomic SECURITY DEFINER functions:
--   create_tenant, complete_sale, refund_sale, receive_payment, mark_payment_link_paid,
--   open_shift, close_shift, log_drawer_open, adjust_stock, receive_stock, set_my_pin
-- Errors that the POS turns into a PIN prompt use SQLSTATE 'ZT401' with message 'APPROVAL_REQUIRED:<permission>'.

alter table public.journal_lines add column customer_id uuid references public.customers(id);
create index on public.journal_lines(tenant_id, customer_id) where customer_id is not null;

-- ================================================================ internal helpers
create or replace function public._acct(p_tenant uuid, p_key text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from accounts where tenant_id = p_tenant and system_key = p_key;
  if v is null then raise exception 'missing system account %', p_key; end if;
  return v;
end $$;

-- p_lines: [{"key":"cash","debit":1000}, {"key":"sales","credit":870,"customer_id":"..."}]
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
    insert into journal_lines(tenant_id, entry_id, account_id, branch_id, debit, credit, customer_id)
    values (p_tenant, v_id, _acct(p_tenant, l->>'key'), p_branch,
            coalesce((l->>'debit')::bigint,0), coalesce((l->>'credit')::bigint,0),
            nullif(l->>'customer_id','')::uuid);
  end loop;
  return v_id;
end $$;

create or replace function public._tender_account(p_tender public.tender_type) returns text
language sql immutable as $$
  select case p_tender
    when 'cash' then 'cash'
    when 'card' then 'card_clearing'
    when 'bank_transfer' then 'bank'
    when 'store_credit' then 'store_credit'
    when 'on_account' then 'ar'
    when 'payment_link' then 'ar'
    else 'other_clearing' end;
$$;

-- returns the approver's user id, or null when the caller is allowed on their own.
-- p_value is compared with the permission limit (percent or minor units).
create or replace function public._require(p_tenant uuid, p_perm text, p_value numeric, p_pin text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role public.member_role := my_role(p_tenant);
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

create or replace function public._units(p_tenant uuid, p_units numeric) returns bigint
language sql stable security definer set search_path = public as $$
  select (p_units * power(10, currency_decimals))::bigint from tenants where id = p_tenant;
$$;

create or replace function public.customer_balance(p_customer uuid) returns bigint
language sql stable security definer set search_path = public as $$
  -- receivable owed by the customer (positive = customer owes us)
  select coalesce(sum(jl.debit - jl.credit),0)::bigint
    from journal_lines jl join accounts a on a.id = jl.account_id
   where jl.customer_id = p_customer and a.system_key = 'ar'
     and is_member(jl.tenant_id);
$$;

create or replace function public.customer_store_credit(p_customer uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(jl.credit - jl.debit),0)::bigint
    from journal_lines jl join accounts a on a.id = jl.account_id
   where jl.customer_id = p_customer and a.system_key = 'store_credit'
     and is_member(jl.tenant_id);
$$;

create or replace function public._next_number(p_tenant uuid, p_branch uuid, p_doc public.doc_type) returns text
language plpgsql security definer set search_path = public as $$
declare v_no bigint; v_code text;
begin
  insert into doc_sequences(tenant_id, branch_id, doc_type, next_no) values (p_tenant, p_branch, p_doc, 2)
  on conflict (tenant_id, branch_id, doc_type) do update set next_no = doc_sequences.next_no + 1
  returning next_no - 1 into v_no;
  select code into v_code from branches where id = p_branch;
  return v_code || '-' || case p_doc when 'invoice' then 'INV' else 'CN' end || '-' || lpad(v_no::text, 6, '0');
end $$;

create or replace function public._audit(p_tenant uuid, p_branch uuid, p_action text, p_entity text, p_entity_id uuid,
                                         p_amount bigint, p_reason text, p_approver uuid, p_meta jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into audit_log(tenant_id, branch_id, user_id, approved_by, action, entity, entity_id, amount, reason, meta)
  values (p_tenant, p_branch, auth.uid(), p_approver, p_action, p_entity, p_entity_id, p_amount, p_reason, coalesce(p_meta,'{}'));
$$;

create or replace function public.sale_json(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(s) || jsonb_build_object(
    'lines',    (select coalesce(jsonb_agg(to_jsonb(l) order by l.name),'[]') from sale_lines l where l.sale_id = s.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at),'[]') from payments p where p.sale_id = s.id),
    'links',    (select coalesce(jsonb_agg(jsonb_build_object('token',k.token,'amount',k.amount,'status',k.status,'expires_at',k.expires_at)),'[]')
                   from payment_links k where k.sale_id = s.id),
    'customer', (select to_jsonb(c) from customers c where c.id = s.customer_id))
  from sales s where s.id = p_sale and can_see_branch(s.tenant_id, s.branch_id);
$$;

-- ================================================================ onboarding
create or replace function public.create_tenant(p jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  c countries%rowtype;
  v_tenant uuid;
  v_branch uuid;
  u bigint;
begin
  if v_uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into c from countries where code = upper(coalesce(p->>'country_code','')) ;
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
          p->>'branch_address', c.timezone)
  returning id into v_branch;

  insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
  values (v_tenant, v_uid, 'owner', coalesce(nullif(p->>'display_name',''), 'Owner'),
          case when length(coalesce(p->>'pin','')) >= 4 then crypt(p->>'pin', gen_salt('bf')) end);

  insert into accounts(tenant_id, code, name_en, name_ar, type, system_key)
  select v_tenant, code, name_en, name_ar, type, system_key from coa_template;

  u := power(10, c.currency_decimals)::bigint;   -- one currency unit in minor units
  insert into role_permissions(tenant_id, role, permission, limit_value) values
    -- manager
    (v_tenant,'manager','sale.create',null),(v_tenant,'manager','sale.discount',30),
    (v_tenant,'manager','sale.refund',null),(v_tenant,'manager','sale.cancel',null),
    (v_tenant,'manager','sale.over_credit',null),(v_tenant,'manager','drawer.no_sale',null),
    (v_tenant,'manager','catalog.manage',null),(v_tenant,'manager','customers.manage',null),
    (v_tenant,'manager','staff.manage',null),(v_tenant,'manager','inventory.adjust',null),
    (v_tenant,'manager','reports.all',null),(v_tenant,'manager','reports.exceptions',null),
    (v_tenant,'manager','reports.costs',null),(v_tenant,'manager','finance.view',null),
    (v_tenant,'manager','shift.view_expected',null),(v_tenant,'manager','payments.receive',null),
    -- supervisor
    (v_tenant,'supervisor','sale.create',null),(v_tenant,'supervisor','sale.discount',15),
    (v_tenant,'supervisor','sale.refund',50*u),(v_tenant,'supervisor','sale.cancel',50*u),
    (v_tenant,'supervisor','drawer.no_sale',null),(v_tenant,'supervisor','customers.manage',null),
    (v_tenant,'supervisor','inventory.adjust',null),(v_tenant,'supervisor','shift.view_expected',null),
    (v_tenant,'supervisor','payments.receive',null),
    -- cashier
    (v_tenant,'cashier','sale.create',null),(v_tenant,'cashier','sale.discount',5),
    (v_tenant,'cashier','sale.refund',10*u),(v_tenant,'cashier','payments.receive',null),
    -- accountant
    (v_tenant,'accountant','finance.view',null),(v_tenant,'accountant','reports.all',null),
    (v_tenant,'accountant','reports.exceptions',null),(v_tenant,'accountant','reports.costs',null),
    (v_tenant,'accountant','payments.receive',null);

  return v_tenant;
end $$;

create or replace function public.set_my_pin(p_tenant uuid, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'PIN must be 4 to 6 digits'; end if;
  update memberships set pin_hash = crypt(p_pin, gen_salt('bf'))
   where tenant_id = p_tenant and user_id = auth.uid();
  if not found then raise exception 'not a member' using errcode = '42501'; end if;
end $$;

-- ================================================================ shifts
create or replace function public.open_shift(p_branch uuid, p_float bigint) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_id uuid;
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if v_tenant is null or not can_see_branch(v_tenant, p_branch) then raise exception 'branch not allowed' using errcode='42501'; end if;
  perform _require(v_tenant, 'sale.create', null, null);
  select id into v_id from shifts where branch_id = p_branch and opened_by = auth.uid() and closed_at is null;
  if v_id is not null then return v_id; end if;
  insert into shifts(tenant_id, branch_id, opened_by, opening_float) values (v_tenant, p_branch, auth.uid(), greatest(p_float,0))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.shift_summary(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s shifts%rowtype; v jsonb; v_show boolean;
begin
  select * into s from shifts where id = p_shift;
  if not found or not can_see_branch(s.tenant_id, s.branch_id) then raise exception 'shift not found'; end if;
  v_show := s.closed_at is not null or has_perm(s.tenant_id, 'shift.view_expected');
  select jsonb_build_object(
    'shift', to_jsonb(s) - case when v_show then 'x' else 'expected_cash' end,
    'invoices', (select count(*) from sales where shift_id = s.id and doc_type='invoice'),
    'credit_notes', (select count(*) from sales where shift_id = s.id and doc_type='credit_note'),
    'sales_total', (select coalesce(sum(total),0) from sales where shift_id = s.id and doc_type='invoice'),
    'refunds_total', (select coalesce(sum(total),0) from sales where shift_id = s.id and doc_type='credit_note'),
    'tax_total', (select coalesce(sum(case when doc_type='invoice' then tax_total else -tax_total end),0) from sales where shift_id = s.id),
    'tenders', (select coalesce(jsonb_object_agg(tender, amt),'{}') from
                 (select p.tender, sum(p.amount) amt from payments p where p.shift_id = s.id group by p.tender) t),
    'expected_cash', case when v_show then s.opening_float + (select coalesce(sum(amount),0) from payments
                        where shift_id = s.id and tender='cash' and status='captured') end
  ) into v;
  return v;
end $$;

create or replace function public.close_shift(p_shift uuid, p_counted bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s shifts%rowtype; v_expected bigint; v_var bigint;
begin
  select * into s from shifts where id = p_shift for update;
  if not found or not can_see_branch(s.tenant_id, s.branch_id) then raise exception 'shift not found'; end if;
  if s.closed_at is not null then raise exception 'shift already closed'; end if;
  if s.opened_by <> auth.uid() then perform _require(s.tenant_id, 'shift.view_expected', null, null); end if;

  v_expected := s.opening_float + (select coalesce(sum(amount),0) from payments
                 where shift_id = s.id and tender = 'cash' and status = 'captured');
  v_var := p_counted - v_expected;
  update shifts set closed_at = now(), closed_by = auth.uid(), expected_cash = v_expected,
                    counted_cash = p_counted, variance = v_var where id = s.id;
  if v_var <> 0 then
    perform _post(s.tenant_id, s.branch_id, 'shift_variance', s.id, 'Cash over/short',
      case when v_var > 0
        then jsonb_build_array(jsonb_build_object('key','cash','debit',v_var), jsonb_build_object('key','cash_over_short','credit',v_var))
        else jsonb_build_array(jsonb_build_object('key','cash_over_short','debit',-v_var), jsonb_build_object('key','cash','credit',-v_var)) end);
    perform _audit(s.tenant_id, s.branch_id, 'shift.variance', 'shift', s.id, v_var, null, null);
  end if;
  return shift_summary(s.id);
end $$;

create or replace function public.log_drawer_open(p_branch uuid, p_reason text, p_pin text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_appr uuid;
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if coalesce(trim(p_reason),'') = '' then raise exception 'reason required'; end if;
  v_appr := _require(v_tenant, 'drawer.no_sale', null, p_pin);
  perform _audit(v_tenant, p_branch, 'drawer.no_sale', 'branch', p_branch, null, p_reason, v_appr);
end $$;

-- ================================================================ sale
-- p = {
--   tenant_id, branch_id, shift_id?, client_id, customer_id?, device_created_at?, approver_pin?, note?,
--   lines: [{ item_id?, name?, qty, unit_price?, discount? }],
--   payments: [{ tender, amount, reference? }]
-- }
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
      'total', v_total_line, 'unit_cost', coalesce(it.cost,0), 'track', coalesce(it.track_stock,false));
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
    insert into sale_lines(tenant_id, sale_id, item_id, name, qty, unit_price, discount, tax_rate, net_amount, tax_amount, line_total, unit_cost)
    values (t.id, v_sale, nullif(l->>'item_id','')::uuid, l->>'name', (l->>'qty')::numeric, (l->>'unit_price')::bigint,
            (l->>'discount')::bigint, (l->>'tax_rate')::numeric, (l->>'net')::bigint, (l->>'tax')::bigint, (l->>'total')::bigint,
            (l->>'unit_cost')::bigint);
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
  return sale_json(v_sale);
end $$;

-- ================================================================ refund / cancel
-- p = { sale_id, client_id, tender, reason, approver_pin?, shift_id?, cancel?: bool,
--       lines?: [{ line_id, qty }]   (omit = everything still refundable) }
create or replace function public.refund_sale(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o sales%rowtype; ol sale_lines%rowtype;
  v_cancel boolean := coalesce((p->>'cancel')::boolean, false);
  v_tender tender_type := coalesce(nullif(p->>'tender',''),'cash')::tender_type;
  v_reason text := nullif(trim(coalesce(p->>'reason','')),'');
  v_shift uuid := nullif(p->>'shift_id','')::uuid;
  v_existing uuid; v_cn uuid; v_number text; v_appr uuid;
  v_req numeric; v_done numeric; v_q numeric;
  v_net bigint; v_tax bigint; v_tot bigint;
  v_sub bigint := 0; v_taxsum bigint := 0; v_total bigint := 0; v_cogs bigint := 0;
  v_rows jsonb := '[]'; r jsonb;
begin
  select * into o from sales where id = (p->>'sale_id')::uuid for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'sale not found'; end if;
  if o.doc_type <> 'invoice' then raise exception 'only invoices can be refunded'; end if;
  if v_reason is null then raise exception 'a reason is required' using errcode = 'ZT422'; end if;

  select id into v_existing from sales where tenant_id = o.tenant_id and client_id = (p->>'client_id')::uuid;
  if v_existing is not null then return sale_json(v_existing); end if;

  if v_tender = 'payment_link' then raise exception 'refunds cannot go to a payment link'; end if;
  if v_tender in ('on_account','store_credit') and o.customer_id is null then
    raise exception 'this sale has no customer; refund in cash or card'; end if;
  if o.paid_total < o.total and v_tender <> 'on_account' then
    raise exception 'the sale is not fully paid; refund to the customer account' using errcode = 'ZT422'; end if;
  if v_shift is not null and not exists (select 1 from shifts where id = v_shift and closed_at is null) then v_shift := null; end if;

  for ol in select * from sale_lines where sale_id = o.id loop
    select coalesce(sum(x.qty),0) into v_done from sale_lines x where x.original_line_id = ol.id;
    if p ? 'lines' and not v_cancel then
      select (e->>'qty')::numeric into v_req from jsonb_array_elements(p->'lines') e where (e->>'line_id')::uuid = ol.id;
      if v_req is null then continue; end if;
    else
      v_req := ol.qty - v_done;
    end if;
    if v_req <= 0 then continue; end if;
    if v_req > ol.qty - v_done then raise exception 'cannot refund more than sold for %', ol.name; end if;
    v_q := v_req / ol.qty;
    v_net := round(ol.net_amount * v_q)::bigint; v_tax := round(ol.tax_amount * v_q)::bigint; v_tot := v_net + v_tax;
    v_sub := v_sub + v_net; v_taxsum := v_taxsum + v_tax; v_total := v_total + v_tot;
    if ol.item_id is not null and exists (select 1 from items where id = ol.item_id and track_stock) then
      v_cogs := v_cogs + round(v_req * ol.unit_cost)::bigint;
    end if;
    v_rows := v_rows || jsonb_build_object('line', to_jsonb(ol), 'qty', v_req, 'net', v_net, 'tax', v_tax, 'total', v_tot);
  end loop;
  if v_total <= 0 then raise exception 'nothing left to refund'; end if;

  v_appr := _require(o.tenant_id, case when v_cancel then 'sale.cancel' else 'sale.refund' end, v_total, p->>'approver_pin');

  v_number := _next_number(o.tenant_id, o.branch_id, 'credit_note');
  insert into sales(tenant_id, branch_id, shift_id, client_id, doc_type, number, original_sale_id, customer_id,
                    subtotal, discount_total, tax_total, total, paid_total, reason, approved_by, created_by)
  values (o.tenant_id, o.branch_id, v_shift, (p->>'client_id')::uuid, 'credit_note', v_number, o.id, o.customer_id,
          v_sub, 0, v_taxsum, v_total, case when v_tender = 'on_account' then 0 else v_total end, v_reason, v_appr, auth.uid())
  returning id into v_cn;

  for r in select * from jsonb_array_elements(v_rows) loop
    insert into sale_lines(tenant_id, sale_id, original_line_id, item_id, name, qty, unit_price, discount, tax_rate,
                           net_amount, tax_amount, line_total, unit_cost)
    values (o.tenant_id, v_cn, (r->'line'->>'id')::uuid, nullif(r->'line'->>'item_id','')::uuid, r->'line'->>'name',
            (r->>'qty')::numeric, (r->'line'->>'unit_price')::bigint, 0, (r->'line'->>'tax_rate')::numeric,
            (r->>'net')::bigint, (r->>'tax')::bigint, (r->>'total')::bigint, (r->'line'->>'unit_cost')::bigint);
    if nullif(r->'line'->>'item_id','') is not null and exists (select 1 from items where id = (r->'line'->>'item_id')::uuid and track_stock) then
      insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, created_by)
      values (o.tenant_id, o.branch_id, (r->'line'->>'item_id')::uuid, (r->>'qty')::numeric, 'refund', v_cn,
              (r->'line'->>'unit_cost')::bigint, auth.uid());
    end if;
  end loop;

  insert into payments(tenant_id, sale_id, tender, amount, status, shift_id, created_by)
  values (o.tenant_id, v_cn, v_tender, -v_total, 'captured', v_shift, auth.uid());

  perform _post(o.tenant_id, o.branch_id, case when v_cancel then 'cancel' else 'refund' end, v_cn, v_number,
    jsonb_build_array(
      jsonb_build_object('key','sales','debit', v_sub),
      jsonb_build_object('key','vat_payable','debit', v_taxsum),
      jsonb_build_object('key', _tender_account(v_tender), 'credit', v_total,
                         'customer_id', case when v_tender in ('on_account','store_credit') then o.customer_id end),
      jsonb_build_object('key','inventory','debit', v_cogs),
      jsonb_build_object('key','cogs','credit', v_cogs)));

  update sales set refunded_total = refunded_total + v_total,
                   status = case when v_cancel then 'cancelled'
                                 when refunded_total + v_total >= total then 'refunded'
                                 else 'partially_refunded' end
   where id = o.id;

  perform _audit(o.tenant_id, o.branch_id, case when v_cancel then 'sale.cancel' else 'sale.refund' end, 'sale', o.id,
                 v_total, v_reason, v_appr, jsonb_build_object('credit_note', v_number, 'tender', v_tender,
                 'same_shift', o.shift_id is not distinct from v_shift));
  return sale_json(v_cn);
end $$;

-- ================================================================ collections
create or replace function public.receive_payment(p_sale uuid, p_tender public.tender_type, p_amount bigint, p_reference text default null,
                                                  p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o sales%rowtype;
begin
  select * into o from sales where id = p_sale for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'sale not found'; end if;
  perform _require(o.tenant_id, 'payments.receive', null, null);
  if p_tender in ('on_account','payment_link') then raise exception 'choose a real tender'; end if;
  if p_amount <= 0 or p_amount > o.total - o.paid_total - o.refunded_total then raise exception 'amount exceeds the balance due'; end if;
  insert into payments(tenant_id, sale_id, tender, amount, reference, status, shift_id, created_by)
  values (o.tenant_id, o.id, p_tender, p_amount, p_reference, 'captured', p_shift, auth.uid());
  update sales set paid_total = paid_total + p_amount where id = o.id;
  perform _post(o.tenant_id, o.branch_id, 'collection', o.id, o.number, jsonb_build_array(
    jsonb_build_object('key', _tender_account(p_tender), 'debit', p_amount),
    jsonb_build_object('key','ar','credit', p_amount, 'customer_id', o.customer_id)));
  return sale_json(o.id);
end $$;

create or replace function public.create_payment_link(p_sale uuid, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o sales%rowtype; v_pid uuid; v_link payment_links%rowtype;
begin
  select * into o from sales where id = p_sale for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'sale not found'; end if;
  perform _require(o.tenant_id, 'payments.receive', null, null);
  if p_amount <= 0 or p_amount > o.total - o.paid_total - o.refunded_total
     - (select coalesce(sum(amount),0) from payment_links where sale_id = o.id and status = 'pending') then
    raise exception 'amount exceeds the open balance'; end if;
  insert into payments(tenant_id, sale_id, tender, amount, status, created_by)
  values (o.tenant_id, o.id, 'payment_link', p_amount, 'pending', auth.uid()) returning id into v_pid;
  insert into payment_links(tenant_id, sale_id, payment_id, amount) values (o.tenant_id, o.id, v_pid, p_amount)
  returning * into v_link;
  return to_jsonb(v_link);
end $$;

-- called only by the payment gateway webhook (service role)
create or replace function public.mark_payment_link_paid(p_token text, p_gateway_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k payment_links%rowtype; o sales%rowtype;
begin
  select * into k from payment_links where token = p_token for update;
  if not found then raise exception 'unknown link'; end if;
  if k.status = 'paid' then return to_jsonb(k); end if;
  if k.status <> 'pending' then raise exception 'link is %', k.status; end if;
  select * into o from sales where id = k.sale_id for update;
  update payment_links set status = 'paid', paid_at = now(), gateway_ref = p_gateway_ref where id = k.id returning * into k;
  update payments set status = 'captured', reference = p_gateway_ref where id = k.payment_id;
  update sales set paid_total = paid_total + k.amount where id = o.id;
  perform _post(o.tenant_id, o.branch_id, 'payment_link', o.id, o.number, jsonb_build_array(
    jsonb_build_object('key','gateway_clearing','debit', k.amount),
    jsonb_build_object('key','ar','credit', k.amount, 'customer_id', o.customer_id)));
  return to_jsonb(k);
end $$;

-- public lookup for the hosted payment page (no login)
create or replace function public.payment_link_info(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('amount', k.amount, 'status', k.status, 'expires_at', k.expires_at,
           'currency', t.currency, 'decimals', t.currency_decimals, 'business', t.name, 'business_ar', t.name_ar,
           'number', s.number, 'brand_color', t.brand_color)
    from payment_links k join sales s on s.id = k.sale_id join tenants t on t.id = k.tenant_id
   where k.token = p_token;
$$;

-- ================================================================ stock
create or replace function public.adjust_stock(p_branch uuid, p_item uuid, p_qty numeric, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare it items%rowtype; v_val bigint;
begin
  select * into it from items where id = p_item;
  if not found or not can_see_branch(it.tenant_id, p_branch) then raise exception 'not allowed' using errcode='42501'; end if;
  perform _require(it.tenant_id, 'inventory.adjust', null, null);
  if p_qty = 0 then return; end if;
  insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost, note, created_by)
  values (it.tenant_id, p_branch, p_item, p_qty, 'adjustment', it.cost, p_note, auth.uid());
  v_val := abs(round(p_qty * it.cost))::bigint;
  perform _post(it.tenant_id, p_branch, 'stock_adjustment', p_item, coalesce(p_note, it.name),
    case when p_qty > 0
      then jsonb_build_array(jsonb_build_object('key','inventory','debit',v_val), jsonb_build_object('key','inventory_adjustments','credit',v_val))
      else jsonb_build_array(jsonb_build_object('key','inventory_adjustments','debit',v_val), jsonb_build_object('key','inventory','credit',v_val)) end);
  perform _audit(it.tenant_id, p_branch, 'inventory.adjust', 'item', p_item, v_val, p_note, null, jsonb_build_object('qty', p_qty));
end $$;

-- goods received from a supplier; updates moving-average cost
create or replace function public.receive_stock(p_branch uuid, p_item uuid, p_qty numeric, p_unit_cost bigint, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare it items%rowtype; v_onhand numeric; v_val bigint;
begin
  select * into it from items where id = p_item for update;
  if not found or not can_see_branch(it.tenant_id, p_branch) then raise exception 'not allowed' using errcode='42501'; end if;
  perform _require(it.tenant_id, 'inventory.adjust', null, null);
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

-- ================================================================ privileges
revoke execute on all functions in schema public from public, anon;
grant execute on function public.create_tenant(jsonb), public.set_my_pin(uuid,text), public.open_shift(uuid,bigint),
  public.close_shift(uuid,bigint), public.shift_summary(uuid), public.log_drawer_open(uuid,text,text),
  public.complete_sale(jsonb), public.refund_sale(jsonb), public.receive_payment(uuid,public.tender_type,bigint,text,uuid),
  public.create_payment_link(uuid,bigint), public.adjust_stock(uuid,uuid,numeric,text),
  public.receive_stock(uuid,uuid,numeric,bigint,text), public.sale_json(uuid), public.customer_balance(uuid),
  public.customer_store_credit(uuid), public.is_member(uuid), public.my_role(uuid), public.can_see_branch(uuid,uuid),
  public.has_perm(uuid,text), public.role_has(uuid,public.member_role,text), public.role_limit(uuid,public.member_role,text)
  to authenticated;
grant execute on function public.payment_link_info(text) to anon, authenticated;
grant execute on function public.mark_payment_link_paid(text,text) to service_role;

-- ===== 20261118000004_reference_and_reports.sql
-- Z Trust MVP · reference data (country packs v1, chart of accounts) and report views
-- Country data must be re-confirmed with each tax authority before go-live.

insert into public.countries(code, name_en, name_ar, currency, currency_decimals, vat_rate, prices_include_tax, einvoice_regime, default_language, timezone) values
  ('KW','Kuwait','الكويت','KWD',3, 0, true, null,           'ar','Asia/Kuwait'),
  ('SA','Saudi Arabia','السعودية','SAR',2,15, true, 'zatca',        'ar','Asia/Riyadh'),
  ('AE','United Arab Emirates','الإمارات','AED',2, 5, true, 'uae_asp',      'ar','Asia/Dubai'),
  ('QA','Qatar','قطر','QAR',2, 0, true, null,           'ar','Asia/Qatar'),
  ('BH','Bahrain','البحرين','BHD',3,10, true, null,           'ar','Asia/Bahrain'),
  ('OM','Oman','عُمان','OMR',3, 5, true, 'oman_fawtara', 'ar','Asia/Muscat'),
  ('EG','Egypt','مصر','EGP',2,14, true, 'eta',          'ar','Africa/Cairo'),
  ('JO','Jordan','الأردن','JOD',3,16, true, 'jofotara',     'ar','Asia/Amman'),
  ('GB','United Kingdom','المملكة المتحدة','GBP',2,20, true, null,      'en','Europe/London'),
  ('US','United States','الولايات المتحدة','USD',2, 0, false, null,     'en','America/New_York'),
  ('XX','Other country (generic)','دولة أخرى','USD',2, 0, true, null,  'en','UTC')
on conflict (code) do nothing;

insert into public.coa_template(system_key, code, name_en, name_ar, type) values
  ('cash',                  '1010','Cash on hand',               'النقدية في الصندوق',     'asset'),
  ('bank',                  '1020','Bank',                       'البنك',                  'asset'),
  ('card_clearing',         '1030','Card payments clearing',     'تسوية مدفوعات البطاقات', 'asset'),
  ('gateway_clearing',      '1040','Online payments clearing',   'تسوية المدفوعات الإلكترونية','asset'),
  ('other_clearing',        '1050','Other tenders clearing',     'تسوية وسائل دفع أخرى',   'asset'),
  ('ar',                    '1100','Accounts receivable',        'الذمم المدينة',          'asset'),
  ('inventory',             '1200','Inventory',                  'المخزون',                'asset'),
  ('ap',                    '2010','Accounts payable',           'الذمم الدائنة',          'liability'),
  ('vat_payable',           '2100','VAT payable',                'ضريبة القيمة المضافة المستحقة','liability'),
  ('store_credit',          '2200','Customer store credit',      'أرصدة العملاء الدائنة',   'liability'),
  ('equity',                '3000','Owner equity',               'حقوق الملكية',           'equity'),
  ('sales',                 '4000','Sales',                      'المبيعات',               'income'),
  ('cogs',                  '5000','Cost of goods sold',         'تكلفة البضاعة المباعة',   'expense'),
  ('inventory_adjustments', '5100','Inventory adjustments',      'تسويات المخزون',         'expense'),
  ('cash_over_short',       '5200','Cash over / short',          'فروقات النقدية',         'expense')
on conflict (system_key) do nothing;

-- ---------------------------------------------------------------- report views (RLS of the caller applies)
create or replace view public.v_daily_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id,
       (s.created_at at time zone b.timezone)::date as day,
       count(*) filter (where s.doc_type = 'invoice')                          as invoices,
       count(*) filter (where s.doc_type = 'credit_note')                      as credit_notes,
       coalesce(sum(s.total) filter (where s.doc_type = 'invoice'),0)          as gross_sales,
       coalesce(sum(s.total) filter (where s.doc_type = 'credit_note'),0)      as refunds,
       coalesce(sum(case when s.doc_type='invoice' then s.total else -s.total end),0)         as net_sales,
       coalesce(sum(case when s.doc_type='invoice' then s.tax_total else -s.tax_total end),0) as tax,
       coalesce(sum(s.discount_total) filter (where s.doc_type = 'invoice'),0) as discounts
  from public.sales s join public.branches b on b.id = s.branch_id
 group by 1,2,3;

create or replace view public.v_tender_daily with (security_invoker = true) as
select s.tenant_id, s.branch_id, (p.created_at at time zone b.timezone)::date as day, p.tender, p.status,
       sum(p.amount) as amount, count(*) as count
  from public.payments p join public.sales s on s.id = p.sale_id join public.branches b on b.id = s.branch_id
 group by 1,2,3,4,5;

create or replace view public.v_item_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day, l.item_id, l.name,
       sum(case when s.doc_type='invoice' then l.qty else -l.qty end)               as qty,
       sum(case when s.doc_type='invoice' then l.line_total else -l.line_total end) as total,
       sum(case when s.doc_type='invoice' then l.net_amount else -l.net_amount end) as net,
       sum(case when s.doc_type='invoice' then l.qty*l.unit_cost else -l.qty*l.unit_cost end)::bigint as cost
  from public.sale_lines l join public.sales s on s.id = l.sale_id join public.branches b on b.id = s.branch_id
 group by 1,2,3,4,5;

create or replace view public.v_hourly_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day,
       extract(hour from s.created_at at time zone b.timezone)::int as hour,
       sum(case when s.doc_type='invoice' then s.total else -s.total end) as net_sales, count(*) as docs
  from public.sales s join public.branches b on b.id = s.branch_id
 group by 1,2,3,4;

create or replace view public.v_stock_levels with (security_invoker = true) as
select m.tenant_id, m.branch_id, m.item_id, sum(m.qty) as qty
  from public.stock_movements m group by 1,2,3;

create or replace view public.v_cashier_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day, s.created_by,
       coalesce(mb.display_name,'') as cashier,
       count(*) filter (where s.doc_type='invoice') as invoices,
       coalesce(sum(s.total) filter (where s.doc_type='invoice'),0) as sales,
       coalesce(sum(s.discount_total) filter (where s.doc_type='invoice'),0) as discounts,
       coalesce(sum(s.total) filter (where s.doc_type='credit_note'),0) as refunds
  from public.sales s join public.branches b on b.id = s.branch_id
  left join public.memberships mb on mb.tenant_id = s.tenant_id and mb.user_id = s.created_by
 group by 1,2,3,4,5;

create or replace view public.v_exceptions with (security_invoker = true) as
select a.id, a.tenant_id, a.branch_id, a.created_at, a.action, a.amount, a.reason, a.meta,
       a.user_id, u.display_name as user_name, a.approved_by, ap.display_name as approver_name, a.entity_id
  from public.audit_log a
  left join public.memberships u  on u.tenant_id  = a.tenant_id and u.user_id  = a.user_id
  left join public.memberships ap on ap.tenant_id = a.tenant_id and ap.user_id = a.approved_by;

create or replace view public.v_trial_balance with (security_invoker = true) as
select a.tenant_id, a.code, a.name_en, a.name_ar, a.type, a.system_key,
       coalesce(sum(jl.debit),0)::bigint as debit, coalesce(sum(jl.credit),0)::bigint as credit,
       coalesce(sum(jl.debit - jl.credit),0)::bigint as balance
  from public.accounts a left join public.journal_lines jl on jl.account_id = a.id
 group by 1,2,3,4,5,6;

grant select on public.v_daily_sales, public.v_tender_daily, public.v_item_sales, public.v_hourly_sales,
  public.v_stock_levels, public.v_cashier_sales, public.v_exceptions, public.v_trial_balance to authenticated;

-- ===== 20261118000005_dashboards.sql
-- Z Trust MVP · role-based dashboard layouts
-- The owner chooses which widgets each role sees. Widgets still only show data the role is allowed to read (RLS).

create table public.dashboard_layouts (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  role      public.member_role not null,
  widgets   text[] not null,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, role)
);
alter table public.dashboard_layouts enable row level security;
create policy dl_read  on public.dashboard_layouts for select to authenticated using (public.is_member(tenant_id));
create policy dl_write on public.dashboard_layouts for all to authenticated
  using (public.my_role(tenant_id) = 'owner') with check (public.my_role(tenant_id) = 'owner');

-- ===== 20261118000006_roles_kitchen_purchasing.sql
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

-- ===== 20261118000007_accounting.sql
-- Z Trust · audit-ready accounting
--  * Verifiable ledger: gapless entry numbers per business and a SHA-256 hash computed from the stored entry + lines,
--    chained to the previous entry. verify_ledger() recomputes everything and reports any break.
--  * Statement-ready chart of accounts (sections), custom accounts, opening balances through manual journals.
--  * Manual journals with maker-checker approval, reversing entries, period close/lock (reopen = owner + reason).
--  * Expenses with input VAT, supplier payments, trial balance, ledger, P&L, balance sheet, VAT return, AR/AP aging.

-- ================================================================ permissions
insert into public.permission_catalog(key, module, name_en, name_ar, limit_kind, sort) values
  ('finance.journal','finance','Prepare manual journal entries','إعداد قيود يومية يدوية',null,71),
  ('finance.post','finance','Approve and post journal entries (max amount)','اعتماد وترحيل القيود (حد أقصى)','money',72),
  ('finance.close','finance','Close accounting periods','إقفال الفترات المحاسبية',null,73),
  ('finance.manage','finance','Manage chart of accounts','إدارة دليل الحسابات',null,74),
  ('expenses.create','finance','Record expenses','تسجيل المصروفات',null,75),
  ('payables.pay','finance','Pay suppliers','سداد الموردين',null,76);

update public.role_templates set perms = perms || '{"finance.journal":null,"finance.close":null,"finance.manage":null,"expenses.create":null,"payables.pay":null}' where key = 'accountant';
update public.role_templates set perms = perms || '{"expenses.create":null,"finance.post":1000}' where key = 'manager';

-- give only the NEW permissions to existing system roles (never re-add something an owner removed)
insert into public.role_permissions(tenant_id, role, permission, limit_value)
select r.tenant_id, r.key, x.perm, case when x.lim is null then null else x.lim * power(10, t.currency_decimals) end
  from public.roles r join public.tenants t on t.id = r.tenant_id
  join (values ('accountant','finance.journal',null::numeric),('accountant','finance.close',null),('accountant','finance.manage',null),
               ('accountant','expenses.create',null),('accountant','payables.pay',null),
               ('manager','expenses.create',null),('manager','finance.post',1000)) x(role, perm, lim) on x.role = r.key
on conflict do nothing;

-- ================================================================ chart of accounts
alter table public.coa_template add column section text;
alter table public.accounts add column section text;
alter table public.accounts add column is_active boolean not null default true;
alter table public.accounts add column is_system boolean not null default false;
alter table public.accounts add column description text;

insert into public.coa_template(system_key, code, name_en, name_ar, type) values
  ('petty_cash',        '1015','Petty cash',                    'العهدة النقدية',              'asset'),
  ('vat_input',         '1110','VAT receivable (input VAT)',    'ضريبة المدخلات القابلة للاسترداد','asset'),
  ('prepaid',           '1300','Prepaid expenses',              'مصروفات مدفوعة مقدماً',        'asset'),
  ('fixed_assets',      '1500','Property and equipment',        'الممتلكات والمعدات',          'asset'),
  ('acc_depreciation',  '1590','Accumulated depreciation',      'مجمع الإهلاك',                'asset'),
  ('accruals',          '2300','Accrued expenses',              'مصروفات مستحقة',              'liability'),
  ('salaries_payable',  '2400','Salaries payable',              'رواتب مستحقة',                'liability'),
  ('retained_earnings', '3100','Retained earnings',             'الأرباح المحتجزة',            'equity'),
  ('opening_balance',   '3900','Opening balance equity',        'حقوق ملكية الأرصدة الافتتاحية','equity'),
  ('other_income',      '4900','Other income',                  'إيرادات أخرى',                'income'),
  ('exp_salaries',      '6000','Salaries and wages',            'الرواتب والأجور',             'expense'),
  ('exp_rent',          '6100','Rent',                          'الإيجار',                     'expense'),
  ('exp_utilities',     '6200','Utilities',                     'الكهرباء والماء والاتصالات',   'expense'),
  ('exp_bank_fees',     '6300','Bank and card fees',            'عمولات البنوك والبطاقات',      'expense'),
  ('exp_marketing',     '6400','Marketing',                     'التسويق',                     'expense'),
  ('exp_maintenance',   '6500','Repairs and maintenance',       'الصيانة والإصلاحات',          'expense'),
  ('exp_depreciation',  '6600','Depreciation',                  'الإهلاك',                     'expense'),
  ('exp_general',       '6900','General and administrative',    'مصروفات عمومية وإدارية',      'expense')
on conflict (system_key) do nothing;
update public.coa_template set name_en = 'Owner capital', name_ar = 'رأس المال' where system_key = 'equity';

update public.coa_template set section = case
  when system_key in ('cash','petty_cash','bank','card_clearing','gateway_clearing','other_clearing','ar','vat_input','inventory','prepaid') then 'current_asset'
  when system_key = 'fixed_assets' then 'non_current_asset'
  when system_key = 'acc_depreciation' then 'contra_asset'
  when system_key in ('ap','vat_payable','store_credit','accruals','salaries_payable') then 'current_liability'
  when system_key in ('equity','retained_earnings','opening_balance') then 'equity'
  when system_key = 'sales' then 'revenue'
  when system_key = 'other_income' then 'other_income'
  when system_key in ('cogs','inventory_adjustments') then 'cogs'
  else 'operating_expense' end;
alter table public.coa_template alter column section set not null;

-- existing businesses: add the new accounts, then classify every system account
insert into public.accounts(tenant_id, code, name_en, name_ar, type, system_key)
select t.id, c.code, c.name_en, c.name_ar, c.type, c.system_key from public.tenants t cross join public.coa_template c
on conflict do nothing;
update public.accounts a set section = c.section, is_system = true,
       name_en = case when a.system_key = 'equity' then c.name_en else a.name_en end,
       name_ar = case when a.system_key = 'equity' then c.name_ar else a.name_ar end
  from public.coa_template c where c.system_key = a.system_key;
update public.accounts set section = case type when 'asset' then 'current_asset' when 'liability' then 'current_liability'
  when 'equity' then 'equity' when 'income' then 'revenue' else 'operating_expense' end where section is null;
alter table public.accounts alter column section set not null;
alter table public.accounts add constraint accounts_section_chk check (section in
  ('current_asset','non_current_asset','contra_asset','current_liability','non_current_liability','equity',
   'revenue','other_income','cogs','operating_expense','other_expense'));

-- accountants add their own accounts; system accounts keep their code, key and type
grant insert, update on public.accounts to authenticated;
create policy accounts_insert on public.accounts for insert to authenticated
  with check (public.has_perm(tenant_id, 'finance.manage') and system_key is null and not is_system);
create policy accounts_update on public.accounts for update to authenticated
  using (public.has_perm(tenant_id, 'finance.manage')) with check (public.has_perm(tenant_id, 'finance.manage'));
create or replace function public.guard_account() returns trigger language plpgsql as $$
begin
  if old.is_system and (new.code, new.system_key, new.type, new.is_system, new.tenant_id)
       is distinct from (old.code, old.system_key, old.type, old.is_system, old.tenant_id) then
    raise exception 'system accounts keep their code and type' using errcode = 'P0001';
  end if;
  if not old.is_system and (new.system_key is not null or new.is_system) then
    raise exception 'custom accounts cannot become system accounts' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger accounts_guard before update on public.accounts for each row execute function public.guard_account();

create or replace function public.create_tenant_accounts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- keep new tenants' accounts classified (create_tenant copies code/name/type/system_key only)
  if new.system_key is not null then
    select c.section, true into new.section, new.is_system from coa_template c where c.system_key = new.system_key;
  end if;
  return new;
end $$;
create trigger accounts_classify before insert on public.accounts for each row execute function public.create_tenant_accounts();

-- ================================================================ verifiable ledger
alter table public.journal_entries add column entry_no bigint;
alter table public.journal_entries add column reference text;
alter table public.journal_entries add column approved_by uuid;
alter table public.journal_entries add column reversal_of bigint references public.journal_entries(id);
alter table public.journal_entries alter column hash drop not null;
alter table public.journal_entries alter column created_at set default clock_timestamp();

-- deterministic digest of a stored entry and its lines
create or replace function public._entry_digest(p_id bigint) returns text
language sql stable security definer set search_path = public, extensions as $$
  select encode(digest(
      coalesce(e.prev_hash,'') || '|' || e.tenant_id::text || '|' || e.entry_no::text || '|' || to_char(e.entry_date,'YYYY-MM-DD')
      || '|' || e.source_type || '|' || coalesce(e.source_id::text,'') || '|' || coalesce(e.memo,'') || '|' || coalesce(e.reference,'')
      || '|' || coalesce(e.approved_by::text,'') || '|' || coalesce(e.reversal_of::text,'')
      || '|' || to_char(e.created_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US')
      || '|' || coalesce((select string_agg(l.account_id::text || ':' || l.debit || ':' || l.credit || ':' || coalesce(l.branch_id::text,'')
                                            || ':' || coalesce(l.customer_id::text,'') || ':' || coalesce(l.supplier_id::text,''), ';' order by l.id)
                            from journal_lines l where l.entry_id = e.id), ''),
      'sha256'), 'hex')
  from journal_entries e where e.id = p_id;
$$;

-- an entry is sealed once its hash is set; before that only the hash may be filled in
drop trigger journal_entries_immutable on public.journal_entries;
create or replace function public.guard_journal_entry() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'journal_entries is append-only' using errcode = 'P0001'; end if;
  if coalesce(current_setting('zt.allow_rehash', true), '') = 'on' then return new; end if;
  if old.hash is null and new.hash is not null and (to_jsonb(new) - 'hash') = (to_jsonb(old) - 'hash') then return new; end if;
  raise exception 'journal_entries is append-only' using errcode = 'P0001';
end $$;
create trigger journal_entries_guard before update or delete on public.journal_entries for each row execute function public.guard_journal_entry();

create or replace function public.guard_journal_line() returns trigger language plpgsql as $$
begin
  if (select hash from journal_entries where id = new.entry_id) is not null then
    raise exception 'journal entry % is sealed', new.entry_id using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger journal_lines_seal before insert on public.journal_lines for each row execute function public.guard_journal_line();

-- backfill numbering and re-hash existing entries with the verifiable scheme
select set_config('zt.allow_rehash', 'on', false);
update public.journal_entries e set entry_no = x.n
  from (select id, row_number() over (partition by tenant_id order by id) n from public.journal_entries) x where x.id = e.id;
do $$
declare r record; v_prev text; v_tenant uuid;
begin
  for r in select id, tenant_id from public.journal_entries order by tenant_id, entry_no loop
    if v_tenant is distinct from r.tenant_id then v_prev := null; v_tenant := r.tenant_id; end if;
    update public.journal_entries set prev_hash = v_prev where id = r.id;
    update public.journal_entries set hash = public._entry_digest(r.id) where id = r.id returning hash into v_prev;
  end loop;
end $$;
select set_config('zt.allow_rehash', '', false);
alter table public.journal_entries alter column entry_no set not null;
alter table public.journal_entries add constraint journal_entries_no_uq unique (tenant_id, entry_no);

-- ================================================================ periods
create table public.fiscal_periods (
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  period_start date not null,
  period_end   date not null,
  status       text not null default 'closed' check (status = 'closed'),
  closed_by    uuid not null,
  closed_at    timestamptz not null default now(),
  primary key (tenant_id, period_start)
);
alter table public.fiscal_periods enable row level security;
create policy fp_read on public.fiscal_periods for select to authenticated using (public.has_perm(tenant_id, 'finance.view'));
revoke insert, update, delete on public.fiscal_periods from anon, authenticated;

create or replace function public.guard_period() returns trigger language plpgsql as $$
begin
  if exists (select 1 from fiscal_periods p where p.tenant_id = new.tenant_id and new.entry_date between p.period_start and p.period_end) then
    raise exception 'PERIOD_CLOSED:%', to_char(new.entry_date, 'YYYY-MM') using errcode = 'ZT423';
  end if;
  return new;
end $$;
create trigger journal_entries_period before insert on public.journal_entries for each row execute function public.guard_period();

-- ================================================================ posting
-- lines: [{"key":"cash" | "account_id":"…", "debit":n | "credit":n, "customer_id"?, "supplier_id"?, "branch_id"?}]
create or replace function public._post_ex(p_tenant uuid, p_branch uuid, p_source text, p_source_id uuid, p_memo text, p_lines jsonb,
                                           p_date date default null, p_reference text default null, p_approved_by uuid default null,
                                           p_reversal_of bigint default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_dr bigint; v_cr bigint; v_prev text; v_no bigint; v_id bigint; l jsonb; v_acct uuid;
begin
  select coalesce(sum((x->>'debit')::bigint),0), coalesce(sum((x->>'credit')::bigint),0) into v_dr, v_cr
    from jsonb_array_elements(p_lines) x;
  if v_dr <> v_cr then raise exception 'unbalanced journal: debit % credit %', v_dr, v_cr; end if;
  if v_dr = 0 then return null; end if;

  perform pg_advisory_xact_lock(hashtext('je:' || p_tenant::text));
  select hash, entry_no into v_prev, v_no from journal_entries where tenant_id = p_tenant order by entry_no desc limit 1;
  insert into journal_entries(tenant_id, branch_id, entry_no, entry_date, source_type, source_id, memo, reference, approved_by,
                              reversal_of, prev_hash, hash, created_by)
  values (p_tenant, p_branch, coalesce(v_no, 0) + 1, coalesce(p_date, current_date), p_source, p_source_id, p_memo, p_reference,
          p_approved_by, p_reversal_of, v_prev, null, auth.uid())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'debit')::bigint,0) = 0 and coalesce((l->>'credit')::bigint,0) = 0 then continue; end if;
    if (l->>'debit')::bigint < 0 or (l->>'credit')::bigint < 0 then raise exception 'negative journal amount'; end if;
    if l ? 'account_id' then
      select id into v_acct from accounts where id = (l->>'account_id')::uuid and tenant_id = p_tenant;
      if v_acct is null then raise exception 'unknown account'; end if;
    else
      v_acct := _acct(p_tenant, l->>'key');
    end if;
    insert into journal_lines(tenant_id, entry_id, account_id, branch_id, debit, credit, customer_id, supplier_id)
    values (p_tenant, v_id, v_acct, coalesce(nullif(l->>'branch_id','')::uuid, p_branch),
            coalesce((l->>'debit')::bigint,0), coalesce((l->>'credit')::bigint,0),
            nullif(l->>'customer_id','')::uuid, nullif(l->>'supplier_id','')::uuid);
  end loop;
  update journal_entries set hash = _entry_digest(v_id) where id = v_id;
  return v_id;
end $$;

create or replace function public._post(p_tenant uuid, p_branch uuid, p_source text, p_source_id uuid, p_memo text, p_lines jsonb) returns bigint
language sql security definer set search_path = public as $$
  select public._post_ex(p_tenant, p_branch, p_source, p_source_id, p_memo, p_lines);
$$;

create or replace function public.verify_ledger(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not has_perm(p_tenant, 'finance.view') then raise exception 'not allowed' using errcode = '42501'; end if;
  with e as (
    select id, entry_no, hash, prev_hash,
           lag(hash) over (order by entry_no) as expected_prev,
           lag(entry_no) over (order by entry_no) as prev_no,
           _entry_digest(id) as recomputed
      from journal_entries where tenant_id = p_tenant
  ), bad as (
    select entry_no from e where hash is distinct from recomputed or prev_hash is distinct from expected_prev
  ), unb as (
    select je.entry_no from journal_lines l join journal_entries je on je.id = l.entry_id
     where l.tenant_id = p_tenant group by je.entry_no having sum(l.debit) <> sum(l.credit)
  )
  select jsonb_build_object(
    'entries', (select count(*) from e),
    'first_entry', (select min(entry_no) from e), 'last_entry', (select max(entry_no) from e),
    'hash_mismatches', (select count(*) from e where hash is distinct from recomputed),
    'chain_breaks', (select count(*) from e where prev_hash is distinct from expected_prev),
    'numbering_gaps', (select count(*) from e where prev_no is not null and entry_no <> prev_no + 1),
    'unbalanced_entries', (select count(*) from unb),
    'total_debit', (select coalesce(sum(debit),0) from journal_lines where tenant_id = p_tenant),
    'total_credit', (select coalesce(sum(credit),0) from journal_lines where tenant_id = p_tenant),
    'problem_entries', (select coalesce(jsonb_agg(entry_no order by entry_no), '[]') from (select entry_no from bad union select entry_no from unb limit 50) x),
    'last_hash', (select hash from e order by entry_no desc limit 1),
    'checked_at', now()) into v;
  return v;
end $$;

-- ================================================================ manual journals (maker-checker)
create table public.journal_drafts (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  branch_id     uuid references public.branches(id),
  entry_date    date not null,
  memo          text not null,
  reference     text,
  lines         jsonb not null,
  total         bigint not null,
  status        text not null default 'draft' check (status in ('draft','posted','rejected')),
  created_by    uuid not null,
  created_at    timestamptz not null default now(),
  reviewed_by   uuid,
  reviewed_at   timestamptz,
  review_note   text,
  posted_entry_id bigint references public.journal_entries(id)
);
alter table public.journal_drafts enable row level security;
create policy jd_read on public.journal_drafts for select to authenticated
  using (public.has_perm(tenant_id,'finance.journal') or public.has_perm(tenant_id,'finance.post') or public.has_perm(tenant_id,'finance.view'));
revoke insert, update, delete on public.journal_drafts from anon, authenticated;

-- p = { id?, tenant_id, branch_id?, entry_date, memo, reference?, lines: [{account_id, debit|credit, customer_id?, supplier_id?}] }
create or replace function public.save_journal_draft(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_id uuid := nullif(p->>'id','')::uuid; l jsonb; v_dr bigint := 0; v_cr bigint := 0; d journal_drafts%rowtype;
begin
  perform _require(v_tenant, 'finance.journal', null, null);
  if coalesce(trim(p->>'memo'),'') = '' then raise exception 'a description is required' using errcode = 'ZT422'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) < 2 then raise exception 'a journal needs at least two lines' using errcode = 'ZT422'; end if;
  for l in select * from jsonb_array_elements(p->'lines') loop
    if not exists (select 1 from accounts where id = (l->>'account_id')::uuid and tenant_id = v_tenant and is_active) then
      raise exception 'unknown or inactive account'; end if;
    if (coalesce((l->>'debit')::bigint,0) > 0) = (coalesce((l->>'credit')::bigint,0) > 0) then
      raise exception 'each line needs either a debit or a credit' using errcode = 'ZT422'; end if;
    if coalesce((l->>'debit')::bigint,0) < 0 or coalesce((l->>'credit')::bigint,0) < 0 then raise exception 'negative amount'; end if;
    v_dr := v_dr + coalesce((l->>'debit')::bigint,0); v_cr := v_cr + coalesce((l->>'credit')::bigint,0);
  end loop;
  if v_dr <> v_cr then raise exception 'debits (%) must equal credits (%)', v_dr, v_cr using errcode = 'ZT422'; end if;
  if exists (select 1 from fiscal_periods fp where fp.tenant_id = v_tenant and (p->>'entry_date')::date between fp.period_start and fp.period_end) then
    raise exception 'PERIOD_CLOSED:%', to_char((p->>'entry_date')::date, 'YYYY-MM') using errcode = 'ZT423';
  end if;

  if v_id is null then
    insert into journal_drafts(tenant_id, branch_id, entry_date, memo, reference, lines, total, created_by)
    values (v_tenant, nullif(p->>'branch_id','')::uuid, (p->>'entry_date')::date, p->>'memo', nullif(p->>'reference',''), p->'lines', v_dr, auth.uid())
    returning id into v_id;
  else
    select * into d from journal_drafts where id = v_id and tenant_id = v_tenant for update;
    if not found or d.status <> 'draft' then raise exception 'only drafts can be edited' using errcode = 'ZT422'; end if;
    if d.created_by <> auth.uid() then raise exception 'only the preparer can edit a draft' using errcode = '42501'; end if;
    update journal_drafts set branch_id = nullif(p->>'branch_id','')::uuid, entry_date = (p->>'entry_date')::date, memo = p->>'memo',
           reference = nullif(p->>'reference',''), lines = p->'lines', total = v_dr where id = v_id;
  end if;
  return v_id;
end $$;

-- the preparer can never post their own journal (the owner is exempt)
create or replace function public.post_journal_draft(p_id uuid, p_pin text default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare d journal_drafts%rowtype; v_appr uuid; v_actor uuid; v_self boolean; v_entry bigint;
begin
  select * into d from journal_drafts where id = p_id for update;
  if not found or not is_member(d.tenant_id) then raise exception 'journal not found'; end if;
  if d.status <> 'draft' then raise exception 'journal already %', d.status using errcode = 'ZT422'; end if;
  v_self := d.created_by = auth.uid() and my_role(d.tenant_id) <> 'owner';
  if v_self then
    if coalesce(p_pin,'') = '' then raise exception 'APPROVAL_REQUIRED:finance.post' using errcode = 'ZT401'; end if;
    select m.user_id into v_appr from memberships m
     where m.tenant_id = d.tenant_id and m.is_active and m.user_id <> d.created_by
       and m.pin_hash is not null and m.pin_hash = crypt(p_pin, m.pin_hash)
       and role_has(d.tenant_id, m.role, 'finance.post')
       and (role_limit(d.tenant_id, m.role, 'finance.post') is null or d.total <= role_limit(d.tenant_id, m.role, 'finance.post'))
     limit 1;
    if v_appr is null then raise exception 'APPROVAL_DENIED:finance.post' using errcode = 'ZT403'; end if;
  else
    v_appr := _require(d.tenant_id, 'finance.post', d.total, p_pin);
  end if;
  v_actor := coalesce(v_appr, auth.uid());
  if v_actor = d.created_by and (select role from memberships where tenant_id = d.tenant_id and user_id = v_actor) <> 'owner' then
    raise exception 'APPROVAL_DENIED:finance.post' using errcode = 'ZT403';
  end if;
  v_entry := _post_ex(d.tenant_id, d.branch_id, 'manual', d.id, d.memo,
                      (select jsonb_agg(x - 'memo') from jsonb_array_elements(d.lines) x), d.entry_date, d.reference, v_actor);
  update journal_drafts set status = 'posted', reviewed_by = v_actor, reviewed_at = now(), posted_entry_id = v_entry where id = d.id;
  perform _audit(d.tenant_id, d.branch_id, 'journal.post', 'journal', d.id, d.total, d.memo, v_appr,
                 jsonb_build_object('entry_no', (select entry_no from journal_entries where id = v_entry)));
  return v_entry;
end $$;

create or replace function public.reject_journal_draft(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare d journal_drafts%rowtype;
begin
  select * into d from journal_drafts where id = p_id for update;
  if not found or d.status <> 'draft' then raise exception 'only drafts can be rejected'; end if;
  perform _require(d.tenant_id, 'finance.post', null, null);
  if coalesce(trim(p_note),'') = '' then raise exception 'a reason is required' using errcode = 'ZT422'; end if;
  update journal_drafts set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note where id = d.id;
  perform _audit(d.tenant_id, d.branch_id, 'journal.reject', 'journal', d.id, d.total, p_note, null);
end $$;

create or replace function public.reverse_entry(p_entry bigint, p_date date, p_reason text) returns bigint
language plpgsql security definer set search_path = public as $$
declare e journal_entries%rowtype; v_new bigint;
begin
  select * into e from journal_entries where id = p_entry;
  if not found then raise exception 'entry not found'; end if;
  perform _require(e.tenant_id, 'finance.post', null, null);
  if coalesce(trim(p_reason),'') = '' then raise exception 'a reason is required' using errcode = 'ZT422'; end if;
  if exists (select 1 from journal_entries where reversal_of = e.id) then raise exception 'entry already reversed' using errcode = 'ZT422'; end if;
  if e.source_type <> 'manual' then
    raise exception 'operational entries are corrected at the source (refund, cancel, credit note), not by reversal' using errcode = 'ZT422';
  end if;
  v_new := _post_ex(e.tenant_id, e.branch_id, 'reversal', e.source_id, 'Reversal of JV-' || e.entry_no || ': ' || p_reason,
    (select jsonb_agg(jsonb_build_object('account_id', l.account_id, 'debit', l.credit, 'credit', l.debit, 'branch_id', l.branch_id,
                                         'customer_id', l.customer_id, 'supplier_id', l.supplier_id) order by l.id)
       from journal_lines l where l.entry_id = e.id),
    coalesce(p_date, current_date), e.reference, auth.uid(), e.id);
  perform _audit(e.tenant_id, e.branch_id, 'journal.reverse', 'journal', e.source_id, null, p_reason, null,
                 jsonb_build_object('entry_no', e.entry_no, 'reversal_no', (select entry_no from journal_entries where id = v_new)));
  return v_new;
end $$;

-- ================================================================ periods: close / reopen
create or replace function public.close_period(p_tenant uuid, p_year int, p_month int) returns void
language plpgsql security definer set search_path = public as $$
declare v_start date := make_date(p_year, p_month, 1);
begin
  perform _require(p_tenant, 'finance.close', null, null);
  -- only finished months: closing the running month would stop every sale at the till
  if v_start >= date_trunc('month', current_date)::date then raise exception 'only finished months can be closed' using errcode = 'ZT422'; end if;
  if exists (select 1 from journal_drafts where tenant_id = p_tenant and status = 'draft'
             and entry_date between v_start and (v_start + interval '1 month - 1 day')::date) then
    raise exception 'post or reject the draft journals of this period first' using errcode = 'ZT422';
  end if;
  insert into fiscal_periods(tenant_id, period_start, period_end, closed_by)
  values (p_tenant, v_start, (v_start + interval '1 month - 1 day')::date, auth.uid()) on conflict do nothing;
  perform _audit(p_tenant, null, 'period.close', 'period', null, null, to_char(v_start,'YYYY-MM'), null);
end $$;

create or replace function public.reopen_period(p_tenant uuid, p_year int, p_month int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can reopen a closed period' using errcode = '42501'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'a reason is required' using errcode = 'ZT422'; end if;
  delete from fiscal_periods where tenant_id = p_tenant and period_start = make_date(p_year, p_month, 1);
  perform _audit(p_tenant, null, 'period.reopen', 'period', null, null, to_char(make_date(p_year,p_month,1),'YYYY-MM') || ': ' || p_reason, null);
end $$;

-- ================================================================ expenses & supplier payments
create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  entry_date  date not null,
  account_id  uuid not null references public.accounts(id),
  supplier_id uuid references public.suppliers(id),
  description text not null,
  amount      bigint not null check (amount > 0),
  vat         bigint not null default 0 check (vat >= 0),
  total       bigint not null,
  paid_from   text not null check (paid_from in ('cash','petty_cash','bank','ap')),
  reference   text,
  entry_id    bigint references public.journal_entries(id),
  created_by  uuid not null,
  created_at  timestamptz not null default now()
);
create table public.supplier_payments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  supplier_id uuid not null references public.suppliers(id),
  entry_date  date not null,
  amount      bigint not null check (amount > 0),
  paid_from   text not null check (paid_from in ('cash','bank')),
  reference   text,
  entry_id    bigint references public.journal_entries(id),
  created_by  uuid not null,
  created_at  timestamptz not null default now()
);
alter table public.expenses enable row level security;
alter table public.supplier_payments enable row level security;
create policy ex_read on public.expenses for select to authenticated
  using ((public.has_perm(tenant_id,'expenses.create') or public.has_perm(tenant_id,'finance.view')) and public.can_see_branch(tenant_id, branch_id));
create policy sp_read on public.supplier_payments for select to authenticated
  using (public.has_perm(tenant_id,'payables.pay') or public.has_perm(tenant_id,'finance.view'));
revoke insert, update, delete on public.expenses, public.supplier_payments from anon, authenticated;

-- p = { tenant_id, branch_id, entry_date?, account_id, description, amount, vat?, paid_from, supplier_id?, reference? }
create or replace function public.record_expense(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; a accounts%rowtype;
        v_amt bigint := (p->>'amount')::bigint; v_vat bigint := coalesce((p->>'vat')::bigint, 0); v_from text := p->>'paid_from';
        v_sup uuid := nullif(p->>'supplier_id','')::uuid; v_id uuid := gen_random_uuid(); v_entry bigint;
begin
  if not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'expenses.create', null, null);
  select * into a from accounts where id = (p->>'account_id')::uuid and tenant_id = v_tenant and is_active;
  if not found or a.section not in ('operating_expense','other_expense','cogs','non_current_asset','current_asset') or a.system_key in ('cash','bank','ar','inventory','card_clearing','gateway_clearing','other_clearing','petty_cash','vat_input') then
    raise exception 'choose an expense or asset account' using errcode = 'ZT422'; end if;
  if coalesce(trim(p->>'description'),'') = '' then raise exception 'a description is required' using errcode = 'ZT422'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'amount must be positive' using errcode = 'ZT422'; end if;
  if v_from = 'ap' and v_sup is null then raise exception 'choose the supplier for an unpaid bill' using errcode = 'ZT422'; end if;
  if v_sup is not null and not exists (select 1 from suppliers where id = v_sup and tenant_id = v_tenant) then raise exception 'unknown supplier'; end if;

  v_entry := _post_ex(v_tenant, v_branch, 'expense', v_id, p->>'description', jsonb_build_array(
      jsonb_build_object('account_id', a.id, 'debit', v_amt),
      jsonb_build_object('key', 'vat_input', 'debit', v_vat),
      jsonb_build_object('key', v_from, 'credit', v_amt + v_vat, 'supplier_id', case when v_from = 'ap' then v_sup end)),
    coalesce(nullif(p->>'entry_date','')::date, current_date), nullif(p->>'reference',''));
  insert into expenses(id, tenant_id, branch_id, entry_date, account_id, supplier_id, description, amount, vat, total, paid_from, reference, entry_id, created_by)
  values (v_id, v_tenant, v_branch, coalesce(nullif(p->>'entry_date','')::date, current_date), a.id, v_sup, p->>'description', v_amt, v_vat,
          v_amt + v_vat, v_from, nullif(p->>'reference',''), v_entry, auth.uid());
  perform _audit(v_tenant, v_branch, 'expense.record', 'expense', v_id, v_amt + v_vat, p->>'description', null);
  return v_id;
end $$;

create or replace function public.supplier_balance(p_supplier uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(jl.credit - jl.debit),0)::bigint from journal_lines jl join accounts a on a.id = jl.account_id
   where jl.supplier_id = p_supplier and a.system_key = 'ap' and can_purchasing(jl.tenant_id);
$$;

-- p = { tenant_id, branch_id, supplier_id, amount, paid_from: cash|bank, entry_date?, reference? }
create or replace function public.pay_supplier(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_sup uuid := (p->>'supplier_id')::uuid;
        v_amt bigint := (p->>'amount')::bigint; v_id uuid := gen_random_uuid(); v_entry bigint; v_owed bigint;
begin
  if not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'payables.pay', null, null);
  if not exists (select 1 from suppliers where id = v_sup and tenant_id = v_tenant) then raise exception 'unknown supplier'; end if;
  if p->>'paid_from' not in ('cash','bank') then raise exception 'pay from cash or bank' using errcode = 'ZT422'; end if;
  select coalesce(sum(jl.credit - jl.debit),0) into v_owed from journal_lines jl join accounts a on a.id = jl.account_id
   where jl.supplier_id = v_sup and a.system_key = 'ap';
  if v_amt is null or v_amt <= 0 or v_amt > v_owed then
    raise exception 'amount must be between 0 and the balance owed (%)', v_owed using errcode = 'ZT422'; end if;
  v_entry := _post_ex(v_tenant, v_branch, 'supplier_payment', v_id, 'Payment to ' || (select name from suppliers where id = v_sup),
    jsonb_build_array(jsonb_build_object('key','ap','debit', v_amt, 'supplier_id', v_sup),
                      jsonb_build_object('key', p->>'paid_from', 'credit', v_amt)),
    coalesce(nullif(p->>'entry_date','')::date, current_date), nullif(p->>'reference',''));
  insert into supplier_payments(id, tenant_id, branch_id, supplier_id, entry_date, amount, paid_from, reference, entry_id, created_by)
  values (v_id, v_tenant, v_branch, v_sup, coalesce(nullif(p->>'entry_date','')::date, current_date), v_amt, p->>'paid_from',
          nullif(p->>'reference',''), v_entry, auth.uid());
  perform _audit(v_tenant, v_branch, 'supplier.pay', 'supplier', v_sup, v_amt, p->>'reference', null);
  return v_id;
end $$;

-- ================================================================ statements
create or replace function public._fin_guard(p_tenant uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_perm(p_tenant, 'finance.view') then raise exception 'not allowed' using errcode = '42501'; end if;
end $$;

create or replace function public.fin_trial_balance(p_tenant uuid, p_from date, p_to date, p_branch uuid default null)
returns table(account_id uuid, code text, name_en text, name_ar text, type public.account_type, section text,
              opening bigint, debit bigint, credit bigint, closing bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _fin_guard(p_tenant);
  return query
  select a.id, a.code, a.name_en, a.name_ar, a.type, a.section,
         coalesce(sum(l.debit - l.credit) filter (where e.entry_date < p_from), 0)::bigint,
         coalesce(sum(l.debit) filter (where e.entry_date between p_from and p_to), 0)::bigint,
         coalesce(sum(l.credit) filter (where e.entry_date between p_from and p_to), 0)::bigint,
         coalesce(sum(l.debit - l.credit) filter (where e.entry_date <= p_to), 0)::bigint
    from accounts a
    left join journal_lines l on l.account_id = a.id and (p_branch is null or l.branch_id = p_branch)
    left join journal_entries e on e.id = l.entry_id
   where a.tenant_id = p_tenant
   group by a.id order by a.code;
end $$;

create or replace function public.fin_ledger(p_tenant uuid, p_account uuid, p_from date, p_to date)
returns table(entry_no bigint, entry_date date, source_type text, memo text, reference text, debit bigint, credit bigint,
              balance bigint, party text, line_id bigint)
language plpgsql stable security definer set search_path = public as $$
declare v_open bigint;
begin
  perform _fin_guard(p_tenant);
  select coalesce(sum(l.debit - l.credit),0) into v_open from journal_lines l join journal_entries e on e.id = l.entry_id
   where l.account_id = p_account and l.tenant_id = p_tenant and e.entry_date < p_from;
  return query
  select null::bigint, p_from, 'opening'::text, 'Opening balance'::text, null::text, null::bigint, null::bigint, v_open, null::text, null::bigint
  union all
  select e.entry_no, e.entry_date, e.source_type, e.memo, e.reference, l.debit, l.credit,
         (v_open + sum(l.debit - l.credit) over (order by e.entry_date, e.entry_no, l.id))::bigint,
         coalesce(c.name, s.name), l.id
    from journal_lines l join journal_entries e on e.id = l.entry_id
    left join customers c on c.id = l.customer_id left join suppliers s on s.id = l.supplier_id
   where l.account_id = p_account and l.tenant_id = p_tenant and e.entry_date between p_from and p_to
   order by 2, 1 nulls first, 10 nulls first;
end $$;

-- amounts are signed for presentation: income and expenses as positive numbers
create or replace function public.fin_income_statement(p_tenant uuid, p_from date, p_to date, p_branch uuid default null)
returns table(section text, code text, name_en text, name_ar text, amount bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _fin_guard(p_tenant);
  return query
  select a.section, a.code, a.name_en, a.name_ar,
         (case when a.type = 'income' then sum(l.credit - l.debit) else sum(l.debit - l.credit) end)::bigint
    from accounts a join journal_lines l on l.account_id = a.id join journal_entries e on e.id = l.entry_id
   where a.tenant_id = p_tenant and a.type in ('income','expense') and e.entry_date between p_from and p_to
     and (p_branch is null or l.branch_id = p_branch)
   group by a.id having sum(l.debit) <> 0 or sum(l.credit) <> 0 order by a.code;
end $$;

-- assets as debit balances, liabilities and equity as credit balances; unclosed profit shown as current earnings
create or replace function public.fin_balance_sheet(p_tenant uuid, p_as_of date)
returns table(section text, code text, name_en text, name_ar text, amount bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _fin_guard(p_tenant);
  return query
  select a.section, a.code, a.name_en, a.name_ar,
         (case when a.type = 'asset' then sum(l.debit - l.credit) else sum(l.credit - l.debit) end)::bigint
    from accounts a join journal_lines l on l.account_id = a.id join journal_entries e on e.id = l.entry_id
   where a.tenant_id = p_tenant and a.type in ('asset','liability','equity') and e.entry_date <= p_as_of
   group by a.id having sum(l.debit - l.credit) <> 0
  union all
  select 'equity', '3999', 'Current earnings (not yet closed)', 'أرباح الفترة غير المقفلة',
         coalesce(sum(l.credit - l.debit),0)::bigint
    from journal_lines l join accounts a on a.id = l.account_id join journal_entries e on e.id = l.entry_id
   where l.tenant_id = p_tenant and a.type in ('income','expense') and e.entry_date <= p_as_of
  order by 2;
end $$;

create or replace function public.fin_vat_return(p_tenant uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform _fin_guard(p_tenant);
  select jsonb_build_object(
    'output_vat', coalesce(sum(l.credit - l.debit) filter (where a.system_key = 'vat_payable'),0),
    'input_vat',  coalesce(sum(l.debit - l.credit) filter (where a.system_key = 'vat_input'),0),
    'sales_net',  coalesce(sum(l.credit - l.debit) filter (where a.section = 'revenue'),0),
    'expenses_net', coalesce(sum(l.debit - l.credit) filter (where e.source_type = 'expense' and a.type = 'expense'),0),
    'purchases_net', coalesce(sum(l.debit - l.credit) filter (where e.source_type in ('goods_receipt','stock_receipt') and a.system_key = 'inventory'),0))
  into v
  from journal_lines l join accounts a on a.id = l.account_id join journal_entries e on e.id = l.entry_id
  where l.tenant_id = p_tenant and e.entry_date between p_from and p_to;
  return v || jsonb_build_object('net_vat', (v->>'output_vat')::bigint - (v->>'input_vat')::bigint);
end $$;

-- open items aged first-in-first-out: payments settle the oldest invoices/bills first
create or replace function public.fin_aging(p_tenant uuid, p_kind text, p_as_of date)
returns table(party_id uuid, party text, total bigint, d0_30 bigint, d31_60 bigint, d61_90 bigint, d90_plus bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _fin_guard(p_tenant);
  return query
  with mv as (
    select case when p_kind = 'ar' then l.customer_id else l.supplier_id end as pid, e.entry_date, l.id,
           case when p_kind = 'ar' then l.debit else l.credit end as dr_amt,
           case when p_kind = 'ar' then l.credit else l.debit end as cr_amt
      from journal_lines l join accounts a on a.id = l.account_id join journal_entries e on e.id = l.entry_id
     where l.tenant_id = p_tenant and a.system_key = case when p_kind = 'ar' then 'ar' else 'ap' end and e.entry_date <= p_as_of
  ), settled as (select pid, sum(cr_amt) s from mv group by pid),
  items as (
    select m.pid, m.entry_date, m.dr_amt, sum(m.dr_amt) over (partition by m.pid order by m.entry_date, m.id) as cum
      from mv m where m.dr_amt > 0
  ), opn as (
    select i.pid, i.entry_date, greatest(0, least(i.dr_amt, i.cum - coalesce(st.s,0)))::bigint as amt
      from items i left join settled st on st.pid is not distinct from i.pid
  )
  select o.pid, coalesce(c.name, s.name, 'Unassigned'),
         sum(o.amt)::bigint,
         (sum(o.amt) filter (where p_as_of - o.entry_date <= 30))::bigint,
         (sum(o.amt) filter (where p_as_of - o.entry_date between 31 and 60))::bigint,
         (sum(o.amt) filter (where p_as_of - o.entry_date between 61 and 90))::bigint,
         (sum(o.amt) filter (where p_as_of - o.entry_date > 90))::bigint
    from opn o left join customers c on c.id = o.pid left join suppliers s on s.id = o.pid
   group by o.pid, c.name, s.name having sum(o.amt) > 0 order by 3 desc;
end $$;

-- ================================================================ privileges
grant execute on function
  public.verify_ledger(uuid), public.save_journal_draft(jsonb), public.post_journal_draft(uuid,text), public.reject_journal_draft(uuid,text),
  public.reverse_entry(bigint,date,text), public.close_period(uuid,int,int), public.reopen_period(uuid,int,int,text),
  public.record_expense(jsonb), public.pay_supplier(jsonb), public.supplier_balance(uuid),
  public.fin_trial_balance(uuid,date,date,uuid), public.fin_ledger(uuid,uuid,date,date), public.fin_income_statement(uuid,date,date,uuid),
  public.fin_balance_sheet(uuid,date), public.fin_vat_return(uuid,date,date), public.fin_aging(uuid,text,date)
  to authenticated;
revoke execute on function public._post_ex(uuid,uuid,text,uuid,text,jsonb,date,text,uuid,bigint), public._entry_digest(bigint),
  public._fin_guard(uuid), public._post(uuid,uuid,text,uuid,text,jsonb) from public, anon, authenticated;

-- ===== 20261118000008_branch_hub.sql
-- Z Trust · Branch Hub (local network kitchen, works without internet)
-- A hub is a small program on one always-on device in the branch (PC, mini-PC, Raspberry Pi).
-- POS and kitchen screens talk to it over the shop Wi-Fi; it prints to network kitchen printers
-- and syncs kitchen tickets to the cloud whenever the internet is available.
-- The hub authenticates with a per-branch token (stored hashed); it never holds a user password.

alter table public.kitchen_stations add column printer_ip text check (printer_ip is null or printer_ip ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$');
alter table public.kitchen_stations add column printer_port integer not null default 9100;
alter table public.kitchen_stations add column printer_width integer not null default 80 check (printer_width in (58, 80));

alter table public.kitchen_tickets add column sale_client_id uuid;
alter table public.kitchen_tickets add column source text not null default 'cloud' check (source in ('cloud','hub'));
create index on public.kitchen_tickets(tenant_id, sale_client_id) where sale_client_id is not null;

create table public.hubs (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  branch_id    uuid not null references public.branches(id) on delete cascade,
  name         text not null,
  token_hash   text not null unique,
  last_seen_at timestamptz,
  last_ip      text,
  version      text,
  is_active    boolean not null default true,
  created_by   uuid not null,
  created_at   timestamptz not null default now()
);
alter table public.hubs enable row level security;
create policy hubs_read on public.hubs for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy hubs_update on public.hubs for update to authenticated
  using (public.has_perm(tenant_id, 'settings.manage')) with check (public.has_perm(tenant_id, 'settings.manage'));
revoke insert, delete on public.hubs from anon, authenticated;

-- returns the token ONCE; only its SHA-256 is stored
create or replace function public.create_hub(p_branch uuid, p_name text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_tenant uuid; v_token text := 'zth_' || encode(gen_random_bytes(24), 'hex');
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if v_tenant is null or not can_see_branch(v_tenant, p_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'settings.manage', null, null);
  insert into hubs(tenant_id, branch_id, name, token_hash, created_by)
  values (v_tenant, p_branch, coalesce(nullif(trim(p_name),''), 'Branch hub'), encode(digest(v_token, 'sha256'), 'hex'), auth.uid());
  perform _audit(v_tenant, p_branch, 'hub.create', 'branch', p_branch, null, p_name, null);
  return v_token;
end $$;

create or replace function public._hub(p_token text) returns public.hubs
language plpgsql security definer set search_path = public, extensions as $$
declare h hubs%rowtype;
begin
  select * into h from hubs where token_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex') and is_active;
  if not found then raise exception 'invalid hub token' using errcode = '42501'; end if;
  return h;
end $$;

-- everything the hub needs to route and print without asking anyone
create or replace function public.hub_config(p_token text, p_version text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h hubs%rowtype := _hub(p_token);
begin
  update hubs set last_seen_at = now(), version = coalesce(p_version, version) where id = h.id;
  return jsonb_build_object(
    'hub', jsonb_build_object('id', h.id, 'name', h.name, 'tenant_id', h.tenant_id, 'branch_id', h.branch_id),
    'tenant', (select jsonb_build_object('name', name, 'name_ar', name_ar, 'currency', currency) from tenants where id = h.tenant_id),
    'branch', (select jsonb_build_object('code', code, 'name', name, 'name_ar', name_ar) from branches where id = h.branch_id),
    'stations', (select coalesce(jsonb_agg(to_jsonb(s) order by s.sort, s.name), '[]') from kitchen_stations s where s.branch_id = h.branch_id and s.is_active),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'station_id', c.station_id)), '[]') from categories c where c.tenant_id = h.tenant_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'category_id', i.category_id, 'name_ar', i.name_ar)), '[]') from items i where i.tenant_id = h.tenant_id and i.is_active));
end $$;

-- p_tickets: [{id, station_id, sale_client_id, order_ref, order_type, table_no, customer_name, note, status,
--              created_at, started_at, ready_at, served_at, items:[{id, name, name_ar, qty, note, done}]}]
-- Idempotent: the hub may resend the same tickets; the latest state wins.
create or replace function public.hub_sync(p_token text, p_tickets jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h hubs%rowtype := _hub(p_token); t jsonb; v_sale uuid; v_number text; n int := 0;
begin
  for t in select * from jsonb_array_elements(coalesce(p_tickets, '[]')) loop
    if not exists (select 1 from kitchen_stations where id = (t->>'station_id')::uuid and branch_id = h.branch_id) then continue; end if;
    select id, number into v_sale, v_number from sales where tenant_id = h.tenant_id and client_id = nullif(t->>'sale_client_id','')::uuid;
    insert into kitchen_tickets(id, tenant_id, branch_id, station_id, sale_id, sale_client_id, order_ref, order_type, table_no,
                                customer_name, note, status, created_at, started_at, ready_at, served_at, source)
    values ((t->>'id')::uuid, h.tenant_id, h.branch_id, (t->>'station_id')::uuid, v_sale, nullif(t->>'sale_client_id','')::uuid,
            case when v_number is not null and coalesce(t->>'order_ref','') like 'OFF-%' then v_number else coalesce(nullif(t->>'order_ref',''), '—') end,
            coalesce(nullif(t->>'order_type',''), 'takeaway'), nullif(t->>'table_no',''),
            nullif(t->>'customer_name',''), nullif(t->>'note',''), coalesce(nullif(t->>'status',''), 'new'),
            coalesce((t->>'created_at')::timestamptz, now()), (t->>'started_at')::timestamptz, (t->>'ready_at')::timestamptz,
            (t->>'served_at')::timestamptz, 'hub')
    on conflict (id) do update set status = excluded.status, started_at = excluded.started_at, ready_at = excluded.ready_at,
           served_at = excluded.served_at, sale_id = coalesce(kitchen_tickets.sale_id, excluded.sale_id),
           order_ref = case when kitchen_tickets.order_ref like 'OFF-%' and excluded.order_ref not like 'OFF-%' then excluded.order_ref
                            when kitchen_tickets.order_ref like 'OFF-%' and v_number is not null then v_number else kitchen_tickets.order_ref end
     where kitchen_tickets.tenant_id = h.tenant_id;
    insert into kitchen_ticket_items(id, tenant_id, ticket_id, name, name_ar, qty, note, done)
    select (i->>'id')::uuid, h.tenant_id, (t->>'id')::uuid, i->>'name', nullif(i->>'name_ar',''), (i->>'qty')::numeric, nullif(i->>'note',''),
           coalesce((i->>'done')::boolean, false)
      from jsonb_array_elements(coalesce(t->'items','[]')) i
    on conflict (id) do update set done = excluded.done;
    n := n + 1;
  end loop;
  update hubs set last_seen_at = now() where id = h.id;
  return jsonb_build_object('synced', n);
end $$;

-- when an offline sale finally reaches the cloud, attach the tickets the hub already synced
create or replace function public.link_hub_tickets() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update kitchen_tickets set sale_id = new.id,
         order_ref = case when order_ref like 'OFF-%' then new.number else order_ref end
   where tenant_id = new.tenant_id and sale_client_id = new.client_id and sale_id is null;
  return new;
end $$;
create trigger sales_link_hub_tickets after insert on public.sales for each row execute function public.link_hub_tickets();

-- with a hub, the kitchen tickets come from the hub (instantly, over the LAN); the cloud must not create duplicates
create or replace function public._kitchen_from_sale(p_sale uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s sales%rowtype; k jsonb := p->'kitchen'; r record; v_ticket uuid; v_default uuid;
begin
  if k is null or jsonb_typeof(k) <> 'object' then return; end if;
  if coalesce((k->>'hub')::boolean, false) then return; end if;
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
    insert into kitchen_tickets(tenant_id, branch_id, station_id, sale_id, sale_client_id, order_ref, order_type, table_no, customer_name, note)
    values (s.tenant_id, s.branch_id, r.station_id, s.id, s.client_id, s.number,
            coalesce(nullif(k->>'order_type',''),'takeaway'), nullif(k->>'table_no',''),
            coalesce(nullif(k->>'customer_name',''), (select name from customers where id = s.customer_id)),
            nullif(k->>'note',''))
    returning id into v_ticket;
    insert into kitchen_ticket_items(tenant_id, ticket_id, name, name_ar, qty, note)
    select s.tenant_id, v_ticket, x->>'name', x->>'name_ar', (x->>'qty')::numeric, x->>'note'
      from jsonb_array_elements(r.items) x;
  end loop;
end $$;

grant execute on function public.create_hub(uuid, text) to authenticated;
grant execute on function public.hub_config(text, text), public.hub_sync(text, jsonb) to anon, authenticated;
revoke execute on function public._hub(text), public._kitchen_from_sale(uuid, jsonb), public.link_hub_tickets() from public, anon, authenticated;

-- ===== 20261118000009_recipes_receipts_delivery.sql
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

-- ===== 20261118000010_profiles_features_integrations.sql
-- Z Trust · business profiles, feature modules, shop logo, outbound events (n8n / any webhook) and API keys
--  * business_profiles: 18 profiles (9 open for sign-up today); each switches on the modules it needs
--  * feature_modules: the switchable modules; only built ones can be switched on, planned ones show as "coming soon"
--  * tenants.features: module → on/off, chosen by the owner; tenants.addons: paid add-ons set by Z Trust billing only
--  * switching a module off hides it and blocks its server actions; it never deletes data
--  * events: signed webhooks queued in an outbox and delivered with retries by the dispatch-events function
--  * API keys: hashed, scoped, read-only for now (items, stock, sales, customers)

-- ================================================================ catalog
create table public.feature_modules (
  key      text primary key,
  name_en  text not null,
  name_ar  text not null,
  built    boolean not null default false,
  sort     integer not null
);

create table public.business_profiles (
  key          text primary key,
  name_en      text not null,
  name_ar      text not null,
  family       text not null check (family in ('food','retail','services','wholesale')),
  pos_mode     text not null check (pos_mode in ('grid','scan','calendar','ticket')),
  launch       boolean not null default false,   -- open for sign-up today
  modules      jsonb not null,                    -- module key → 2 (on by default) | 1 (suggested, off)
  sort         integer not null
);

insert into public.feature_modules(key, name_en, name_ar, built, sort) values
  ('kitchen','Kitchen screen & printers','شاشة المطبخ والطابعات', true, 1),
  ('recipes','Recipes & ingredients','الوصفات والمكونات', true, 2),
  ('delivery','Delivery platforms','منصات التوصيل', true, 3),
  ('credit','Sell on account','البيع على الحساب', true, 4),
  ('purchasing','Purchasing','المشتريات', true, 5),
  ('integrations','Integrations (webhooks & API)','الربط (Webhooks و API)', true, 6),
  ('tables','Tables & floor plan','الطاولات ومخطط الصالة', false, 10),
  ('modifiers','Modifiers & add-ons','الإضافات والخيارات', false, 11),
  ('variants','Variants (size × colour)','المقاسات والألوان', false, 12),
  ('batches','Batches & expiry (FEFO)','الدفعات والصلاحية', false, 13),
  ('weighed','Weighed items & scale barcodes','البيع بالوزن والميزان', false, 14),
  ('serials','Serial / IMEI & warranty','الأرقام التسلسلية والضمان', false, 15),
  ('promotions','Promotions & bundles','العروض والباكجات', false, 16),
  ('loyalty','Loyalty points','نقاط الولاء', false, 17),
  ('appointments','Appointments & calendar','المواعيد والتقويم', false, 18),
  ('commissions','Staff commissions','عمولات الموظفين', false, 19),
  ('memberships','Packages & memberships','الباقات والعضويات', false, 20),
  ('job_cards','Job cards','تذاكر العمل', false, 21),
  ('preorders','Pre-orders & deposits','الطلب المسبق والعربون', false, 22),
  ('consignment','Consignment','بضاعة الأمانة', false, 23),
  ('quotations','Quotations & B2B prices','عروض الأسعار وأسعار الجملة', false, 24),
  ('gold_pricing','Gold-rate pricing','تسعير الذهب', false, 25);

insert into public.business_profiles(key, name_en, name_ar, family, pos_mode, launch, sort, modules) values
  ('restaurant','Restaurant','مطعم','food','grid',true,1,'{"kitchen":2,"tables":2,"modifiers":2,"recipes":2,"delivery":2,"promotions":2,"purchasing":2,"batches":1,"loyalty":1,"credit":1,"preorders":1}'),
  ('cafe','Café','مقهى','food','grid',true,2,'{"kitchen":2,"modifiers":2,"recipes":2,"delivery":2,"promotions":2,"loyalty":2,"purchasing":2,"tables":1,"batches":1}'),
  ('quick_service','Fast food & cloud kitchen','وجبات سريعة ومطابخ سحابية','food','grid',true,3,'{"kitchen":2,"modifiers":2,"recipes":2,"delivery":2,"promotions":2,"purchasing":2,"loyalty":1,"batches":1}'),
  ('bakery','Bakery & sweets','مخابز وحلويات','food','grid',false,4,'{"recipes":2,"weighed":2,"batches":2,"preorders":2,"promotions":2,"purchasing":2,"kitchen":1,"modifiers":1,"delivery":1,"loyalty":1}'),
  ('grocery','Grocery & supermarket','بقالة وسوبرماركت','retail','scan',true,5,'{"weighed":2,"batches":2,"promotions":2,"credit":2,"purchasing":2,"loyalty":1,"consignment":1,"delivery":1}'),
  ('fashion','Fashion & shoes','ملابس وأحذية','retail','scan',true,6,'{"variants":2,"promotions":2,"loyalty":2,"purchasing":2,"consignment":1,"commissions":1}'),
  ('electronics','Electronics & mobiles','إلكترونيات وجوالات','retail','scan',false,7,'{"serials":2,"promotions":2,"purchasing":2,"variants":1,"job_cards":1,"credit":1,"quotations":1}'),
  ('stationery','Stationery, books & gifts','قرطاسية وكتب وهدايا','retail','scan',true,8,'{"promotions":2,"purchasing":2,"variants":1,"quotations":1,"credit":1,"loyalty":1,"consignment":1,"modifiers":1}'),
  ('perfume','Perfume, oud & cosmetics','عطور وعود وتجميل','retail','grid',true,9,'{"variants":2,"promotions":2,"loyalty":2,"purchasing":2,"recipes":1,"weighed":1,"modifiers":1,"batches":1,"commissions":1}'),
  ('jewelry','Jewelry & gold','ذهب ومجوهرات','retail','scan',false,10,'{"gold_pricing":2,"serials":2,"weighed":2,"purchasing":2,"credit":1,"preorders":1,"commissions":1}'),
  ('florist','Florist','ورد وتنسيق','retail','grid',false,11,'{"preorders":2,"modifiers":2,"delivery":2,"purchasing":2,"recipes":1,"batches":1,"promotions":1}'),
  ('salon','Salon & barber','صالون وحلاقة','services','calendar',true,12,'{"appointments":2,"commissions":2,"memberships":2,"purchasing":1,"recipes":1,"promotions":1,"loyalty":1}'),
  ('spa','Spa & beauty centre','سبا ومركز تجميل','services','calendar',false,13,'{"appointments":2,"commissions":2,"memberships":2,"promotions":2,"recipes":1,"loyalty":1,"purchasing":1}'),
  ('laundry','Laundry','مغسلة ملابس','services','ticket',true,14,'{"job_cards":2,"preorders":2,"credit":2,"memberships":1,"delivery":1,"promotions":1}'),
  ('car_wash','Car wash & auto service','غسيل سيارات وخدمة','services','ticket',false,15,'{"job_cards":2,"memberships":2,"appointments":1,"commissions":1,"credit":1,"promotions":1}'),
  ('gym','Gym & fitness','نادي رياضي','services','calendar',false,16,'{"memberships":2,"appointments":1,"commissions":1,"promotions":1}'),
  ('repair','Repair shop','صيانة وتصليح','services','ticket',false,17,'{"job_cards":2,"serials":2,"appointments":1,"credit":1,"quotations":1,"purchasing":1}'),
  ('wholesale','Wholesale & distribution','جملة وتوزيع','wholesale','scan',false,18,'{"quotations":2,"credit":2,"purchasing":2,"batches":1,"variants":1,"promotions":1,"consignment":1}');

alter table public.feature_modules enable row level security;
alter table public.business_profiles enable row level security;
create policy fm_read on public.feature_modules for select to anon, authenticated using (true);
create policy bp_read on public.business_profiles for select to anon, authenticated using (true);
revoke insert, update, delete on public.feature_modules, public.business_profiles from anon, authenticated;

-- ================================================================ tenant profile & switches
alter table public.tenants add column business_profile text references public.business_profiles(key);
alter table public.tenants add column features jsonb not null default '{}';
alter table public.tenants add column addons jsonb not null default '{}';   -- paid add-ons (whatsapp, ai_assistant): billing only

-- the built modules a profile switches on by default
create or replace function public._profile_features(p_profile text) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_object_agg(m.key, true), '{}')
    from business_profiles p cross join lateral jsonb_each_text(p.modules) e(k, v)
    join feature_modules m on m.key = e.k and m.built
   where p.key = p_profile and e.v = '2';
$$;

-- existing businesses keep everything they could already use
update public.tenants set
  business_profile = case business_type when 'food' then 'restaurant' when 'services' then 'salon' when 'mixed' then 'restaurant' else 'grocery' end,
  features = (select jsonb_object_agg(key, true) from public.feature_modules where built and key <> 'integrations');
alter table public.tenants alter column business_profile set not null;

create or replace function public.has_feature(p_tenant uuid, p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (features->>p_key)::boolean from tenants where id = p_tenant), false);
$$;
grant execute on function public.has_feature(uuid, text) to authenticated, service_role;

create or replace function public._require_feature(p_tenant uuid, p_key text) returns void
language plpgsql stable set search_path = public as $$
begin
  if not has_feature(p_tenant, p_key) then
    raise exception 'The % module is switched off for this business', p_key using errcode = 'ZT422', hint = 'feature_off:' || p_key;
  end if;
end $$;

-- managers with settings.manage may edit the business details, but billing, currency and module switches only change through the functions below
create or replace function public.guard_tenant_update() returns trigger language plpgsql as $$
begin
  if current_setting('zt.trusted', true) = 'on' or current_user in ('postgres','service_role','supabase_admin') then return new; end if;
  if new.plan is distinct from old.plan or new.trial_ends_at is distinct from old.trial_ends_at
     or new.addons is distinct from old.addons or new.features is distinct from old.features
     or new.business_profile is distinct from old.business_profile or new.business_type is distinct from old.business_type
     or new.currency is distinct from old.currency or new.currency_decimals is distinct from old.currency_decimals
     or new.country_code is distinct from old.country_code then
    raise exception 'these fields cannot be changed here' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger tenants_guard before update on public.tenants for each row execute function public.guard_tenant_update();

-- owner: change the business type; apply_defaults switches on the new profile's modules (nothing is switched off)
create or replace function public.set_business_profile(p_tenant uuid, p_profile text, p_apply_defaults boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_fam text; v_features jsonb;
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can change the business type' using errcode = '42501'; end if;
  select family into v_fam from business_profiles where key = p_profile;
  if v_fam is null then raise exception 'unknown business type %', p_profile using errcode = 'ZT422'; end if;
  perform set_config('zt.trusted', 'on', true);
  update tenants set business_profile = p_profile,
         business_type = case v_fam when 'food' then 'food' when 'services' then 'services' else 'retail' end::business_type,
         features = case when p_apply_defaults then features || _profile_features(p_profile) else features end
   where id = p_tenant returning features into v_features;
  perform set_config('zt.trusted', 'off', true);
  if exists (select 1 from feature_modules where key = 'kitchen') and (v_features->>'kitchen')::boolean then
    insert into kitchen_stations(tenant_id, branch_id, name, name_ar, is_default)
    select p_tenant, b.id, 'Kitchen', 'المطبخ', true from branches b
     where b.tenant_id = p_tenant and not exists (select 1 from kitchen_stations k where k.branch_id = b.id);
  end if;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), 'business_profile.set', 'tenant', p_tenant, jsonb_build_object('profile', p_profile, 'apply_defaults', p_apply_defaults));
  return v_features;
end $$;

-- owner: switch one module on or off
create or replace function public.set_feature(p_tenant uuid, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m feature_modules%rowtype; v_features jsonb;
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can switch modules' using errcode = '42501'; end if;
  select * into m from feature_modules where key = p_key;
  if not found then raise exception 'unknown module %', p_key using errcode = 'ZT422'; end if;
  if p_on and not m.built then raise exception '% is coming soon', m.name_en using errcode = 'ZT422'; end if;
  perform set_config('zt.trusted', 'on', true);
  update tenants set features = features || jsonb_build_object(p_key, p_on) where id = p_tenant returning features into v_features;
  perform set_config('zt.trusted', 'off', true);
  if p_key = 'kitchen' and p_on then
    insert into kitchen_stations(tenant_id, branch_id, name, name_ar, is_default)
    select p_tenant, b.id, 'Kitchen', 'المطبخ', true from branches b
     where b.tenant_id = p_tenant and not exists (select 1 from kitchen_stations k where k.branch_id = b.id);
  end if;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), case when p_on then 'feature.on' else 'feature.off' end, 'tenant', p_tenant, jsonb_build_object('module', p_key));
  return v_features;
end $$;
grant execute on function public.set_business_profile(uuid, text, boolean), public.set_feature(uuid, text, boolean) to authenticated;
revoke execute on function public._require_feature(uuid, text), public._profile_features(text) from public, anon, authenticated;

-- onboarding: choose a profile (old clients may still send business_type)
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
  v_features := case when nullif(p->>'business_profile','') is null
                     then (select jsonb_object_agg(key, true) from feature_modules where built and key <> 'integrations')
                     else _profile_features(v_profile) end;

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

-- ================================================================ server-side gates for built modules
-- kitchen off: sales simply produce no kitchen tickets
create or replace function public._kitchen_from_sale(p_sale uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s sales%rowtype; k jsonb := p->'kitchen'; r record; v_ticket uuid; v_default uuid;
begin
  if k is null or jsonb_typeof(k) <> 'object' then return; end if;
  if coalesce((k->>'hub')::boolean, false) then return; end if;
  select * into s from sales where id = p_sale;
  if not has_feature(s.tenant_id, 'kitchen') then return; end if;   -- kitchen switched off: no tickets
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
    insert into kitchen_tickets(tenant_id, branch_id, station_id, sale_id, sale_client_id, order_ref, order_type, table_no, customer_name, note)
    values (s.tenant_id, s.branch_id, r.station_id, s.id, s.client_id, s.number,
            coalesce(nullif(k->>'order_type',''),'takeaway'), nullif(k->>'table_no',''),
            coalesce(nullif(k->>'customer_name',''), (select name from customers where id = s.customer_id)),
            nullif(k->>'note',''))
    returning id into v_ticket;
    insert into kitchen_ticket_items(tenant_id, ticket_id, name, name_ar, qty, note)
    select s.tenant_id, v_ticket, x->>'name', x->>'name_ar', (x->>'qty')::numeric, x->>'note'
      from jsonb_array_elements(r.items) x;
  end loop;
end $$;

create or replace function public.delivery_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'delivery_channels' then perform _require_feature(new.tenant_id, 'delivery');
  elsif new.channel_id is not null then perform _require_feature(new.tenant_id, 'delivery'); end if;
  return new;
end $$;
create trigger delivery_channels_gate before insert on public.delivery_channels for each row execute function public.delivery_gate();
create trigger sales_channel_gate before insert on public.sales for each row when (new.channel_id is not null) execute function public.delivery_gate();

create or replace function public.purchasing_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _require_feature(new.tenant_id, 'purchasing'); return new; end $$;
create trigger po_gate before insert on public.purchase_orders for each row execute function public.purchasing_gate();

create or replace function public.recipes_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _require_feature(new.tenant_id, 'recipes'); return new; end $$;
create trigger recipe_lines_gate before insert on public.recipe_lines for each row execute function public.recipes_gate();

create or replace function public.credit_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.tender = 'on_account' and new.amount > 0 then perform _require_feature(new.tenant_id, 'credit'); end if;
  return new;
end $$;
create trigger payments_credit_gate before insert on public.payments for each row execute function public.credit_gate();

-- ================================================================ shop logo (receipt, invoice, payment page)
do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('branding', 'branding', true, 1048576, array['image/png','image/jpeg','image/webp','image/svg+xml'])
    on conflict (id) do nothing;
    execute $p$create policy branding_write on storage.objects for insert to authenticated
      with check (bucket_id = 'branding' and public.has_perm(((storage.foldername(name))[1])::uuid, 'settings.manage'))$p$;
    execute $p$create policy branding_update on storage.objects for update to authenticated
      using (bucket_id = 'branding' and public.has_perm(((storage.foldername(name))[1])::uuid, 'settings.manage'))$p$;
    execute $p$create policy branding_delete on storage.objects for delete to authenticated
      using (bucket_id = 'branding' and public.has_perm(((storage.foldername(name))[1])::uuid, 'settings.manage'))$p$;
  end if;
end $$;

create or replace function public.payment_link_info(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('amount', k.amount, 'status', k.status, 'expires_at', k.expires_at,
           'currency', t.currency, 'decimals', t.currency_decimals, 'business', t.name, 'business_ar', t.name_ar,
           'number', s.number, 'brand_color', t.brand_color,
           'logo_url', case when coalesce((t.settings->>'logo_show')::boolean, true) then t.logo_url end)
    from payment_links k join sales s on s.id = k.sale_id join tenants t on t.id = k.tenant_id
   where k.token = p_token;
$$;

-- ================================================================ outbound events (webhooks)
create table public.event_types (
  key      text primary key,
  name_en  text not null,
  name_ar  text not null,
  sort     integer not null
);
insert into public.event_types values
  ('sale.completed','Sale completed','اكتمال عملية بيع',1),
  ('refund.created','Refund issued','إصدار مرتجع',2),
  ('order.ready','Kitchen order ready','الطلب جاهز في المطبخ',3),
  ('stock.low','Stock reached reorder point','وصول المخزون لحد إعادة الطلب',4),
  ('shift.closed','Shift closed','إقفال وردية',5),
  ('customer.created','New customer','عميل جديد',6),
  ('payment_link.paid','Payment link paid','دفع رابط الدفع',7);
alter table public.event_types enable row level security;
create policy et_read on public.event_types for select to authenticated using (true);
revoke insert, update, delete on public.event_types from anon, authenticated;

create table public.webhook_endpoints (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  name        text not null,
  url         text not null check (url ~ '^https?://[^\s]+$'),
  secret      text not null,                       -- HMAC key; readable only by the dispatcher (service_role)
  events      text[] not null check (cardinality(events) > 0),
  is_active   boolean not null default true,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  last_status integer,
  last_at     timestamptz,
  failures    integer not null default 0           -- consecutive failed deliveries
);
create index on public.webhook_endpoints(tenant_id) where is_active;

create table public.event_outbox (
  id            bigint generated always as identity primary key,
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  endpoint_id   uuid not null references public.webhook_endpoints(id) on delete cascade,
  event         text not null,
  payload       jsonb not null,
  status        text not null default 'pending' check (status in ('pending','sending','sent','dead')),
  attempts      integer not null default 0,
  next_at       timestamptz not null default now(),
  response_code integer,
  last_error    text,
  created_at    timestamptz not null default now(),
  sent_at       timestamptz
);
create index on public.event_outbox(status, next_at);
create index on public.event_outbox(endpoint_id, id desc);

alter table public.webhook_endpoints enable row level security;
alter table public.event_outbox enable row level security;
create policy we_read on public.webhook_endpoints for select to authenticated using (public.has_perm(tenant_id, 'settings.manage'));
create policy eo_read on public.event_outbox for select to authenticated using (public.has_perm(tenant_id, 'settings.manage'));
revoke insert, update, delete on public.webhook_endpoints, public.event_outbox from anon, authenticated;
-- the signing secret never reaches the browser after creation
revoke select on public.webhook_endpoints from authenticated;
grant select (id, tenant_id, name, url, events, is_active, created_at, last_status, last_at, failures) on public.webhook_endpoints to authenticated;

-- queue one delivery per active endpoint subscribed to the event (only when the integrations module is on)
create or replace function public._emit(p_tenant uuid, p_event text, p_data jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not has_feature(p_tenant, 'integrations') then return 0; end if;
  insert into event_outbox(tenant_id, endpoint_id, event, payload)
  select p_tenant, e.id, p_event,
         jsonb_build_object('event', p_event, 'tenant_id', p_tenant, 'occurred_at', now(), 'data', p_data)
    from webhook_endpoints e
   where e.tenant_id = p_tenant and e.is_active and p_event = any(e.events);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public._emit(uuid, text, jsonb) from public, anon, authenticated;

-- sale/refund: fired at commit so the lines and payments are in place
create or replace function public.emit_sale() returns trigger language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not has_feature(new.tenant_id, 'integrations') then return null; end if;
  select jsonb_build_object('id', s.id, 'number', s.number, 'doc_type', s.doc_type, 'branch_id', s.branch_id, 'branch', b.name,
           'created_at', s.created_at, 'currency', t.currency, 'decimals', t.currency_decimals,
           'subtotal', s.subtotal, 'discount_total', s.discount_total, 'tax_total', s.tax_total, 'total', s.total,
           'original_sale_id', s.original_sale_id, 'external_ref', s.external_ref,
           'customer', (select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone) from customers c where c.id = s.customer_id),
           'lines', (select coalesce(jsonb_agg(jsonb_build_object('item_id', l.item_id, 'name', l.name, 'qty', l.qty, 'line_total', l.line_total) order by l.name), '[]')
                       from sale_lines l where l.sale_id = s.id),
           'payments', (select coalesce(jsonb_agg(jsonb_build_object('tender', p.tender, 'amount', p.amount, 'status', p.status)), '[]')
                          from payments p where p.sale_id = s.id))
    into v
    from sales s join branches b on b.id = s.branch_id join tenants t on t.id = s.tenant_id where s.id = new.id;
  perform _emit(new.tenant_id, case when new.doc_type = 'credit_note' then 'refund.created' else 'sale.completed' end, v);
  return null;
end $$;
create constraint trigger sales_emit after insert on public.sales deferrable initially deferred for each row execute function public.emit_sale();

create or replace function public.emit_kitchen_ready() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'ready' and old.status is distinct from 'ready' then
    perform _emit(new.tenant_id, 'order.ready', jsonb_build_object('ticket_id', new.id, 'order_ref', new.order_ref, 'order_type', new.order_type,
      'table_no', new.table_no, 'customer_name', new.customer_name, 'sale_id', new.sale_id, 'branch_id', new.branch_id, 'ready_at', new.ready_at));
  end if;
  return null;
end $$;
create trigger kitchen_emit after update of status on public.kitchen_tickets for each row execute function public.emit_kitchen_ready();

create or replace function public.emit_shift_closed() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.closed_at is not null and old.closed_at is null then
    perform _emit(new.tenant_id, 'shift.closed', jsonb_build_object('shift_id', new.id, 'branch_id', new.branch_id,
      'opened_at', new.opened_at, 'closed_at', new.closed_at, 'opening_float', new.opening_float,
      'expected_cash', new.expected_cash, 'counted_cash', new.counted_cash, 'variance', new.variance,
      'closed_by', (select display_name from memberships m where m.tenant_id = new.tenant_id and m.user_id = new.closed_by)));
  end if;
  return null;
end $$;
create trigger shifts_emit after update of closed_at on public.shifts for each row execute function public.emit_shift_closed();

create or replace function public.emit_customer() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform _emit(new.tenant_id, 'customer.created', jsonb_build_object('id', new.id, 'name', new.name, 'phone', new.phone, 'email', new.email));
  return null;
end $$;
create trigger customers_emit after insert on public.customers for each row execute function public.emit_customer();

-- stock.low: when a movement takes the balance from above the reorder point to at or below it
create or replace function public.emit_stock_low() returns trigger language plpgsql security definer set search_path = public as $$
declare it items%rowtype; v_after numeric;
begin
  if new.qty >= 0 or not has_feature(new.tenant_id, 'integrations') then return null; end if;
  select * into it from items where id = new.item_id;
  if it.reorder_point is null then return null; end if;
  select coalesce(sum(qty), 0) into v_after from stock_movements where item_id = new.item_id and branch_id = new.branch_id;
  if v_after <= it.reorder_point and v_after - new.qty > it.reorder_point then
    perform _emit(new.tenant_id, 'stock.low', jsonb_build_object('item_id', it.id, 'name', it.name, 'name_ar', it.name_ar, 'sku', it.sku,
      'branch_id', new.branch_id, 'on_hand', v_after, 'reorder_point', it.reorder_point, 'unit', it.unit));
  end if;
  return null;
end $$;
create trigger stock_emit after insert on public.stock_movements for each row execute function public.emit_stock_low();

create or replace function public.emit_link_paid() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    perform _emit(new.tenant_id, 'payment_link.paid', jsonb_build_object('token', new.token, 'sale_id', new.sale_id, 'amount', new.amount,
      'sale_number', (select number from sales where id = new.sale_id)));
  end if;
  return null;
end $$;
create trigger payment_links_emit after update of status on public.payment_links for each row execute function public.emit_link_paid();

-- settings: add / change / remove an endpoint; the secret is returned once, on creation
create or replace function public.save_webhook(p_tenant uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := nullif(p->>'id','')::uuid; v_secret text; v_events text[];
begin
  perform _require(p_tenant, 'settings.manage', null, null);
  perform _require_feature(p_tenant, 'integrations');
  select array_agg(e) into v_events from jsonb_array_elements_text(coalesce(p->'events','[]')) e where e in (select key from event_types);
  if coalesce(cardinality(v_events), 0) = 0 then raise exception 'choose at least one event' using errcode = 'ZT422'; end if;
  if coalesce(p->>'url','') !~ '^https?://[^\s]+$' then raise exception 'enter a full URL starting with https://' using errcode = 'ZT422'; end if;
  if v_id is null then
    v_secret := 'whsec_' || encode(gen_random_bytes(24), 'hex');
    insert into webhook_endpoints(tenant_id, name, url, secret, events, created_by)
    values (p_tenant, coalesce(nullif(p->>'name',''), 'Webhook'), p->>'url', v_secret, v_events, auth.uid()) returning id into v_id;
  else
    update webhook_endpoints set name = coalesce(nullif(p->>'name',''), name), url = p->>'url', events = v_events,
           is_active = coalesce((p->>'is_active')::boolean, is_active),
           failures = case when coalesce((p->>'is_active')::boolean, is_active) and not is_active then 0 else failures end
     where id = v_id and tenant_id = p_tenant;
    if not found then raise exception 'not found' using errcode = '42501'; end if;
  end if;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), 'webhook.save', 'webhook_endpoint', v_id, jsonb_build_object('url', p->>'url', 'events', v_events));
  return jsonb_build_object('id', v_id, 'secret', v_secret);
end $$;

create or replace function public.delete_webhook(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from webhook_endpoints where id = p_id;
  if v_tenant is null then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(v_tenant, 'settings.manage', null, null);
  delete from webhook_endpoints where id = p_id;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id) values (v_tenant, auth.uid(), 'webhook.delete', 'webhook_endpoint', p_id);
end $$;

-- "Send test": queues a ping to one endpoint regardless of its event list
create or replace function public.test_webhook(p_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare e webhook_endpoints%rowtype; v bigint;
begin
  select * into e from webhook_endpoints where id = p_id;
  if not found then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(e.tenant_id, 'settings.manage', null, null);
  insert into event_outbox(tenant_id, endpoint_id, event, payload)
  values (e.tenant_id, e.id, 'ping', jsonb_build_object('event', 'ping', 'tenant_id', e.tenant_id, 'occurred_at', now(),
          'data', jsonb_build_object('message', 'Test from Z Trust', 'endpoint', e.name)))
  returning id into v;
  return v;
end $$;

-- dispatcher (service_role only): claim due deliveries, then report each result
create or replace function public.claim_events(p_limit integer default 50) returns table(id bigint, event text, payload jsonb, url text, secret text, attempts integer)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select o.id from event_outbox o
     where (o.status = 'pending' and o.next_at <= now())
        or (o.status = 'sending' and o.next_at <= now() - interval '5 minutes')     -- a dispatcher that died mid-send
     order by o.id for update skip locked limit p_limit)
  update event_outbox o set status = 'sending', attempts = o.attempts + 1, next_at = now()
    from due, webhook_endpoints e
   where o.id = due.id and e.id = o.endpoint_id
  returning o.id, o.event, o.payload, e.url, e.secret, o.attempts;
end $$;

create or replace function public.finish_event(p_id bigint, p_ok boolean, p_code integer, p_error text) returns void
language plpgsql security definer set search_path = public as $$
declare o event_outbox%rowtype;
  -- retry after 1 min, 5 min, 30 min, 2 h, 12 h; then give up
  v_backoff interval[] := array[interval '1 minute', interval '5 minutes', interval '30 minutes', interval '2 hours', interval '12 hours'];
begin
  select * into o from event_outbox where id = p_id for update;
  if not found then return; end if;
  if p_ok then
    update event_outbox set status = 'sent', sent_at = now(), response_code = p_code, last_error = null where id = p_id;
    update webhook_endpoints set last_status = p_code, last_at = now(), failures = 0 where id = o.endpoint_id;
  else
    update event_outbox set status = case when o.attempts >= 6 then 'dead' else 'pending' end,
           next_at = now() + coalesce(v_backoff[o.attempts], interval '12 hours'), response_code = p_code, last_error = left(p_error, 500)
     where id = p_id;
    -- 50 failures in a row: the endpoint is paused so a dead URL does not pile up work
    update webhook_endpoints set last_status = p_code, last_at = now(), failures = failures + 1,
           is_active = case when failures + 1 >= 50 then false else is_active end
     where id = o.endpoint_id;
  end if;
end $$;
revoke execute on function public.claim_events(integer), public.finish_event(bigint, boolean, integer, text) from public, anon, authenticated;
grant execute on function public.claim_events(integer), public.finish_event(bigint, boolean, integer, text) to service_role;
grant execute on function public.save_webhook(uuid, jsonb), public.delete_webhook(uuid), public.test_webhook(uuid) to authenticated;

-- ================================================================ API keys (read-only for now)
create table public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  name         text not null,
  prefix       text not null unique,          -- shown in the list so a key can be recognised
  key_hash     text not null,                 -- sha256 of the full key
  scopes       text[] not null,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
alter table public.api_keys enable row level security;
create policy ak_read on public.api_keys for select to authenticated using (public.has_perm(tenant_id, 'settings.manage'));
revoke insert, update, delete on public.api_keys from anon, authenticated;
revoke select on public.api_keys from authenticated;
grant select (id, tenant_id, name, prefix, scopes, created_at, last_used_at, revoked_at) on public.api_keys to authenticated;

create or replace function public.create_api_key(p_tenant uuid, p_name text, p_scopes text[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_prefix text := 'ztk_' || encode(gen_random_bytes(4), 'hex'); v_key text; v_id uuid; v_scopes text[];
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can create API keys' using errcode = '42501'; end if;
  perform _require_feature(p_tenant, 'integrations');
  select array_agg(distinct s) into v_scopes from unnest(p_scopes) s where s in ('items.read','stock.read','sales.read','customers.read');
  if coalesce(cardinality(v_scopes), 0) = 0 then raise exception 'choose at least one permission' using errcode = 'ZT422'; end if;
  v_key := v_prefix || '_' || encode(gen_random_bytes(24), 'hex');
  insert into api_keys(tenant_id, name, prefix, key_hash, scopes, created_by)
  values (p_tenant, coalesce(nullif(p_name,''), 'API key'), v_prefix, encode(digest(v_key, 'sha256'), 'hex'), v_scopes, auth.uid()) returning id into v_id;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), 'api_key.create', 'api_key', v_id, jsonb_build_object('name', p_name, 'scopes', v_scopes));
  return jsonb_build_object('id', v_id, 'key', v_key);
end $$;

create or replace function public.revoke_api_key(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from api_keys where id = p_id;
  if v_tenant is null or my_role(v_tenant) is distinct from 'owner' then raise exception 'not allowed' using errcode = '42501'; end if;
  update api_keys set revoked_at = now() where id = p_id and revoked_at is null;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id) values (v_tenant, auth.uid(), 'api_key.revoke', 'api_key', p_id);
end $$;

-- the public-api function calls this with the caller's key; every answer is scoped to that key's business
create or replace function public.api_query(p_key text, p_resource text, p jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k api_keys%rowtype; v_limit integer := least(greatest(coalesce((p->>'limit')::int, 100), 1), 500); v jsonb;
  v_from timestamptz := coalesce((p->>'from')::timestamptz, now() - interval '1 day');
  v_to timestamptz := coalesce((p->>'to')::timestamptz, now());
begin
  select * into k from api_keys where key_hash = encode(digest(coalesce(p_key,''), 'sha256'), 'hex') and revoked_at is null;
  if not found then raise exception 'invalid API key' using errcode = '42501'; end if;
  if not has_feature(k.tenant_id, 'integrations') then raise exception 'integrations are switched off for this business' using errcode = '42501'; end if;
  if not (p_resource || '.read') = any(k.scopes) then raise exception 'this key has no % permission', p_resource || '.read' using errcode = '42501'; end if;
  update api_keys set last_used_at = now() where id = k.id and (last_used_at is null or last_used_at < now() - interval '1 minute');

  if p_resource = 'items' then
    select coalesce(jsonb_agg(x order by x->>'name'), '[]') into v from (
      select jsonb_build_object('id', i.id, 'name', i.name, 'name_ar', i.name_ar, 'sku', i.sku, 'barcode', i.barcode, 'price', i.price,
             'item_type', i.item_type, 'unit', i.unit, 'is_active', i.is_active, 'category', c.name) x
        from items i left join categories c on c.id = i.category_id
       where i.tenant_id = k.tenant_id order by i.name limit v_limit) q;
  elsif p_resource = 'stock' then
    select coalesce(jsonb_agg(x), '[]') into v from (
      select jsonb_build_object('item_id', s.item_id, 'name', s.name, 'sku', s.sku, 'branch_id', s.branch_id, 'on_hand', s.on_hand,
             'reorder_point', s.reorder_point, 'unit', s.unit) x
        from (select i.id as item_id, i.name, i.sku, b.id as branch_id, coalesce(sum(m.qty), 0) as on_hand, i.reorder_point, i.unit
                from items i join branches b on b.tenant_id = i.tenant_id
                left join stock_movements m on m.item_id = i.id and m.branch_id = b.id
               where i.tenant_id = k.tenant_id and i.track_stock and i.item_type <> 'recipe'
               group by i.id, b.id order by i.name limit v_limit) s) q;
  elsif p_resource = 'sales' then
    select coalesce(jsonb_agg(x order by x->>'created_at'), '[]') into v from (
      select jsonb_build_object('id', s.id, 'number', s.number, 'doc_type', s.doc_type, 'branch_id', s.branch_id, 'created_at', s.created_at,
             'status', s.status, 'subtotal', s.subtotal, 'discount_total', s.discount_total, 'tax_total', s.tax_total, 'total', s.total,
             'customer_id', s.customer_id, 'external_ref', s.external_ref,
             'lines', (select coalesce(jsonb_agg(jsonb_build_object('item_id', l.item_id, 'name', l.name, 'qty', l.qty, 'line_total', l.line_total)), '[]')
                         from sale_lines l where l.sale_id = s.id)) x
        from sales s where s.tenant_id = k.tenant_id and s.created_at >= v_from and s.created_at < v_to
       order by s.created_at limit v_limit) q;
  elsif p_resource = 'customers' then
    select coalesce(jsonb_agg(x order by x->>'name'), '[]') into v from (
      select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'email', c.email, 'created_at', c.created_at) x
        from customers c where c.tenant_id = k.tenant_id order by c.name limit v_limit) q;
  else
    raise exception 'unknown resource %', p_resource using errcode = 'ZT422';
  end if;
  return jsonb_build_object('data', v, 'currency', (select currency from tenants where id = k.tenant_id),
                            'decimals', (select currency_decimals from tenants where id = k.tenant_id));
end $$;
grant execute on function public.create_api_key(uuid, text, text[]), public.revoke_api_key(uuid) to authenticated;
grant execute on function public.api_query(text, text, jsonb) to anon, authenticated, service_role;

-- ===== 20261118000011_tender_values.sql
-- New tenders used by phases B–D. Enum values must be committed before any function uses them, so they live in their own migration.
alter type public.tender_type add value if not exists 'loyalty';   -- points redeemed
alter type public.tender_type add value if not exists 'package';   -- a prepaid session from a customer package
alter type public.tender_type add value if not exists 'deposit';   -- a deposit taken earlier on a job card or pre-order

-- ===== 20261118000012_retail_food_modules.sql
-- Z Trust · phase B: modifiers, variants, batches & expiry (FEFO), weighed items, promotions & bundles
-- plus: modules a business type can never use are hidden (a fashion shop never sees the kitchen)

-- ================================================================ module availability per business type
alter table public.feature_modules add column universal boolean not null default false;
update public.feature_modules set universal = true
 where key in ('credit','purchasing','integrations','promotions','loyalty','preorders','consignment','quotations');

-- a module is offered to a business when it is universal or listed in its business type
create or replace function public.module_allowed(p_profile text, p_key text) returns boolean
language sql stable set search_path = public as $$
  select coalesce((select universal from feature_modules where key = p_key), false)
      or exists (select 1 from business_profiles where key = p_profile and modules ? p_key);
$$;
grant execute on function public.module_allowed(text, text) to anon, authenticated;

create or replace function public.set_feature(p_tenant uuid, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m feature_modules%rowtype; v_features jsonb; v_profile text;
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can switch modules' using errcode = '42501'; end if;
  select * into m from feature_modules where key = p_key;
  if not found then raise exception 'unknown module %', p_key using errcode = 'ZT422'; end if;
  select business_profile into v_profile from tenants where id = p_tenant;
  if p_on and not m.built then raise exception '% is coming soon', m.name_en using errcode = 'ZT422'; end if;
  if p_on and not module_allowed(v_profile, p_key) then
    raise exception '% is not available for this business type', m.name_en using errcode = 'ZT422'; end if;
  perform set_config('zt.trusted', 'on', true);
  update tenants set features = features || jsonb_build_object(p_key, p_on) where id = p_tenant returning features into v_features;
  perform set_config('zt.trusted', 'off', true);
  if p_key = 'kitchen' and p_on then
    insert into kitchen_stations(tenant_id, branch_id, name, name_ar, is_default)
    select p_tenant, b.id, 'Kitchen', 'المطبخ', true from branches b
     where b.tenant_id = p_tenant and not exists (select 1 from kitchen_stations k where k.branch_id = b.id);
  end if;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), case when p_on then 'feature.on' else 'feature.off' end, 'tenant', p_tenant, jsonb_build_object('module', p_key));
  return v_features;
end $$;

-- ================================================================ items: new kinds and fields
alter table public.items drop constraint if exists items_item_type_check;
alter table public.items add constraint items_item_type_check check (item_type in ('standard','ingredient','recipe','service','package'));
alter table public.items
  add column parent_id      uuid references public.items(id) on delete cascade,   -- variant → its template
  add column is_template    boolean not null default false,                         -- a variant group, never sold itself
  add column variant_attrs  jsonb,                                                  -- {"Size":"M","Colour":"Black"}
  add column sold_by_weight boolean not null default false,
  add column plu            text,                                                   -- scale code (digits)
  add column track_expiry   boolean not null default false,
  add column commission_pct numeric(5,2) check (commission_pct between 0 and 100),
  add column duration_min   integer check (duration_min between 5 and 720);         -- services
create unique index items_plu_uq on public.items(tenant_id, plu) where plu is not null;
create index on public.items(parent_id) where parent_id is not null;

create or replace function public.normalize_item_type() returns trigger language plpgsql as $$
begin
  if new.item_type in ('recipe','service','package') or new.is_template then new.track_stock := false; end if;
  if new.item_type = 'ingredient' then new.track_stock := true; end if;
  if new.item_type = 'service' and new.duration_min is null then new.duration_min := 30; end if;
  return new;
end $$;
drop trigger if exists items_type_guard on public.items;
create trigger items_type_guard before insert or update of item_type, track_stock, is_template on public.items
  for each row execute function public.normalize_item_type();

-- inventory and stock views leave templates out
create or replace view public.v_inventory with (security_invoker = true) as
select i.tenant_id, b.id as branch_id, i.id as item_id, i.name, i.name_ar, i.sku, i.barcode, i.item_type, i.unit, i.cost, i.reorder_point, i.category_id,
       coalesce(sum(m.qty), 0) as on_hand,
       (coalesce(sum(m.qty), 0) * i.cost)::bigint as value,
       max(m.created_at) as last_movement,
       coalesce(sum(-m.qty) filter (where m.reason = 'sale' and m.created_at > now() - interval '30 days'), 0) as used_30d,
       i.parent_id, i.variant_attrs, i.track_expiry
  from public.items i
  join public.branches b on b.tenant_id = i.tenant_id
  left join public.stock_movements m on m.item_id = i.id and m.branch_id = b.id
 where i.track_stock and i.item_type not in ('recipe','service','package') and not i.is_template
 group by i.id, b.id;
grant select on public.v_inventory to authenticated;

-- variants: create the size × colour matrix under a template in one call
-- p = { template_id, attrs: {"Size":["S","M"],"Colour":["Black"]}, price?, cost?, sku_prefix? }
create or replace function public.generate_variants(p jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare tpl items%rowtype; combo jsonb; n int := 0; k text; v_name text; v_sku text; v_id uuid;
begin
  select * into tpl from items where id = (p->>'template_id')::uuid;
  if not found then raise exception 'item not found'; end if;
  perform _require(tpl.tenant_id, 'catalog.manage', null, null);
  perform _require_feature(tpl.tenant_id, 'variants');
  update items set is_template = true where id = tpl.id;
  -- every combination of the attribute values
  for combo in
    with recursive a as (select key, value, row_number() over () rn from jsonb_each(coalesce(p->'attrs','{}'))),
    c(rn, obj) as (
      select 0::bigint, '{}'::jsonb
      union all
      select a.rn, c.obj || jsonb_build_object(a.key, v) from c join a on a.rn = c.rn + 1 cross join jsonb_array_elements_text(a.value) v)
    select obj from c where rn = (select count(*) from a) and rn > 0
  loop
    if exists (select 1 from items where parent_id = tpl.id and variant_attrs = combo) then continue; end if;
    select string_agg(value, ' / ' order by key) into v_name from jsonb_each_text(combo);
    select string_agg(upper(left(regexp_replace(value, '\s', '', 'g'), 3)), '-' order by key) into v_sku from jsonb_each_text(combo);
    insert into items(tenant_id, category_id, name, name_ar, sku, price, cost, tax_rate, track_stock, image_url, parent_id, variant_attrs,
                      item_type, reorder_point, track_expiry, commission_pct)
    values (tpl.tenant_id, tpl.category_id, tpl.name || ' · ' || v_name, case when tpl.name_ar is not null then tpl.name_ar || ' · ' || v_name end,
            case when coalesce(p->>'sku_prefix', tpl.sku) is not null then coalesce(p->>'sku_prefix', tpl.sku) || '-' || v_sku end,
            coalesce((p->>'price')::bigint, tpl.price), coalesce((p->>'cost')::bigint, tpl.cost), tpl.tax_rate, true, tpl.image_url, tpl.id, combo,
            'standard', tpl.reorder_point, tpl.track_expiry, tpl.commission_pct)
    returning id into v_id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ modifiers & add-ons
create table public.modifier_groups (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  name       text not null,
  name_ar    text,
  min_select integer not null default 0 check (min_select >= 0),
  max_select integer not null default 1 check (max_select >= 1),
  sort       integer not null default 0,
  check (max_select >= min_select)
);
create table public.modifier_options (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  group_id   uuid not null references public.modifier_groups(id) on delete cascade,
  name       text not null,
  name_ar    text,
  price      bigint not null default 0 check (price >= 0),        -- added to the item price
  item_id    uuid references public.items(id) on delete set null,  -- optional stock it uses (oat milk, extra cheese)
  qty        numeric(14,4) not null default 0 check (qty >= 0),
  is_active  boolean not null default true,
  sort       integer not null default 0
);
create table public.item_modifier_groups (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  item_id   uuid not null references public.items(id) on delete cascade,
  group_id  uuid not null references public.modifier_groups(id) on delete cascade,
  sort      integer not null default 0,
  primary key (item_id, group_id)
);
alter table public.sale_lines add column modifiers jsonb;          -- [{option_id, name, name_ar, price}]
alter table public.sale_lines add column staff_id uuid;            -- who served (commissions)
alter table public.sale_lines add column promo_id uuid;
alter table public.sale_lines add column promo_discount bigint not null default 0;
alter table public.sale_lines add column customer_package_id uuid;

-- ================================================================ batches & expiry (FEFO)
create table public.stock_batches (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  item_id     uuid not null references public.items(id),
  batch_no    text not null,
  expiry_date date,
  created_at  timestamptz not null default now()
);
create index on public.stock_batches(item_id, branch_id, expiry_date);
create table public.batch_moves (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  batch_id    uuid not null references public.stock_batches(id),
  movement_id bigint not null references public.stock_movements(id),
  qty         numeric(14,3) not null
);
create index on public.batch_moves(batch_id);
create trigger batch_moves_immutable before update or delete on public.batch_moves for each row execute function public.forbid_change();

-- each movement of an expiry-tracked item is split over batches:
--   in  → the batch named in zt.batch_map {item_id: {batch_no, expiry}} (receiving), else the newest batch
--   out → zt.batch_force (write-off of one batch) or first-expiry-first-out over batches with stock
create or replace function public.allocate_batches() returns trigger language plpgsql security definer set search_path = public as $$
declare it items%rowtype; m jsonb; v_batch uuid; v_left numeric; r record; v_take numeric;
begin
  select * into it from items where id = new.item_id;
  if not it.track_expiry then return null; end if;
  if new.qty > 0 then
    m := nullif(current_setting('zt.batch_map', true), '')::jsonb -> new.item_id::text;
    if m is not null and coalesce(m->>'batch_no','') <> '' then
      select id into v_batch from stock_batches where item_id = new.item_id and branch_id = new.branch_id and batch_no = m->>'batch_no'
        and expiry_date is not distinct from nullif(m->>'expiry','')::date;
      if v_batch is null then
        insert into stock_batches(tenant_id, branch_id, item_id, batch_no, expiry_date)
        values (new.tenant_id, new.branch_id, new.item_id, m->>'batch_no', nullif(m->>'expiry','')::date) returning id into v_batch;
      end if;
    else
      select id into v_batch from stock_batches where item_id = new.item_id and branch_id = new.branch_id order by expiry_date desc nulls first, created_at desc limit 1;
      if v_batch is null then
        insert into stock_batches(tenant_id, branch_id, item_id, batch_no, expiry_date)
        values (new.tenant_id, new.branch_id, new.item_id, 'NO-BATCH', null) returning id into v_batch;
      end if;
    end if;
    insert into batch_moves(tenant_id, batch_id, movement_id, qty) values (new.tenant_id, v_batch, new.id, new.qty);
  else
    v_left := -new.qty;
    v_batch := nullif(current_setting('zt.batch_force', true), '')::uuid;
    if v_batch is not null then
      insert into batch_moves(tenant_id, batch_id, movement_id, qty) values (new.tenant_id, v_batch, new.id, new.qty);
      return null;
    end if;
    for r in select b.id, coalesce(sum(bm.qty), 0) as left_qty
               from stock_batches b left join batch_moves bm on bm.batch_id = b.id
              where b.item_id = new.item_id and b.branch_id = new.branch_id
              group by b.id, b.expiry_date, b.created_at having coalesce(sum(bm.qty), 0) > 0
              order by b.expiry_date nulls last, b.created_at loop
      exit when v_left <= 0;
      v_take := least(v_left, r.left_qty);
      insert into batch_moves(tenant_id, batch_id, movement_id, qty) values (new.tenant_id, r.id, new.id, -v_take);
      v_left := v_left - v_take;
    end loop;
  end if;
  return null;
end $$;
create trigger stock_batches_alloc after insert on public.stock_movements for each row execute function public.allocate_batches();

create or replace view public.v_batches with (security_invoker = true) as
select b.id, b.tenant_id, b.branch_id, b.item_id, i.name, i.name_ar, i.unit, i.cost, b.batch_no, b.expiry_date, b.created_at,
       coalesce(sum(bm.qty), 0) as on_hand,
       (b.expiry_date - (now() at time zone br.timezone)::date) as days_left
  from public.stock_batches b join public.items i on i.id = b.item_id join public.branches br on br.id = b.branch_id
  left join public.batch_moves bm on bm.batch_id = b.id
 group by b.id, i.id, br.timezone;
grant select on public.v_batches to authenticated;

-- receiving with batch numbers and expiry dates: p.batches = {item_id: {batch_no, expiry}}
create or replace function public.receive_po_batches(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('zt.batch_map', coalesce(p->'batches', '{}')::text, true);
  return receive_po(p);
end $$;
create or replace function public.receive_stock_batch(p_branch uuid, p_item uuid, p_qty numeric, p_unit_cost bigint, p_note text, p_batch_no text, p_expiry date) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('zt.batch_map', jsonb_build_object(p_item, jsonb_build_object('batch_no', p_batch_no, 'expiry', p_expiry))::text, true);
  perform receive_stock(p_branch, p_item, p_qty, p_unit_cost, p_note);
end $$;
-- write off what is left of one batch (expired, damaged): stock and ledger through adjust_stock
create or replace function public.write_off_batch(p_batch uuid, p_qty numeric, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare b stock_batches%rowtype; v_left numeric;
begin
  select * into b from stock_batches where id = p_batch;
  if not found then raise exception 'batch not found'; end if;
  select coalesce(sum(qty), 0) into v_left from batch_moves where batch_id = p_batch;
  if p_qty <= 0 or p_qty > v_left then raise exception 'you can write off at most %', v_left using errcode = 'ZT422'; end if;
  perform set_config('zt.batch_force', p_batch::text, true);
  perform adjust_stock(b.branch_id, b.item_id, -p_qty, coalesce(nullif(p_reason,''), 'Expired') || ' · ' || b.batch_no);
  perform set_config('zt.batch_force', '', true);
end $$;

-- ================================================================ promotions & bundles
create table public.promotions (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  name        text not null,
  name_ar     text,
  kind        text not null check (kind in ('percent','amount','bxgy','bundle')),
  -- percent: {percent}; amount: {amount, min_amount}; bxgy: {buy, get, percent}; bundle: {price, components:[{item_id, qty}]}
  params      jsonb not null default '{}',
  item_ids    uuid[],                 -- scope (percent, amount, bxgy); both null = everything
  category_ids uuid[],
  min_qty     numeric(14,3) not null default 0,
  coupon_code text,                   -- when set, applies only with this code
  starts_on   date,
  ends_on     date,
  weekdays    integer[],              -- ISO 1 = Monday … 7 = Sunday; null = every day
  time_from   time,
  time_to     time,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index on public.promotions(tenant_id) where is_active;

-- The promotion engine. lines: [{idx, item_id, qty, gross}] (gross = qty × price incl. add-ons, before manual discounts).
-- Returns [{idx, promo_id, discount}]: per line the single best promotion (promotions do not stack on one line).
-- The POS runs the same rules (app/src/lib/promotions.ts); the server caps what the POS claims at this result.
create or replace function public.promo_allowance(p_tenant uuid, p_at timestamptz, p_lines jsonb, p_coupon text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
end $$;
grant execute on function public.promo_allowance(uuid, timestamptz, jsonb, text) to authenticated;

-- ================================================================ RLS for the new tables
alter table public.modifier_groups enable row level security;
alter table public.modifier_options enable row level security;
alter table public.item_modifier_groups enable row level security;
alter table public.stock_batches enable row level security;
alter table public.batch_moves enable row level security;
alter table public.promotions enable row level security;
create policy mg_read on public.modifier_groups for select to authenticated using (public.is_member(tenant_id));
create policy mg_write on public.modifier_groups for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy mo_read on public.modifier_options for select to authenticated using (public.is_member(tenant_id));
create policy mo_write on public.modifier_options for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy img_read on public.item_modifier_groups for select to authenticated using (public.is_member(tenant_id));
create policy img_write on public.item_modifier_groups for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy sb_read on public.stock_batches for select to authenticated using (public.has_perm(tenant_id, 'inventory.view') or public.has_perm(tenant_id, 'catalog.manage') or public.has_perm(tenant_id, 'inventory.receive'));
create policy bm_read on public.batch_moves for select to authenticated using (public.has_perm(tenant_id, 'inventory.view') or public.has_perm(tenant_id, 'catalog.manage'));
create policy pr_read on public.promotions for select to authenticated using (public.is_member(tenant_id));
create policy pr_write on public.promotions for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
revoke insert, update, delete on public.stock_batches, public.batch_moves from authenticated;

-- writes to module tables need the module switched on
create or replace function public.module_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _require_feature(new.tenant_id, tg_argv[0]); return new; end $$;
create trigger modifier_groups_gate before insert on public.modifier_groups for each row execute function public.module_gate('modifiers');
create trigger promotions_gate before insert on public.promotions for each row execute function public.module_gate('promotions');

grant execute on function public.generate_variants(jsonb), public.receive_po_batches(jsonb),
  public.receive_stock_batch(uuid, uuid, numeric, bigint, text, text, date), public.write_off_batch(uuid, numeric, text) to authenticated;
revoke execute on function public.allocate_batches(), public.module_gate() from public, anon, authenticated;

-- ===== 20261118000013_services_modules.sql
-- Z Trust · phase C: appointments & calendar (with an online booking page), staff commissions, packages & memberships
create extension if not exists btree_gist with schema extensions;

-- ================================================================ staff who take bookings
alter table public.memberships
  add column bookable       boolean not null default false,
  add column commission_pct numeric(5,2) check (commission_pct between 0 and 100),
  add column color          text;

create table public.staff_hours (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  branch_id  uuid not null references public.branches(id) on delete cascade,
  user_id    uuid not null,
  weekday    integer not null check (weekday between 1 and 7),      -- ISO: 1 Monday … 7 Sunday
  start_time time not null,
  end_time   time not null,
  check (end_time > start_time)
);
create index on public.staff_hours(branch_id, user_id, weekday);

-- public booking page: z-trust.app/book/<slug>
alter table public.tenants add column booking_slug text unique check (booking_slug ~ '^[a-z0-9][a-z0-9-]{2,40}$');

-- ================================================================ appointments
create table public.appointments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  customer_id uuid references public.customers(id),
  staff_id    uuid not null,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  status      text not null default 'booked' check (status in ('booked','confirmed','arrived','in_service','completed','no_show','cancelled')),
  source      text not null default 'staff' check (source in ('staff','online')),
  note        text,
  sale_id     uuid references public.sales(id),
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (ends_at > starts_at),
  -- one person cannot be in two appointments at once
  constraint appointments_no_overlap exclude using gist (staff_id with =, tstzrange(starts_at, ends_at) with &&)
    where (status not in ('cancelled','no_show'))
);
create index on public.appointments(branch_id, starts_at);
create table public.appointment_services (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  item_id        uuid not null references public.items(id),
  name           text not null,
  duration_min   integer not null,
  price          bigint not null
);

alter table public.staff_hours enable row level security;
alter table public.appointments enable row level security;
alter table public.appointment_services enable row level security;
create policy sh_read on public.staff_hours for select to authenticated using (public.is_member(tenant_id));
create policy sh_write on public.staff_hours for all to authenticated using (public.has_perm(tenant_id, 'staff.manage')) with check (public.has_perm(tenant_id, 'staff.manage'));
create policy ap_read on public.appointments for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy aps_read on public.appointment_services for select to authenticated using (public.is_member(tenant_id));
revoke insert, update, delete on public.appointments, public.appointment_services from authenticated;

-- p = { id?, branch_id, customer_id?, customer:{name, phone}?, staff_id, starts_at, service_ids:[uuid], note }
create or replace function public.save_appointment(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_tenant uuid; v_id uuid := nullif(p->>'id','')::uuid; v_cust uuid := nullif(p->>'customer_id','')::uuid;
  v_start timestamptz := (p->>'starts_at')::timestamptz; v_min int;
  -- only book_online may create 'online' bookings (it sets this flag); everyone else books as staff
  v_src text := case when current_setting('zt.online_booking', true) = 'on' then 'online' else 'staff' end;
begin
  select tenant_id into v_tenant from branches where id = v_branch;
  if v_src = 'staff' then
    if v_tenant is null or not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
    perform _require(v_tenant, 'sale.create', null, null);
  end if;
  perform _require_feature(v_tenant, 'appointments');
  if not exists (select 1 from memberships where tenant_id = v_tenant and user_id = (p->>'staff_id')::uuid and is_active and bookable) then
    raise exception 'choose a staff member who takes bookings' using errcode = 'ZT422'; end if;
  select sum(duration_min) into v_min from items where tenant_id = v_tenant and item_type = 'service' and id in (select jsonb_array_elements_text(p->'service_ids')::uuid);
  if v_min is null then raise exception 'choose at least one service' using errcode = 'ZT422'; end if;
  if v_cust is null and coalesce(p->'customer'->>'name','') <> '' then
    select id into v_cust from customers where tenant_id = v_tenant and phone = nullif(p->'customer'->>'phone','');
    if v_cust is null then
      insert into customers(tenant_id, name, phone) values (v_tenant, p->'customer'->>'name', nullif(p->'customer'->>'phone','')) returning id into v_cust;
    end if;
  end if;
  begin
    if v_id is null then
      insert into appointments(tenant_id, branch_id, customer_id, staff_id, starts_at, ends_at, note, source, created_by)
      values (v_tenant, v_branch, v_cust, (p->>'staff_id')::uuid, v_start, v_start + make_interval(mins => v_min), nullif(p->>'note',''), v_src, auth.uid())
      returning id into v_id;
    else
      update appointments set customer_id = v_cust, staff_id = (p->>'staff_id')::uuid, starts_at = v_start, ends_at = v_start + make_interval(mins => v_min),
             note = nullif(p->>'note',''), updated_at = now()
       where id = v_id and tenant_id = v_tenant and status in ('booked','confirmed');
      if not found then raise exception 'this appointment can no longer be changed' using errcode = 'ZT422'; end if;
      delete from appointment_services where appointment_id = v_id;
    end if;
  exception when exclusion_violation then
    raise exception 'This staff member is already booked at that time' using errcode = 'ZT422', hint = 'slot_taken';
  end;
  insert into appointment_services(tenant_id, appointment_id, item_id, name, duration_min, price)
  select v_tenant, v_id, i.id, i.name, i.duration_min, i.price from items i
   where i.tenant_id = v_tenant and i.id in (select jsonb_array_elements_text(p->'service_ids')::uuid);
  return v_id;
end $$;

create or replace function public.set_appointment_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare a appointments%rowtype;
begin
  select * into a from appointments where id = p_id for update;
  if not found or not can_see_branch(a.tenant_id, a.branch_id) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(a.tenant_id, 'sale.create', null, null);
  if p_status not in ('confirmed','arrived','in_service','no_show','cancelled','booked') then raise exception 'unknown status' using errcode = 'ZT422'; end if;
  if a.status = 'completed' then raise exception 'this appointment is already paid' using errcode = 'ZT422'; end if;
  update appointments set status = p_status, updated_at = now() where id = p_id;
end $$;

-- free start times for a staff member (or anyone) on a day, in the branch's local time
create or replace function public._free_slots(p_branch uuid, p_minutes int, p_day date, p_staff uuid default null, p_step int default 15)
returns table(staff_id uuid, starts_at timestamptz)
language sql stable security definer set search_path = public as $$
  with b as (select id, tenant_id, timezone from branches where id = p_branch),
  hrs as (
    select h.user_id, h.start_time, h.end_time from staff_hours h join b on b.id = h.branch_id
      join memberships m on m.tenant_id = h.tenant_id and m.user_id = h.user_id and m.is_active and m.bookable
     where h.weekday = extract(isodow from p_day)::int and (p_staff is null or h.user_id = p_staff)),
  cand as (
    select hrs.user_id, (t at time zone b.timezone) as s
      from hrs cross join b
      cross join generate_series(p_day + hrs.start_time, p_day + hrs.end_time - make_interval(mins => p_minutes), make_interval(mins => p_step)) t)
  select c.user_id, c.s from cand c
   where c.s > now()
     and not exists (select 1 from appointments a where a.staff_id = c.user_id and a.status not in ('cancelled','no_show')
                       and tstzrange(a.starts_at, a.ends_at) && tstzrange(c.s, c.s + make_interval(mins => p_minutes)))
   order by c.s, c.user_id;
$$;

-- ---- the public booking page (no sign-in)
create or replace function public.booking_info(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'business', t.name, 'business_ar', t.name_ar, 'logo_url', t.logo_url, 'brand_color', t.brand_color,
    'currency', t.currency, 'decimals', t.currency_decimals,
    'branches', (select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'name_ar', b.name_ar, 'address', b.address, 'timezone', b.timezone) order by b.code) from branches b where b.tenant_id = t.id and b.is_active),
    'services', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'name_ar', i.name_ar, 'duration_min', i.duration_min, 'price', i.price, 'image_url', i.image_url) order by i.name), '[]')
                   from items i where i.tenant_id = t.id and i.item_type = 'service' and i.is_active),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', m.user_id, 'name', m.display_name, 'color', m.color) order by m.display_name), '[]')
                from memberships m where m.tenant_id = t.id and m.is_active and m.bookable))
  from tenants t where t.booking_slug = lower(p_slug) and has_feature(t.id, 'appointments') and coalesce((t.settings->>'booking_online')::boolean, false);
$$;

create or replace function public.booking_slots(p_slug text, p_branch uuid, p_services uuid[], p_day date, p_staff uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tenant uuid; v_min int;
begin
  select id into v_tenant from tenants where booking_slug = lower(p_slug) and has_feature(id, 'appointments') and coalesce((settings->>'booking_online')::boolean, false);
  if v_tenant is null or not exists (select 1 from branches where id = p_branch and tenant_id = v_tenant) then raise exception 'booking page not found' using errcode = '42501'; end if;
  if p_day > current_date + 60 then return '[]'; end if;
  select sum(duration_min) into v_min from items where tenant_id = v_tenant and item_type = 'service' and is_active and id = any(p_services);
  if v_min is null then return '[]'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('staff_id', staff_id, 'starts_at', starts_at)) from _free_slots(p_branch, v_min, p_day, p_staff)), '[]');
end $$;

-- p = { branch_id, service_ids, staff_id, starts_at, name, phone, note }; at most 3 online bookings per phone per day
create or replace function public.book_online(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_id uuid; v_phone text := regexp_replace(coalesce(p->>'phone',''), '[^0-9+]', '', 'g'); v_min int;
begin
  select id into v_tenant from tenants where booking_slug = lower(p_slug) and has_feature(id, 'appointments') and coalesce((settings->>'booking_online')::boolean, false);
  if v_tenant is null then raise exception 'booking page not found' using errcode = '42501'; end if;
  if length(v_phone) < 7 or coalesce(trim(p->>'name'), '') = '' then raise exception 'enter your name and phone number' using errcode = 'ZT422'; end if;
  if (select count(*) from appointments a join customers c on c.id = a.customer_id
       where a.tenant_id = v_tenant and c.phone = v_phone and a.source = 'online' and a.created_at > now() - interval '1 day') >= 3 then
    raise exception 'too many bookings from this number today; please call the shop' using errcode = 'ZT422'; end if;
  select sum(duration_min) into v_min from items where tenant_id = v_tenant and item_type = 'service' and is_active and id in (select jsonb_array_elements_text(p->'service_ids')::uuid);
  if not exists (select 1 from _free_slots((p->>'branch_id')::uuid, coalesce(v_min, 0), ((p->>'starts_at')::timestamptz at time zone (select timezone from branches where id = (p->>'branch_id')::uuid))::date, (p->>'staff_id')::uuid, 5)
                  where starts_at = (p->>'starts_at')::timestamptz) then
    raise exception 'This time was just taken. Please choose another.' using errcode = 'ZT422', hint = 'slot_taken'; end if;
  perform set_config('zt.online_booking', 'on', true);
  v_id := save_appointment(p || jsonb_build_object('customer', jsonb_build_object('name', trim(p->>'name'), 'phone', v_phone)));
  perform set_config('zt.online_booking', 'off', true);
  perform _emit(v_tenant, 'appointment.booked', jsonb_build_object('appointment_id', v_id, 'starts_at', p->>'starts_at', 'name', trim(p->>'name'), 'phone', v_phone, 'source', 'online'));
  return jsonb_build_object('id', v_id, 'starts_at', p->>'starts_at');
end $$;

insert into public.event_types values
  ('appointment.booked','Appointment booked online','حجز موعد أونلاين',8),
  ('job.ready','Job or pre-order ready','الطلب أو التذكرة جاهزة',9)
on conflict do nothing;

-- ================================================================ commissions
-- rate: the item's own %, else the staff member's %; base: the line's net amount (excl. VAT, after discounts)
create or replace view public.v_commissions with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day, l.staff_id, m.display_name as staff_name,
       l.name as item, case when s.doc_type = 'credit_note' then -l.net_amount else l.net_amount end as net,
       coalesce(i.commission_pct, m.commission_pct, 0) as pct,
       round(case when s.doc_type = 'credit_note' then -l.net_amount else l.net_amount end * coalesce(i.commission_pct, m.commission_pct, 0) / 100)::bigint as commission
  from public.sale_lines l join public.sales s on s.id = l.sale_id join public.branches b on b.id = s.branch_id
  left join public.items i on i.id = l.item_id
  left join public.sale_lines o on o.id = l.original_line_id
  left join public.memberships m on m.tenant_id = s.tenant_id and m.user_id = coalesce(l.staff_id, o.staff_id)
 where coalesce(l.staff_id, o.staff_id) is not null;
grant select on public.v_commissions to authenticated;

-- ================================================================ packages & memberships
-- the package is sold as an item (item_type 'package'); its definition says what it covers
create table public.package_defs (
  item_id       uuid primary key references public.items(id) on delete cascade,
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  kind          text not null default 'sessions' check (kind in ('sessions','unlimited')),
  sessions      integer check (sessions between 1 and 1000),
  validity_days integer not null default 365 check (validity_days between 1 and 3660),
  covers        uuid[]                                       -- service items covered; null = any service
);
create table public.customer_packages (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  customer_id    uuid not null references public.customers(id),
  item_id        uuid not null references public.items(id),
  name           text not null,
  kind           text not null,
  sessions_total integer,
  sessions_used  integer not null default 0,
  price_paid     bigint not null,             -- deferred revenue released session by session
  released       bigint not null default 0,
  covers         uuid[],
  sale_id        uuid references public.sales(id),
  starts_on      date not null default current_date,
  expires_on     date not null,
  status         text not null default 'active' check (status in ('active','used','expired','frozen','refunded')),
  created_at     timestamptz not null default now(),
  check (sessions_total is null or sessions_used <= sessions_total)
);
create index on public.customer_packages(customer_id) where status = 'active';
create table public.package_uses (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  package_id  uuid not null references public.customer_packages(id),
  sale_id     uuid references public.sales(id),
  sessions    integer not null,
  amount      bigint not null,
  used_at     timestamptz not null default now(),
  used_by     uuid
);
alter table public.package_defs enable row level security;
alter table public.customer_packages enable row level security;
alter table public.package_uses enable row level security;
create policy pd_read on public.package_defs for select to authenticated using (public.is_member(tenant_id));
create policy pd_write on public.package_defs for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy cp_read on public.customer_packages for select to authenticated using (public.is_member(tenant_id));
create policy pu_read on public.package_uses for select to authenticated using (public.is_member(tenant_id));
revoke insert, update, delete on public.customer_packages, public.package_uses from authenticated;
create trigger package_defs_gate before insert on public.package_defs for each row execute function public.module_gate('memberships');

-- value released per session: the price split evenly, the last session takes the remainder
create or replace function public.package_session_value(p_id uuid, p_sessions int) returns bigint
language sql stable security definer set search_path = public as $$
  select case when c.kind = 'unlimited' then 0
              when c.sessions_used + p_sessions >= c.sessions_total then c.price_paid - c.released
              else (c.price_paid / c.sessions_total) * p_sessions end
    from customer_packages c where c.id = p_id;
$$;

-- unlimited memberships (gym, car wash): record a visit
create or replace function public.use_membership(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c customer_packages%rowtype;
begin
  select * into c from customer_packages where id = p_id for update;
  if not found or not is_member(c.tenant_id) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(c.tenant_id, 'sale.create', null, null);
  if c.status <> 'active' or c.expires_on < current_date then raise exception 'this membership is not active' using errcode = 'ZT422'; end if;
  if c.kind <> 'unlimited' then raise exception 'use sessions at checkout' using errcode = 'ZT422'; end if;
  insert into package_uses(tenant_id, package_id, sessions, amount, used_by) values (c.tenant_id, c.id, 1, 0, auth.uid());
  return jsonb_build_object('visits', (select count(*) from package_uses where package_id = c.id), 'expires_on', c.expires_on);
end $$;

-- expiry: unused value becomes revenue (breakage); run daily (pg_cron) or on demand
create or replace function public.expire_packages(p_tenant uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare c customer_packages%rowtype; n int := 0; v bigint;
begin
  if auth.uid() is not null and not has_perm(p_tenant, 'finance.view') then raise exception 'not allowed' using errcode = '42501'; end if;
  for c in select * from customer_packages where tenant_id = p_tenant and status = 'active' and expires_on < current_date for update loop
    v := c.price_paid - c.released;
    update customer_packages set status = 'expired', released = price_paid where id = c.id;
    if v > 0 then
      perform _post(c.tenant_id, (select branch_id from sales where id = c.sale_id), 'package_expiry', c.id, c.name, jsonb_build_array(
        jsonb_build_object('key','deferred_revenue','debit', v), jsonb_build_object('key','sales','credit', v)));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

insert into public.coa_template(system_key, code, name_en, name_ar, type, section) values
  ('deferred_revenue', '2250', 'Prepaid packages (deferred revenue)', 'باقات مدفوعة مقدماً (إيراد مؤجل)', 'liability', 'current_liability'),
  ('customer_deposits', '2260', 'Customer deposits', 'عربون العملاء', 'liability', 'current_liability'),
  ('exp_loyalty', '6450', 'Loyalty rewards', 'مكافآت الولاء', 'expense', 'operating_expense')
on conflict (system_key) do nothing;
insert into public.accounts(tenant_id, code, name_en, name_ar, type, system_key)
select t.id, c.code, c.name_en, c.name_ar, c.type, c.system_key from public.tenants t cross join public.coa_template c
 where c.system_key in ('deferred_revenue','customer_deposits','exp_loyalty')
on conflict do nothing;

grant execute on function public.save_appointment(jsonb), public.set_appointment_status(uuid, text), public.use_membership(uuid),
  public.expire_packages(uuid), public.package_session_value(uuid, int) to authenticated;
grant execute on function public.booking_info(text), public.booking_slots(text, uuid, uuid[], date, uuid), public.book_online(text, jsonb) to anon, authenticated;
revoke execute on function public._free_slots(uuid, int, date, uuid, int) from public, anon, authenticated;

-- ===== 20261118000014_operations_checkout.sql
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


-- ================================================================ staff profile for bookings and commissions (the owner's own row included)
create or replace function public.set_staff_profile(p_tenant uuid, p_user uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require(p_tenant, 'staff.manage', null, null);
  update memberships set
    bookable = coalesce((p->>'bookable')::boolean, bookable),
    commission_pct = case when p ? 'commission_pct' then nullif(p->>'commission_pct','')::numeric else commission_pct end,
    color = case when p ? 'color' then nullif(p->>'color','') else color end
   where tenant_id = p_tenant and user_id = p_user;
  if not found then raise exception 'not found' using errcode = '42501'; end if;
end $$;
grant execute on function public.set_staff_profile(uuid, uuid, jsonb) to authenticated;

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

-- logos made from photos can be larger than 1 MB as PNG
do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    update storage.buckets set file_size_limit = 3145728 where id = 'branding';
  end if;
end $$;

-- what each promotion gave away, by day (report)
create or replace view public.v_promo_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day, p.id as promo_id, p.name as promotion,
       count(distinct s.id) as invoices, sum(l.qty) as qty, sum(l.promo_discount) as discount, sum(l.net_amount) as net_sales
  from public.sale_lines l join public.sales s on s.id = l.sale_id join public.branches b on b.id = s.branch_id
  join public.promotions p on p.id = l.promo_id
 where s.doc_type = 'invoice' and l.promo_discount > 0
 group by s.tenant_id, s.branch_id, 3, p.id, p.name;
grant select on public.v_promo_sales to authenticated;

-- ===== 20261118000015_more_values.sql
-- Values used by the next migration (enum values must be committed before use)
alter type public.tender_type add value if not exists 'gift_card';   -- redeemed from a gift card code
alter type public.tender_type add value if not exists 'cod';         -- cash on delivery, held by the driver until handed in

-- ===== 20261118000016_growth_modules.sql
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
    v_dist := _distance_m(b.lat, b.lng, p_lat, p_lng);
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

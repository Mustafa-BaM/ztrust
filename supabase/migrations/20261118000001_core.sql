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

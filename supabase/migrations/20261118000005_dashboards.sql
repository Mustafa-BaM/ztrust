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

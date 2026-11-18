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

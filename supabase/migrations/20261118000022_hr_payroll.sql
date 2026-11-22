-- Z Trust · simple HR & payroll
--   employee file with document expiry, leave (annual / sick / emergency / unpaid), salary advances,
--   monthly payroll (basic + allowances + POS commissions + overtime − advances − unpaid leave − deductions),
--   posting to the ledger, payment from the bank, and an end-of-service estimate whose rules are settings.
-- Legal values (leave days, indemnity days, days per month) are tenant settings with defaults, to be confirmed
-- against the labour law that applies to each business before relying on them.

insert into public.coa_template(system_key, code, name_en, name_ar, type, section) values
  ('employee_advances', '1310', 'Employee advances', 'سلف الموظفين', 'asset', 'current_asset')
on conflict (system_key) do nothing;
insert into public.accounts(tenant_id, code, name_en, name_ar, type, system_key)
select t.id, c.code, c.name_en, c.name_ar, c.type, c.system_key from public.tenants t cross join public.coa_template c
 where c.system_key = 'employee_advances' on conflict do nothing;

insert into public.permission_catalog(key, module, name_en, name_ar, limit_kind, sort) values
  ('hr.manage',   'admin', 'Manage employees, documents and leave', 'إدارة الموظفين والوثائق والإجازات', null, 92),
  ('payroll.run', 'admin', 'Prepare, post and pay payroll', 'إعداد الرواتب وترحيلها وصرفها', null, 93)
on conflict (key) do nothing;
update public.role_templates set perms = perms || '{"hr.manage":null}' where key in ('hr','manager');
update public.role_templates set perms = perms || '{"payroll.run":null}' where key in ('hr','accountant');
insert into public.role_permissions(tenant_id, role, permission, limit_value)
select r.tenant_id, r.key, x.perm, null from public.roles r
  join (values ('hr','hr.manage'),('manager','hr.manage'),('hr','payroll.run'),('accountant','payroll.run')) x(role, perm) on x.role = r.key
on conflict do nothing;

create table public.employees (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants(id) on delete cascade,
  branch_id          uuid references public.branches(id),
  user_id            uuid,                    -- the staff login, so POS commissions flow into payroll
  name               text not null,
  name_ar            text,
  job_title          text,
  nationality        text,
  phone              text,
  civil_id           text,
  civil_id_expiry    date,
  passport_no        text,
  passport_expiry    date,
  residency_expiry   date,
  health_card_expiry date,
  license_expiry     date,
  join_date          date not null default current_date,
  end_date           date,
  basic_salary       bigint not null default 0 check (basic_salary >= 0),
  allowances         bigint not null default 0 check (allowances >= 0),
  bank_name          text,
  iban               text,
  annual_leave_days  numeric(5,1),            -- null = the business default
  is_active          boolean not null default true,
  created_at         timestamptz not null default now()
);
create table public.leave_requests (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind        text not null check (kind in ('annual','sick','emergency','unpaid')),
  from_date   date not null,
  to_date     date not null check (to_date >= from_date),
  days        numeric(5,1) not null check (days > 0),
  status      text not null default 'approved' check (status in ('pending','approved','rejected')),
  note        text,
  decided_by  uuid,
  created_at  timestamptz not null default now()
);
create table public.employee_advances (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  employee_id      uuid not null references public.employees(id) on delete cascade,
  amount           bigint not null check (amount > 0),
  monthly_deduction bigint not null check (monthly_deduction > 0),
  recovered        bigint not null default 0,
  given_on         date not null default current_date,
  paid_from        text not null check (paid_from in ('cash_safe','bank','petty_cash')),
  note             text,
  created_by       uuid,
  created_at       timestamptz not null default now()
);
create table public.payroll_runs (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  month       date not null,                 -- first day of the month
  status      text not null default 'draft' check (status in ('draft','posted','paid')),
  gross       bigint not null default 0,
  deductions  bigint not null default 0,
  net         bigint not null default 0,
  created_by  uuid,
  posted_by   uuid,
  posted_at   timestamptz,
  paid_at     timestamptz,
  created_at  timestamptz not null default now(),
  unique (tenant_id, month)
);
create table public.payroll_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  run_id          uuid not null references public.payroll_runs(id) on delete cascade,
  employee_id     uuid not null references public.employees(id),
  basic           bigint not null default 0,
  allowances      bigint not null default 0,
  commission      bigint not null default 0,
  overtime        bigint not null default 0,
  other_additions bigint not null default 0,
  unpaid_days     numeric(5,1) not null default 0,
  absence         bigint not null default 0,
  advance         bigint not null default 0,
  other_deductions bigint not null default 0,
  net             bigint not null default 0,
  note            text,
  unique (run_id, employee_id)
);
alter table public.employees enable row level security;
alter table public.leave_requests enable row level security;
alter table public.employee_advances enable row level security;
alter table public.payroll_runs enable row level security;
alter table public.payroll_lines enable row level security;
create policy emp_read on public.employees for select using (has_perm(tenant_id, 'hr.manage') or has_perm(tenant_id, 'payroll.run'));
create policy emp_write on public.employees for all using (has_perm(tenant_id, 'hr.manage')) with check (has_perm(tenant_id, 'hr.manage'));
create policy lv_read on public.leave_requests for select using (has_perm(tenant_id, 'hr.manage') or has_perm(tenant_id, 'payroll.run'));
create policy lv_write on public.leave_requests for all using (has_perm(tenant_id, 'hr.manage')) with check (has_perm(tenant_id, 'hr.manage'));
create policy adv_read on public.employee_advances for select using (has_perm(tenant_id, 'hr.manage') or has_perm(tenant_id, 'payroll.run'));
create policy pr_read on public.payroll_runs for select using (has_perm(tenant_id, 'payroll.run'));
create policy pl_read on public.payroll_lines for select using (has_perm(tenant_id, 'payroll.run'));
grant select, insert, update, delete on public.employees, public.leave_requests to authenticated;
grant select on public.employee_advances, public.payroll_runs, public.payroll_lines to authenticated;

/** HR rules for this business: defaults, editable in Settings. */
create or replace function public._hr(p_tenant uuid, p_key text) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((settings->>('hr_' || p_key))::numeric, case p_key
    when 'annual_leave_days' then 30 when 'days_per_month' then 26
    when 'indemnity_first_days' then 15 when 'indemnity_first_years' then 5 when 'indemnity_after_days' then 30 when 'indemnity_cap_months' then 18 end)
  from tenants where id = p_tenant;
$$;

/** Per employee: annual leave earned since joining, taken, balance; years of service; end-of-service estimate; next document to expire. */
create or replace function public.hr_overview(p_tenant uuid, p_as_of date default current_date)
returns table(employee_id uuid, name text, years numeric, leave_earned numeric, leave_taken numeric, leave_balance numeric,
              indemnity bigint, next_expiry date, next_expiry_doc text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (has_perm(p_tenant, 'hr.manage') or has_perm(p_tenant, 'payroll.run')) then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select e.id, e.name,
         round(((coalesce(e.end_date, p_as_of) - e.join_date) / 365.0)::numeric, 2),
         round(((coalesce(e.end_date, p_as_of) - e.join_date) / 365.0 * coalesce(e.annual_leave_days, _hr(p_tenant, 'annual_leave_days')))::numeric, 1),
         coalesce((select sum(l.days) from leave_requests l where l.employee_id = e.id and l.kind = 'annual' and l.status = 'approved'), 0),
         round(((coalesce(e.end_date, p_as_of) - e.join_date) / 365.0 * coalesce(e.annual_leave_days, _hr(p_tenant, 'annual_leave_days')))::numeric, 1)
           - coalesce((select sum(l.days) from leave_requests l where l.employee_id = e.id and l.kind = 'annual' and l.status = 'approved'), 0),
         least(
           round((e.basic_salary / _hr(p_tenant, 'days_per_month')) *
             ( least((coalesce(e.end_date, p_as_of) - e.join_date) / 365.0, _hr(p_tenant, 'indemnity_first_years')) * _hr(p_tenant, 'indemnity_first_days')
             + greatest((coalesce(e.end_date, p_as_of) - e.join_date) / 365.0 - _hr(p_tenant, 'indemnity_first_years'), 0) * _hr(p_tenant, 'indemnity_after_days'))),
           e.basic_salary * _hr(p_tenant, 'indemnity_cap_months'))::bigint,
         d.dt, d.doc
    from employees e
    left join lateral (select x.dt, x.doc from (values (e.civil_id_expiry, 'civil_id'), (e.passport_expiry, 'passport'), (e.residency_expiry, 'residency'),
                                                        (e.health_card_expiry, 'health_card'), (e.license_expiry, 'license')) x(dt, doc)
                        where x.dt is not null order by x.dt limit 1) d on true
   where e.tenant_id = p_tenant and e.is_active
   order by e.name;
end $$;
grant execute on function public.hr_overview(uuid, date) to authenticated;

create or replace function public.give_advance(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; v_amt bigint := (p->>'amount')::bigint; v_ded bigint := coalesce((p->>'monthly_deduction')::bigint, (p->>'amount')::bigint);
        v_from text := coalesce(p->>'paid_from','bank'); v_id uuid := gen_random_uuid();
begin
  select * into e from employees where id = (p->>'employee_id')::uuid;
  if not found then raise exception 'employee not found'; end if;
  perform _require(e.tenant_id, 'payroll.run', null, null);
  if v_amt is null or v_amt <= 0 or v_ded <= 0 then raise exception 'amount must be positive' using errcode = 'ZT422'; end if;
  if v_from not in ('cash_safe','bank','petty_cash') then raise exception 'pay the advance from the bank, the safe or petty cash' using errcode = 'ZT422'; end if;
  insert into employee_advances(id, tenant_id, employee_id, amount, monthly_deduction, given_on, paid_from, note, created_by)
  values (v_id, e.tenant_id, e.id, v_amt, least(v_ded, v_amt), coalesce(nullif(p->>'given_on','')::date, current_date), v_from, nullif(p->>'note',''), auth.uid());
  perform _post_ex(e.tenant_id, e.branch_id, 'employee_advance', v_id, 'Advance · ' || e.name, jsonb_build_array(
    jsonb_build_object('key','employee_advances','debit', v_amt), jsonb_build_object('key', v_from, 'credit', v_amt)),
    coalesce(nullif(p->>'given_on','')::date, current_date));
  return v_id;
end $$;
grant execute on function public.give_advance(jsonb) to authenticated;

/** Draft payroll for a month: one line per active employee, commissions from the POS, advance instalments, unpaid leave in the month. */
create or replace function public.prepare_payroll(p_tenant uuid, p_month date) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_m date := date_trunc('month', p_month)::date; v_end date; r payroll_runs%rowtype; e employees%rowtype;
        v_comm bigint; v_adv bigint; v_unpaid numeric; v_abs bigint;
begin
  perform _require(p_tenant, 'payroll.run', null, null);
  v_end := (v_m + interval '1 month - 1 day')::date;
  select * into r from payroll_runs where tenant_id = p_tenant and month = v_m for update;
  if found and r.status <> 'draft' then raise exception 'this month''s payroll is already posted' using errcode = 'ZT422'; end if;
  if not found then
    insert into payroll_runs(tenant_id, month, created_by) values (p_tenant, v_m, auth.uid()) returning * into r;
  end if;
  delete from payroll_lines where run_id = r.id;
  for e in select * from employees where tenant_id = p_tenant and is_active and join_date <= v_end and (end_date is null or end_date >= v_m) loop
    v_comm := case when e.user_id is null then 0 else coalesce((select sum(c.commission) from v_commissions c
                where c.tenant_id = p_tenant and c.staff_id = e.user_id and c.day between v_m and v_end), 0) end;
    v_adv := coalesce((select sum(least(a.monthly_deduction, a.amount - a.recovered)) from employee_advances a where a.employee_id = e.id and a.recovered < a.amount), 0);
    v_unpaid := coalesce((select sum(least(l.to_date, v_end) - greatest(l.from_date, v_m) + 1) from leave_requests l
                 where l.employee_id = e.id and l.kind = 'unpaid' and l.status = 'approved' and l.from_date <= v_end and l.to_date >= v_m), 0);
    v_abs := round(e.basic_salary / _hr(p_tenant, 'days_per_month') * v_unpaid)::bigint;
    insert into payroll_lines(tenant_id, run_id, employee_id, basic, allowances, commission, unpaid_days, absence, advance, net)
    values (p_tenant, r.id, e.id, e.basic_salary, e.allowances, v_comm, v_unpaid, least(v_abs, e.basic_salary),
            least(v_adv, greatest(e.basic_salary + e.allowances + v_comm - least(v_abs, e.basic_salary), 0)), 0);
  end loop;
  perform _payroll_totals(r.id);
  return r.id;
end $$;

create or replace function public._payroll_totals(p_run uuid) returns void
language sql security definer set search_path = public as $$
  update payroll_lines set net = basic + allowances + commission + overtime + other_additions - absence - advance - other_deductions where run_id = p_run;
  update payroll_runs r set gross = x.g, deductions = x.d, net = x.n
    from (select coalesce(sum(basic + allowances + commission + overtime + other_additions), 0) g,
                 coalesce(sum(absence + advance + other_deductions), 0) d, coalesce(sum(net), 0) n from payroll_lines where run_id = p_run) x
   where r.id = p_run;
$$;

/** Edit one line of a draft: overtime, other additions and deductions, note. */
create or replace function public.update_payroll_line(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare l payroll_lines%rowtype; r payroll_runs%rowtype;
begin
  select * into l from payroll_lines where id = (p->>'id')::uuid for update;
  if not found then raise exception 'line not found'; end if;
  select * into r from payroll_runs where id = l.run_id;
  perform _require(r.tenant_id, 'payroll.run', null, null);
  if r.status <> 'draft' then raise exception 'the payroll is already posted' using errcode = 'ZT422'; end if;
  update payroll_lines set overtime = greatest(coalesce((p->>'overtime')::bigint, overtime), 0),
         other_additions = greatest(coalesce((p->>'other_additions')::bigint, other_additions), 0),
         other_deductions = greatest(coalesce((p->>'other_deductions')::bigint, other_deductions), 0),
         advance = greatest(least(coalesce((p->>'advance')::bigint, advance), advance), 0),
         note = coalesce(p->>'note', note) where id = l.id;
  perform _payroll_totals(r.id);
  if exists (select 1 from payroll_lines where run_id = r.id and net < 0) then raise exception 'deductions are larger than the salary' using errcode = 'ZT422'; end if;
end $$;

/** Post: salaries expense (gross − absence − deductions), advances recovered, salaries payable (net). */
create or replace function public.post_payroll(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r payroll_runs%rowtype; v_adv bigint; v_cost bigint; l payroll_lines%rowtype; a employee_advances%rowtype; v_left bigint;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'payroll not found'; end if;
  perform _require(r.tenant_id, 'payroll.run', null, null);
  if r.status <> 'draft' then raise exception 'already posted' using errcode = 'ZT422'; end if;
  perform _payroll_totals(r.id);
  select coalesce(sum(advance), 0), coalesce(sum(basic + allowances + commission + overtime + other_additions - absence - other_deductions), 0)
    into v_adv, v_cost from payroll_lines where run_id = r.id;
  perform _post_ex(r.tenant_id, null, 'payroll', r.id, 'Payroll ' || to_char(r.month, 'YYYY-MM'), jsonb_build_array(
    jsonb_build_object('key','exp_salaries','debit', v_cost),
    jsonb_build_object('key','employee_advances','credit', v_adv),
    jsonb_build_object('key','salaries_payable','credit', v_cost - v_adv)), (r.month + interval '1 month - 1 day')::date);
  -- advance instalments, oldest first
  for l in select * from payroll_lines where run_id = r.id and advance > 0 loop
    v_left := l.advance;
    for a in select * from employee_advances where employee_id = l.employee_id and recovered < amount order by given_on, created_at for update loop
      exit when v_left <= 0;
      update employee_advances set recovered = recovered + least(v_left, amount - recovered) where id = a.id;
      v_left := v_left - least(v_left, a.amount - a.recovered);
    end loop;
  end loop;
  update payroll_runs set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = r.id;
  perform _audit(r.tenant_id, null, 'payroll.post', 'payroll', r.id, r.net, to_char(r.month, 'YYYY-MM'), null);
end $$;

create or replace function public.pay_payroll(p_run uuid, p_from text default 'bank') returns void
language plpgsql security definer set search_path = public as $$
declare r payroll_runs%rowtype;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'payroll not found'; end if;
  perform _require(r.tenant_id, 'payroll.run', null, null);
  if r.status <> 'posted' then raise exception 'post the payroll first' using errcode = 'ZT422'; end if;
  if p_from not in ('bank','cash_safe') then raise exception 'pay salaries from the bank or the safe' using errcode = 'ZT422'; end if;
  perform _post_ex(r.tenant_id, null, 'payroll_payment', r.id, 'Salaries paid ' || to_char(r.month, 'YYYY-MM'), jsonb_build_array(
    jsonb_build_object('key','salaries_payable','debit', r.net), jsonb_build_object('key', p_from, 'credit', r.net)));
  update payroll_runs set status = 'paid', paid_at = now() where id = r.id;
end $$;
grant execute on function public.prepare_payroll(uuid, date), public.update_payroll_line(jsonb), public.post_payroll(uuid), public.pay_payroll(uuid, text) to authenticated;

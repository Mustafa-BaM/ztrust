-- Z Trust · payroll deductions
-- Social insurance per employee (employee share deducted from pay, employer share as a cost; both owed to the authority),
-- a fixed monthly deduction per employee, and total deductions on the payroll report.
-- Rates are per employee (e.g. nationals vs expatriates) and the base is a setting (basic or basic + allowances).

insert into public.coa_template(system_key, code, name_en, name_ar, type, section) values
  ('social_insurance_payable', '2410', 'Social insurance payable', 'تأمينات اجتماعية مستحقة', 'liability', 'current_liability'),
  ('exp_social_insurance',     '6010', 'Social insurance (employer share)', 'التأمينات الاجتماعية (حصة صاحب العمل)', 'expense', 'operating_expense')
on conflict (system_key) do nothing;
insert into public.accounts(tenant_id, code, name_en, name_ar, type, system_key)
select t.id, c.code, c.name_en, c.name_ar, c.type, c.system_key from public.tenants t cross join public.coa_template c
 where c.system_key in ('social_insurance_payable','exp_social_insurance') on conflict do nothing;

alter table public.employees add column if not exists insurance_pct numeric(5,2) not null default 0 check (insurance_pct between 0 and 100);
alter table public.employees add column if not exists insurance_employer_pct numeric(5,2) not null default 0 check (insurance_employer_pct between 0 and 100);
alter table public.employees add column if not exists fixed_deduction bigint not null default 0 check (fixed_deduction >= 0);
alter table public.employees add column if not exists fixed_deduction_label text;
alter table public.payroll_lines add column if not exists insurance bigint not null default 0;
alter table public.payroll_lines add column if not exists insurance_employer bigint not null default 0;
alter table public.payroll_lines add column if not exists fixed_deduction bigint not null default 0;

create or replace function public.prepare_payroll(p_tenant uuid, p_month date) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_m date := date_trunc('month', p_month)::date; v_end date; r payroll_runs%rowtype; e employees%rowtype;
        v_comm bigint; v_adv bigint; v_unpaid numeric; v_abs bigint; v_base bigint;
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
    -- social insurance on the basic salary, or on basic + allowances (setting hr_insurance_base = 'gross')
    v_base := case when coalesce((select settings->>'hr_insurance_base' from tenants where id = p_tenant), 'basic') = 'gross' then e.basic_salary + e.allowances else e.basic_salary end;
    insert into payroll_lines(tenant_id, run_id, employee_id, basic, allowances, commission, unpaid_days, absence, advance, insurance, insurance_employer, fixed_deduction, net)
    values (p_tenant, r.id, e.id, e.basic_salary, e.allowances, v_comm, v_unpaid, least(v_abs, e.basic_salary),
            least(v_adv, greatest(e.basic_salary + e.allowances + v_comm - least(v_abs, e.basic_salary), 0)),
            round(v_base * coalesce(e.insurance_pct, 0) / 100)::bigint, round(v_base * coalesce(e.insurance_employer_pct, 0) / 100)::bigint,
            coalesce(e.fixed_deduction, 0), 0);
  end loop;
  perform _payroll_totals(r.id);
  return r.id;
end $$;

create or replace function public._payroll_totals(p_run uuid) returns void
language sql security definer set search_path = public as $$
  update payroll_lines set net = basic + allowances + commission + overtime + other_additions - absence - advance - other_deductions - insurance - fixed_deduction where run_id = p_run;
  update payroll_runs r set gross = x.g, deductions = x.d, net = x.n
    from (select coalesce(sum(basic + allowances + commission + overtime + other_additions), 0) g,
                 coalesce(sum(absence + advance + other_deductions + insurance + fixed_deduction), 0) d, coalesce(sum(net), 0) n from payroll_lines where run_id = p_run) x
   where r.id = p_run;
$$;

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
         insurance = greatest(coalesce((p->>'insurance')::bigint, insurance), 0),
         fixed_deduction = greatest(coalesce((p->>'fixed_deduction')::bigint, fixed_deduction), 0),
         advance = greatest(least(coalesce((p->>'advance')::bigint, advance), advance), 0),
         note = coalesce(p->>'note', note) where id = l.id;
  perform _payroll_totals(r.id);
  if exists (select 1 from payroll_lines where run_id = r.id and net < 0) then raise exception 'deductions are larger than the salary' using errcode = 'ZT422'; end if;
end $$;

create or replace function public.post_payroll(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r payroll_runs%rowtype; v_adv bigint; v_cost bigint; v_ins bigint; v_emp bigint; l payroll_lines%rowtype; a employee_advances%rowtype; v_left bigint;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'payroll not found'; end if;
  perform _require(r.tenant_id, 'payroll.run', null, null);
  if r.status <> 'draft' then raise exception 'already posted' using errcode = 'ZT422'; end if;
  perform _payroll_totals(r.id);
  -- salary cost = gross − unpaid leave − other deductions − fixed deductions; the employee's insurance share is part of the cost but owed to the authority
  select coalesce(sum(advance), 0), coalesce(sum(basic + allowances + commission + overtime + other_additions - absence - other_deductions - fixed_deduction), 0),
         coalesce(sum(insurance), 0), coalesce(sum(insurance_employer), 0)
    into v_adv, v_cost, v_ins, v_emp from payroll_lines where run_id = r.id;
  perform _post_ex(r.tenant_id, null, 'payroll', r.id, 'Payroll ' || to_char(r.month, 'YYYY-MM'), jsonb_build_array(
    jsonb_build_object('key','exp_salaries','debit', v_cost),
    jsonb_build_object('key','exp_social_insurance','debit', v_emp),
    jsonb_build_object('key','employee_advances','credit', v_adv),
    jsonb_build_object('key','social_insurance_payable','credit', v_ins + v_emp),
    jsonb_build_object('key','salaries_payable','credit', v_cost - v_adv - v_ins)), (r.month + interval '1 month - 1 day')::date);
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

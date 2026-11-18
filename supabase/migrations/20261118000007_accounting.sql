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

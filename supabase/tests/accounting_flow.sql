-- Audit-ready accounting flow test. Run with: supabase/tests/run.sh
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null

create temp table ax(k text primary key, v text);
grant all on ax to authenticated, service_role;
insert into ax values ('O','b0000000-0000-0000-0000-00000000000a'),('A','b0000000-0000-0000-0000-00000000000b'),
  ('M','b0000000-0000-0000-0000-00000000000c'),('C','b0000000-0000-0000-0000-00000000000d');
create or replace function pg_temp.as_user(k text) returns void language sql as
$$ select set_config('request.jwt.claim.sub', (select v from ax where ax.k = $1), false) $$;
create or replace function pg_temp.v(k text) returns text language sql as $$ select v from ax where ax.k = $1 $$;

-- ---------- Saudi retailer (VAT 15% inclusive)
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('O');
insert into ax values ('t', public.create_tenant('{"name":"Riyadh Style","country_code":"SA","pin":"9999"}')::text);
reset role;
insert into ax select 'b', id::text from branches where tenant_id = pg_temp.v('t')::uuid;
insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
select pg_temp.v('t')::uuid, pg_temp.v(x.k)::uuid, x.role, x.name, extensions.crypt(x.pin, extensions.gen_salt('bf'))
  from (values ('A','accountant','Aisha','6666'),('M','manager','Majed','1111'),('C','cashier','Sami','5555')) x(k, role, name, pin);
insert into items(tenant_id, name, price, cost) values (pg_temp.v('t')::uuid, 'Shirt', 11500, 5000);
insert into customers(tenant_id, name, phone, credit_limit) values (pg_temp.v('t')::uuid, 'Hotel Co', '+966500000000', 100000);
insert into suppliers(tenant_id, name) values (pg_temp.v('t')::uuid, 'SEC Utilities');
insert into ax select 'item', id::text from items where tenant_id = pg_temp.v('t')::uuid;
insert into ax select 'cust', id::text from customers where tenant_id = pg_temp.v('t')::uuid;
insert into ax select 'sup', id::text from suppliers where tenant_id = pg_temp.v('t')::uuid;
insert into ax select 'acct_' || system_key, id::text from accounts where tenant_id = pg_temp.v('t')::uuid and system_key is not null;
do $$ begin
  assert (select count(*) from accounts where tenant_id = pg_temp.v('t')::uuid) = 46, 'full chart of accounts (incl. safe, exchanges, purchase variance, employee advances, social insurance)';
  assert not exists (select 1 from accounts where tenant_id = pg_temp.v('t')::uuid and (section is null or not is_system)), 'all classified';
end $$;

-- ---------- sales by the cashier
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id','e0000000-0000-0000-0000-000000000001',
  'lines',jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('item'),'qty',2)),'payments','[{"tender":"cash","amount":23000}]'::jsonb)) is not null;
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id','e0000000-0000-0000-0000-000000000002',
  'customer_id',pg_temp.v('cust'),'lines',jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('item'),'qty',1)),'payments','[{"tender":"on_account","amount":11500}]'::jsonb)) is not null;
do $$ begin
  begin perform * from public.fin_trial_balance(pg_temp.v('t')::uuid, current_date, current_date); raise exception 'cashier must not read statements';
  exception when insufficient_privilege then null; end;
  begin insert into accounts(tenant_id, code, name_en, name_ar, type, section) values (pg_temp.v('t')::uuid,'9999','x','x','expense','operating_expense');
    raise exception 'cashier must not add accounts';
  exception when insufficient_privilege then null; end;
end $$;

-- ---------- accountant: expenses, supplier payment, chart of accounts
select pg_temp.as_user('A');
select public.record_expense(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'account_id',pg_temp.v('acct_exp_rent'),
  'description','Shop rent November','amount',100000,'vat',15000,'paid_from','bank','reference','LEASE-11')) is not null;
select public.record_expense(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'account_id',pg_temp.v('acct_exp_utilities'),
  'description','Electricity bill','amount',20000,'vat',3000,'paid_from','ap','supplier_id',pg_temp.v('sup'))) is not null;
do $$ begin
  begin perform public.record_expense(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'account_id',pg_temp.v('acct_cash'),
      'description','x','amount',1,'paid_from','bank')); raise exception 'cash is not an expense account';
  exception when sqlstate 'ZT422' then null; end;
  begin perform public.pay_supplier(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'supplier_id',pg_temp.v('sup'),'amount',99999,'paid_from','bank'));
    raise exception 'overpayment must fail';
  exception when sqlstate 'ZT422' then null; end;
  perform public.pay_supplier(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'supplier_id',pg_temp.v('sup'),'amount',23000,'paid_from','bank','reference','TRF-9'));
  insert into accounts(tenant_id, code, name_en, name_ar, type, section) values (pg_temp.v('t')::uuid,'6950','Cleaning','النظافة','expense','operating_expense');
  begin update accounts set code = '0000' where id = pg_temp.v('acct_cash')::uuid; raise exception 'system code must not change';
  exception when sqlstate 'P0001' then null; end;
end $$;

-- ---------- manual journal: maker-checker
insert into ax select 'jd', public.save_journal_draft(jsonb_build_object('tenant_id',pg_temp.v('t'),'entry_date',current_date,
  'memo','Opening capital deposited','reference','BANK-STMT-1','lines',jsonb_build_array(
    jsonb_build_object('account_id',pg_temp.v('acct_bank'),'debit',500000),
    jsonb_build_object('account_id',pg_temp.v('acct_opening_balance'),'credit',500000))))::text;
do $$ begin
  begin perform public.save_journal_draft(jsonb_build_object('tenant_id',pg_temp.v('t'),'entry_date',current_date,'memo','bad','lines',jsonb_build_array(
      jsonb_build_object('account_id',pg_temp.v('acct_bank'),'debit',10), jsonb_build_object('account_id',pg_temp.v('acct_equity'),'credit',9))));
    raise exception 'unbalanced draft must fail';
  exception when sqlstate 'ZT422' then null; end;
  begin perform public.post_journal_draft(pg_temp.v('jd')::uuid, null); raise exception 'needs approver';
  exception when sqlstate 'ZT401' then null; end;
  begin perform public.post_journal_draft(pg_temp.v('jd')::uuid, '6666'); raise exception 'preparer cannot post';
  exception when sqlstate 'ZT403' then null; end;
  begin perform public.post_journal_draft(pg_temp.v('jd')::uuid, '1111'); raise exception 'manager limit 1,000 SAR is below 5,000';
  exception when sqlstate 'ZT403' then null; end;
  perform public.post_journal_draft(pg_temp.v('jd')::uuid, '9999');
  assert (select status from journal_drafts where id = pg_temp.v('jd')::uuid) = 'posted', 'posted';
  begin perform public.reverse_entry((select posted_entry_id from journal_drafts where id = pg_temp.v('jd')::uuid), current_date, 'x');
    raise exception 'accountant cannot reverse without finance.post';
  exception when sqlstate 'ZT401' then null; end;
end $$;

-- ---------- owner reverses a second manual journal; operational entries cannot be reversed
select pg_temp.as_user('A');
insert into ax select 'jd2', public.save_journal_draft(jsonb_build_object('tenant_id',pg_temp.v('t'),'entry_date',current_date,'memo','Wrong accrual',
  'lines',jsonb_build_array(jsonb_build_object('account_id',pg_temp.v('acct_exp_general'),'debit',7000),
                            jsonb_build_object('account_id',pg_temp.v('acct_accruals'),'credit',7000))))::text;
select pg_temp.as_user('O');
do $$ declare e bigint; begin
  e := public.post_journal_draft(pg_temp.v('jd2')::uuid, null);
  perform public.reverse_entry(e, current_date, 'Posted to the wrong period');
  begin perform public.reverse_entry(e, current_date, 'again'); raise exception 'double reversal';
  exception when sqlstate 'ZT422' then null; end;
  begin perform public.reverse_entry((select id from journal_entries where tenant_id = pg_temp.v('t')::uuid and source_type = 'sale' limit 1), current_date, 'x');
    raise exception 'sales are corrected by credit notes';
  exception when sqlstate 'ZT422' then null; end;
end $$;

-- ---------- period close and reopen (only finished months can be closed)
select pg_temp.as_user('A');
do $$ declare lm date := (date_trunc('month', current_date) - interval '1 month')::date; begin
  begin perform public.close_period(pg_temp.v('t')::uuid, extract(year from current_date)::int, extract(month from current_date)::int);
    raise exception 'the running month must not be closable';
  exception when sqlstate 'ZT422' then null; end;
  perform public.close_period(pg_temp.v('t')::uuid, extract(year from lm)::int, extract(month from lm)::int);
  begin perform public.save_journal_draft(jsonb_build_object('tenant_id',pg_temp.v('t'),'entry_date',lm + 14,'memo','Late accrual','lines',jsonb_build_array(
      jsonb_build_object('account_id',pg_temp.v('acct_exp_general'),'debit',100), jsonb_build_object('account_id',pg_temp.v('acct_accruals'),'credit',100))));
    raise exception 'closed month must refuse new journals';
  exception when sqlstate 'ZT423' then null; end;
  begin perform public.reopen_period(pg_temp.v('t')::uuid, extract(year from lm)::int, extract(month from lm)::int, 'fix');
    raise exception 'only the owner reopens';
  exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user('O');
select public.reopen_period(pg_temp.v('t')::uuid, extract(year from (current_date - interval '1 month'))::int, extract(month from (current_date - interval '1 month'))::int, 'Late supplier invoice');
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id','e0000000-0000-0000-0000-000000000003',
  'lines',jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('item'),'qty',1)),'payments','[{"tender":"card","amount":11500}]'::jsonb)) is not null;

-- ---------- statements (accountant)
select pg_temp.as_user('A');
do $$ declare v jsonb; a bigint; le bigint; begin
  assert (select sum(closing) from public.fin_trial_balance(pg_temp.v('t')::uuid, date_trunc('month',current_date)::date, current_date)) = 0, 'TB balances';
  assert (select sum(amount) from public.fin_income_statement(pg_temp.v('t')::uuid, date_trunc('month',current_date)::date, current_date) where section = 'revenue') = 40000, 'revenue 400 SAR net';
  assert (select amount from public.fin_income_statement(pg_temp.v('t')::uuid, date_trunc('month',current_date)::date, current_date) where code = '5000') = 20000, 'COGS 4 shirts';
  assert (select amount from public.fin_income_statement(pg_temp.v('t')::uuid, date_trunc('month',current_date)::date, current_date) where code = '6900') = 0, 'reversed accrual nets to zero';
  select sum(amount) filter (where section in ('current_asset','non_current_asset','contra_asset')),
         sum(amount) filter (where section not in ('current_asset','non_current_asset','contra_asset'))
    into a, le from public.fin_balance_sheet(pg_temp.v('t')::uuid, current_date);
  assert a = le, format('balance sheet: assets %s vs liabilities+equity %s', a, le);
  v := public.fin_vat_return(pg_temp.v('t')::uuid, date_trunc('month',current_date)::date, current_date);
  assert (v->>'output_vat')::bigint = 6000 and (v->>'input_vat')::bigint = 18000 and (v->>'net_vat')::bigint = -12000, 'VAT return ' || v::text;
  assert (select total from public.fin_aging(pg_temp.v('t')::uuid, 'ar', current_date)) = 11500, 'AR aging';
  assert (select d0_30 from public.fin_aging(pg_temp.v('t')::uuid, 'ar', current_date)) = 11500, 'AR in 0-30';
  assert not exists (select 1 from public.fin_aging(pg_temp.v('t')::uuid, 'ap', current_date)), 'AP fully paid';
  assert (select balance from public.fin_ledger(pg_temp.v('t')::uuid, pg_temp.v('acct_bank')::uuid, date_trunc('month',current_date)::date, current_date)
          order by entry_no desc nulls last limit 1) = 500000 - 115000 - 23000, 'bank ledger running balance';
  v := public.verify_ledger(pg_temp.v('t')::uuid);
  assert (v->>'hash_mismatches')::int = 0 and (v->>'chain_breaks')::int = 0 and (v->>'numbering_gaps')::int = 0 and (v->>'unbalanced_entries')::int = 0,
         'ledger verifies: ' || v::text;
  assert (select count(*) from audit_log where tenant_id = pg_temp.v('t')::uuid and action in
          ('expense.record','supplier.pay','journal.post','journal.reverse','period.close','period.reopen')) = 8, 'finance actions audited';
  assert (select approved_by from journal_entries where id = (select posted_entry_id from journal_drafts where id = pg_temp.v('jd')::uuid)) = pg_temp.v('O')::uuid, 'approver stored on entry';
end $$;
reset role;

-- ---------- tamper detection: a superuser edits a posted line behind the system's back
alter table journal_lines disable trigger user;
update journal_lines set debit = debit + 1 where id = (select min(l.id) from journal_lines l where l.tenant_id = pg_temp.v('t')::uuid and l.debit > 0);
alter table journal_lines enable trigger user;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('A');
do $$ declare v jsonb; begin
  v := public.verify_ledger(pg_temp.v('t')::uuid);
  assert (v->>'hash_mismatches')::int = 1 and (v->>'unbalanced_entries')::int = 1, 'tampering detected: ' || v::text;
end $$;
reset role;

\o
\echo 'ALL ACCOUNTING TESTS PASSED'

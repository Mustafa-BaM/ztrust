-- P1 / P2 / HR flows: cash in/out + X report, price change approval, cash ceiling, exchange, statements,
-- supplier bill three-way match, return to supplier, price lists, quotation → order → delivery → invoice,
-- serial numbers, debit note, cash flow, bank reconciliation, petty cash, cost centres, payroll.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null

create temp table c(k text primary key, v text);
grant all on c to authenticated, service_role;
create or replace function pg_temp.v(text) returns text language sql as $$ select v from c where k = $1 $$;

-- ---------- owner: Kuwait electronics shop (KWD, 3 decimals)
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', '71111111-1111-1111-1111-111111111111', false);
insert into c values ('t', public.create_tenant('{"name":"Volt Mobiles","country_code":"KW","business_type":"retail","branch_name":"Hawalli","display_name":"Huda","pin":"7777"}')::text);
insert into c select 'b', id::text from branches where tenant_id = pg_temp.v('t')::uuid;
reset role;
insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
select pg_temp.v('t')::uuid, '72222222-2222-2222-2222-222222222222', 'cashier', 'Sami', extensions.crypt('1234', extensions.gen_salt('bf'));
insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
select pg_temp.v('t')::uuid, '73333333-3333-3333-3333-333333333333', 'manager', 'Mona', extensions.crypt('5555', extensions.gen_salt('bf'));
insert into items(tenant_id, name, barcode, price, cost, track_stock) values
  (pg_temp.v('t')::uuid, 'Charger', 'CH1', 5000, 2000, true),
  (pg_temp.v('t')::uuid, 'Cable', 'CB1', 2000, 500, true);
insert into items(tenant_id, name, barcode, price, cost, track_stock, track_serial, warranty_months) values
  (pg_temp.v('t')::uuid, 'Phone X', 'PX1', 150000, 0, true, true, 12);
insert into c select 'charger', id::text from items where barcode = 'CH1' and tenant_id = pg_temp.v('t')::uuid;
insert into c select 'cable', id::text from items where barcode = 'CB1' and tenant_id = pg_temp.v('t')::uuid;
insert into c select 'phone', id::text from items where barcode = 'PX1' and tenant_id = pg_temp.v('t')::uuid;
insert into customers(tenant_id, name, phone, credit_limit) values (pg_temp.v('t')::uuid, 'Gulf Trading', '+96560000000', 1000000);
insert into c select 'cust', id::text from customers where tenant_id = pg_temp.v('t')::uuid;
insert into suppliers(tenant_id, name, payment_terms_days) values (pg_temp.v('t')::uuid, 'Asia Parts', 30);
insert into c select 'sup', id::text from suppliers where tenant_id = pg_temp.v('t')::uuid;
insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost)
select pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, id, 20, 'adjustment', cost from items where tenant_id = pg_temp.v('t')::uuid and not track_serial;

-- ---------- purchase order for phones with serial numbers, then the supplier's bill (three-way match)
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', '71111111-1111-1111-1111-111111111111', false);
insert into c select 'po', public.save_po(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'supplier_id', pg_temp.v('sup'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('phone'), 'qty', 3, 'unit_cost', 100000)))) ::text;
select public.approve_po(pg_temp.v('po')::uuid, null);
do $$ begin
  perform public.receive_po(jsonb_build_object('po_id', pg_temp.v('po'), 'lines', jsonb_build_array(jsonb_build_object(
    'line_id', (select id from purchase_order_lines where po_id = pg_temp.v('po')::uuid), 'qty', 3, 'serials', jsonb_build_array('IMEI-1','IMEI-2')))));
  raise exception 'expected serial count error';
exception when sqlstate 'ZT422' then null; end $$;
select public.receive_po(jsonb_build_object('po_id', pg_temp.v('po'), 'supplier_ref', 'DO-77', 'lines', jsonb_build_array(jsonb_build_object(
  'line_id', (select id from purchase_order_lines where po_id = pg_temp.v('po')::uuid), 'qty', 3, 'serials', jsonb_build_array('imei-1','IMEI-2','IMEI-3')))));
do $$ begin
  assert (select count(*) from item_serials where item_id = pg_temp.v('phone')::uuid and status = 'in_stock') = 3, '3 serials in stock';
end $$;
-- billed at a higher price than ordered: a variance, posted to purchase variance with VAT 0
do $$ declare r jsonb; begin
  r := public.record_supplier_invoice(jsonb_build_object('po_id', pg_temp.v('po'), 'supplier_no', 'INV-9001', 'lines', jsonb_build_array(jsonb_build_object(
    'po_line_id', (select id from purchase_order_lines where po_id = pg_temp.v('po')::uuid), 'qty', 3, 'unit_cost', 101000))));
  assert r->>'match_status' = 'variance' and (r->>'variance')::bigint = 3000, 'bill variance 3.000';
end $$;
do $$ begin
  perform public.record_supplier_invoice(jsonb_build_object('po_id', pg_temp.v('po'), 'supplier_no', 'INV-9001', 'lines', '[]'::jsonb));
  raise exception 'expected duplicate bill error';
exception when sqlstate 'ZT422' then null; end $$;
do $$ begin
  assert (select ap_bal from (select sum(credit - debit) ap_bal from journal_lines l join accounts a on a.id = l.account_id
           where l.tenant_id = pg_temp.v('t')::uuid and a.system_key = 'ap') x) = 303000, 'AP = receipt 300.000 + variance 3.000';
end $$;

-- ---------- supplier statement and return to supplier (one phone by serial)
do $$ declare r jsonb; begin
  r := public.return_to_supplier(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'supplier_id', pg_temp.v('sup'),
    'reason', 'Dead on arrival', 'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('phone'), 'qty', 1, 'unit_cost', 101000, 'serials', jsonb_build_array('IMEI-3')))));
  assert (r->>'total')::bigint = 101000, 'return value';
  r := public.party_statement(pg_temp.v('t')::uuid, 'ap', pg_temp.v('sup')::uuid, current_date - 30, current_date);
  assert (r->>'closing')::bigint = 202000, 'supplier statement closing 202.000';
  assert jsonb_array_length(r->'rows') = 3, 'receipt, bill, return';
  assert (select status from item_serials where serial = 'IMEI-3') = 'returned', 'serial returned to supplier';
end $$;

-- ---------- cashier shift: cash in/out, price change needs a PIN, cash ceiling, serial sale
select set_config('request.jwt.claim.sub', '72222222-2222-2222-2222-222222222222', false);
insert into c select 'shift', public.open_shift(pg_temp.v('b')::uuid, 20000)::text;
do $$ begin
  perform public.cash_move(jsonb_build_object('shift_id', pg_temp.v('shift'), 'kind', 'out', 'amount', 5000, 'counter', 'safe', 'reason', 'Drop to safe'));
  raise exception 'cashier has no cash move permission';
exception when sqlstate 'ZT401' then null; end $$;
select public.cash_move(jsonb_build_object('shift_id', pg_temp.v('shift'), 'kind', 'out', 'amount', 5000, 'counter', 'safe', 'reason', 'Drop to safe', 'approver_pin', '5555'));
select public.cash_move(jsonb_build_object('shift_id', pg_temp.v('shift'), 'kind', 'in', 'amount', 1000, 'counter', 'safe', 'reason', 'Coins', 'approver_pin', '5555'));

do $$ begin
  perform public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'),
    'client_id', 'cccccccc-0000-0000-0000-000000000001',
    'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('charger'), 'qty', 1, 'unit_price', 6000)),
    'payments', jsonb_build_array(jsonb_build_object('tender', 'cash', 'amount', 6000))));
  raise exception 'price change needs approval';
exception when sqlstate 'ZT401' then null; end $$;
select public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'),
  'client_id', 'cccccccc-0000-0000-0000-000000000001', 'approver_pin', '5555',
  'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('charger'), 'qty', 1, 'unit_price', 6000)),
  'payments', jsonb_build_array(jsonb_build_object('tender', 'cash', 'amount', 6000))));

-- serial item: must name an in-stock serial
do $$ begin
  perform public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'),
    'client_id', 'cccccccc-0000-0000-0000-000000000002',
    'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('phone'), 'qty', 1, 'serials', jsonb_build_array('IMEI-3'))),
    'payments', jsonb_build_array(jsonb_build_object('tender', 'card', 'amount', 150000, 'method', 'K-Net'))));
  raise exception 'returned serial cannot be sold';
exception when sqlstate 'ZT422' then null; end $$;
insert into c select 'phonesale', (public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'),
  'client_id', 'cccccccc-0000-0000-0000-000000000002', 'customer_id', pg_temp.v('cust'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('phone'), 'qty', 1, 'serials', jsonb_build_array('IMEI-1'))),
  'payments', jsonb_build_array(jsonb_build_object('tender', 'card', 'amount', 150000, 'method', 'K-Net')))))->>'id';
do $$ begin
  assert (select status from item_serials where serial = 'IMEI-1') = 'sold', 'serial sold';
  assert (select warranty_until from item_serials where serial = 'IMEI-1') = (current_date + interval '12 months')::date, 'warranty 12 months';
end $$;

-- cash ceiling: owner sets 100.000 KWD and block
reset role;
update tenants set settings = settings || '{"cash_limit": 100000, "cash_limit_mode": "block"}' where id = pg_temp.v('t')::uuid;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', '72222222-2222-2222-2222-222222222222', false);
do $$ begin
  perform public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'),
    'client_id', 'cccccccc-0000-0000-0000-000000000003',
    'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('phone'), 'qty', 1, 'serials', jsonb_build_array('IMEI-2'))),
    'payments', jsonb_build_array(jsonb_build_object('tender', 'cash', 'amount', 150000))));
  raise exception 'cash above the ceiling must be refused';
exception when sqlstate 'ZT422' then null; end $$;

-- ---------- exchange: return the charger (6.000), take 2 cables (4.000) → 2.000 cash back
do $$ declare r jsonb; v_sale uuid; begin
  select id into v_sale from sales where client_id = 'cccccccc-0000-0000-0000-000000000001';
  r := public.exchange_sale(jsonb_build_object(
    'refund', jsonb_build_object('sale_id', v_sale, 'client_id', 'cccccccc-0000-0000-0000-0000000000e1', 'reason', 'Wrong model', 'shift_id', pg_temp.v('shift'),
                                 'approver_pin', '5555', 'lines', jsonb_build_array(jsonb_build_object('line_id', (select id from sale_lines where sale_id = v_sale), 'qty', 1))),
    'sale', jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'), 'client_id', 'cccccccc-0000-0000-0000-0000000000e2',
                               'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('cable'), 'qty', 2)),
                               'payments', jsonb_build_array(jsonb_build_object('tender', 'exchange', 'amount', 4000)))));
  assert (r->>'cash_back')::bigint = 2000, 'exchange cash back 2.000';
end $$;
do $$ declare x jsonb; begin
  x := public.shift_summary(pg_temp.v('shift')::uuid);
  -- float 20.000 − out 5.000 + in 1.000 + charger 6.000 − exchange cash back 2.000 = 20.000
  assert (x->>'cash_in')::bigint = 1000 and (x->>'cash_out')::bigint = 7000, 'moves in X report';
  assert (x->'methods'->>'K-Net')::bigint = 150000, 'card network in X report';
end $$;
reset role;
do $$ begin
  assert public._expected_cash(pg_temp.v('shift')::uuid) = 20000, 'expected cash 20.000';
  assert (select coalesce(sum(debit - credit), 0) from journal_lines l join accounts a on a.id = l.account_id
           where l.tenant_id = pg_temp.v('t')::uuid and a.system_key = 'exchange_clearing') = 0, 'exchange clearing nets to zero';
end $$;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', '72222222-2222-2222-2222-222222222222', false);
select public.close_shift(pg_temp.v('shift')::uuid, 20000);

-- ---------- price list, quotation → order → delivery note → invoice on account
select set_config('request.jwt.claim.sub', '71111111-1111-1111-1111-111111111111', false);
insert into c select 'pl', public.save_price_list(jsonb_build_object('tenant_id', pg_temp.v('t'), 'name', 'Wholesale', 'discount_pct', 10,
  'items', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('charger'), 'price', 4000))))::text;
select public.set_customer_price_list(pg_temp.v('cust')::uuid, pg_temp.v('pl')::uuid);
do $$ declare q jsonb; o jsonb; d jsonb; s jsonb; begin
  q := public.save_sales_doc(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'kind', 'quotation', 'customer_id', pg_temp.v('cust'),
        'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('charger'), 'qty', 10), jsonb_build_object('item_id', pg_temp.v('cable'), 'qty', 5))));
  assert (q->>'total')::bigint = 49000, 'quotation priced from the list: 10×4.000 + 5×1.800';
  o := public.advance_sales_doc((q->>'id')::uuid, 'to_order');
  d := public.advance_sales_doc((o->>'id')::uuid, 'to_delivery');
  s := public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'client_id', 'cccccccc-0000-0000-0000-000000000010',
        'customer_id', pg_temp.v('cust'), 'sales_doc_id', d->>'id',
        'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('charger'), 'qty', 10), jsonb_build_object('item_id', pg_temp.v('cable'), 'qty', 5)),
        'payments', jsonb_build_array(jsonb_build_object('tender', 'on_account', 'amount', 49000))));
  assert (s->>'total')::bigint = 49000, 'invoice at list prices, no approval';
  assert (select status from sales_docs where id = (d->>'id')::uuid) = 'invoiced', 'delivery note invoiced';
  assert (select status from sales_docs where id = (o->>'id')::uuid) = 'invoiced', 'order invoiced';
  assert (select status from sales_docs where id = (q->>'id')::uuid) = 'accepted', 'quotation accepted';
end $$;

-- ---------- debit note and customer statement
do $$ declare r jsonb; begin
  perform public.customer_debit_note(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'customer_id', pg_temp.v('cust'),
    'amount', 1500, 'reason', 'Delivery charge'));
  r := public.party_statement(pg_temp.v('t')::uuid, 'ar', pg_temp.v('cust')::uuid, current_date - 30, current_date);
  assert (r->>'closing')::bigint = 50500, 'customer owes 49.000 + 1.500';
  assert (r->>'closing')::bigint = public.customer_balance(pg_temp.v('cust')::uuid), 'statement = customer balance';
end $$;

-- ---------- cost centre, petty cash, bank reconciliation, cash flow
insert into cost_centers(tenant_id, code, name, branch_id) values (pg_temp.v('t')::uuid, 'HW', 'Hawalli shop', pg_temp.v('b')::uuid);
select public.petty_topup(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'amount', 30000, 'from', 'bank'));
select public.record_expense(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'amount', 2500, 'paid_from', 'petty_cash',
  'description', 'Cleaning', 'account_id', (select id from accounts where tenant_id = pg_temp.v('t')::uuid and system_key = 'exp_general')));
do $$ declare r jsonb; begin
  assert (select cost_center_id from journal_lines l join accounts a on a.id = l.account_id where l.tenant_id = pg_temp.v('t')::uuid and a.system_key = 'exp_general')
         = (select id from cost_centers where code = 'HW' and tenant_id = pg_temp.v('t')::uuid), 'expense tagged with the branch cost centre';
  assert (select sum(amount) from public.fin_income_statement_cc(pg_temp.v('t')::uuid, current_date, current_date, (select id from cost_centers where code = 'HW' and tenant_id = pg_temp.v('t')::uuid))
          where section = 'operating_expense') = 2500, 'cost centre P&L';
  r := public.import_bank_lines(pg_temp.v('t')::uuid, (select id from accounts where tenant_id = pg_temp.v('t')::uuid and system_key = 'bank'),
        jsonb_build_array(jsonb_build_object('date', current_date, 'description', 'Transfer to petty', 'amount', -30000),
                          jsonb_build_object('date', current_date, 'description', 'Bank charge', 'amount', -250)));
  assert (r->>'matched')::int = 1, 'one statement line matched';
  r := public.bank_reconciliation(pg_temp.v('t')::uuid, (select id from accounts where tenant_id = pg_temp.v('t')::uuid and system_key = 'bank'), current_date);
  assert jsonb_array_length(r->'unmatched_statement') = 1, 'bank charge still to book';
  r := public.fin_cash_flow(pg_temp.v('t')::uuid, current_date, current_date);
  assert abs((r->>'opening')::bigint + (select coalesce(sum((x->>'amount')::bigint), 0) from jsonb_array_elements(r->'rows') x) - (r->>'closing')::bigint) <= 5,
         'cash flow explains the change in cash (rounding ≤ 5 fils)';
end $$;

-- ---------- HR & payroll: commission from the POS, an advance, unpaid leave
reset role;
update memberships set commission_pct = 5 where user_id = '72222222-2222-2222-2222-222222222222';
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', '71111111-1111-1111-1111-111111111111', false);
insert into employees(tenant_id, branch_id, user_id, name, join_date, basic_salary, allowances, civil_id_expiry)
values (pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, '72222222-2222-2222-2222-222222222222', 'Sami', current_date - 400, 260000, 40000, current_date + 20);
insert into c select 'emp', id::text from employees where name = 'Sami';
insert into leave_requests(tenant_id, employee_id, kind, from_date, to_date, days)
values (pg_temp.v('t')::uuid, pg_temp.v('emp')::uuid, 'unpaid', date_trunc('month', current_date)::date, date_trunc('month', current_date)::date + 1, 2);
select public.give_advance(jsonb_build_object('employee_id', pg_temp.v('emp'), 'amount', 60000, 'monthly_deduction', 20000, 'paid_from', 'bank'));
insert into c select 'run', public.prepare_payroll(pg_temp.v('t')::uuid, current_date)::text;
do $$ declare l payroll_lines%rowtype; o record; begin
  select * into l from payroll_lines where run_id = pg_temp.v('run')::uuid;
  assert l.absence = 20000, 'two unpaid days of 260.000 / 26 = 20.000';
  assert l.advance = 20000, 'advance instalment 20.000';
  assert l.net = 260000 + 40000 + l.commission - 20000 - 20000, 'net pay';
  select * into o from public.hr_overview(pg_temp.v('t')::uuid);
  assert o.next_expiry_doc = 'civil_id', 'next document to expire';
  assert o.indemnity > 0, 'end-of-service estimate';
end $$;
select public.update_payroll_line(jsonb_build_object('id', (select id from payroll_lines where run_id = pg_temp.v('run')::uuid), 'overtime', 15000));
select public.post_payroll(pg_temp.v('run')::uuid);
select public.pay_payroll(pg_temp.v('run')::uuid, 'bank');
reset role;
do $$ begin
  assert (select recovered from employee_advances where employee_id = pg_temp.v('emp')::uuid) = 20000, 'advance recovered';
  assert (select coalesce(sum(debit - credit), 0) from journal_lines l join accounts a on a.id = l.account_id
           where l.tenant_id = pg_temp.v('t')::uuid and a.system_key = 'salaries_payable') = 0, 'salaries paid in full';
  assert (select coalesce(sum(debit - credit), 0) from journal_lines l join accounts a on a.id = l.account_id
           where l.tenant_id = pg_temp.v('t')::uuid and a.system_key = 'employee_advances') = 40000, '40.000 still to recover';
  -- the ledger stays balanced and the chain verifies
  assert (select sum(debit) = sum(credit) from journal_lines where tenant_id = pg_temp.v('t')::uuid), 'ledger balanced';
end $$;

do $$ begin
  assert public._today(pg_temp.v('t')::uuid) = (now() at time zone 'Asia/Kuwait')::date, 'business date follows the Kuwait clock, not UTC';
  assert (select entry_date from journal_entries where tenant_id = pg_temp.v('t')::uuid and source_type = 'payroll_payment') = (now() at time zone 'Asia/Kuwait')::date,
         'entries without a date are dated on the local business day';
end $$;
\o
select 'ALL P1 / P2 / HR ERP TESTS PASSED';

-- End-to-end money flow test. Run with: supabase/tests/run.sh
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null

create temp table ctx(k text primary key, v text);
grant all on ctx to authenticated, service_role;

-- ---------- owner signs up and onboards (Kuwait, café, 3-decimal KWD)
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
insert into ctx values ('tenant', public.create_tenant('{"name":"Faisal Coffee","country_code":"KW","business_type":"food","branch_name":"Salmiya","display_name":"Faisal","pin":"9999"}')::text);
insert into ctx select 'branch', id::text from branches where tenant_id = (select v::uuid from ctx where k='tenant');
reset role;

-- cashier membership + catalog (setup done as admin for brevity)
insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
select v::uuid, '22222222-2222-2222-2222-222222222222', 'cashier', 'Ali', extensions.crypt('1234', extensions.gen_salt('bf')) from ctx where k='tenant';
insert into items(tenant_id, name, name_ar, barcode, price, cost) select v::uuid, 'Latte', 'لاتيه', '111', 1500, 400 from ctx where k='tenant';
insert into items(tenant_id, name, name_ar, barcode, price, cost) select v::uuid, 'Croissant', 'كرواسون', '222', 900, 300 from ctx where k='tenant';
insert into customers(tenant_id, name, phone, credit_limit) select v::uuid, 'Office Co', '+96550000000', 20000 from ctx where k='tenant';
insert into ctx select 'latte', id::text from items where barcode='111' and tenant_id = (select v::uuid from ctx where k='tenant');
insert into ctx select 'croissant', id::text from items where barcode='222' and tenant_id = (select v::uuid from ctx where k='tenant');
insert into ctx select 'customer', id::text from customers where tenant_id = (select v::uuid from ctx where k='tenant') limit 1;

-- ---------- cashier opens shift and sells
set role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
insert into ctx select 'shift', public.open_shift((select v::uuid from ctx where k='branch'), 10000)::text;

-- sale 1: 2 lattes + 1 croissant = 3.900 KWD, split cash 2.000 + card 1.900
insert into ctx select 'sale1', (public.complete_sale(jsonb_build_object(
  'tenant_id',(select v from ctx where k='tenant'),'branch_id',(select v from ctx where k='branch'),
  'shift_id',(select v from ctx where k='shift'),'client_id','aaaaaaaa-0000-0000-0000-000000000001',
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select v from ctx where k='latte'),'qty',2),
                             jsonb_build_object('item_id',(select v from ctx where k='croissant'),'qty',1)),
  'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',2000), jsonb_build_object('tender','card','amount',1900))
)))->>'id';

-- idempotent replay returns the same sale
do $$ declare r jsonb; begin
  r := public.complete_sale(jsonb_build_object(
    'tenant_id',(select v from ctx where k='tenant'),'branch_id',(select v from ctx where k='branch'),
    'client_id','aaaaaaaa-0000-0000-0000-000000000001',
    'lines', jsonb_build_array(jsonb_build_object('item_id',(select v from ctx where k='latte'),'qty',2)),
    'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',3000))));
  assert r->>'id' = (select v from ctx where k='sale1'), 'replay should return original sale';
  assert (r->>'total')::bigint = 3900, 'total should be 3900';
end $$;

-- 20% discount needs approval: no PIN → ZT401
do $$ begin
  perform public.complete_sale(jsonb_build_object(
    'tenant_id',(select v from ctx where k='tenant'),'branch_id',(select v from ctx where k='branch'),
    'client_id','aaaaaaaa-0000-0000-0000-000000000002',
    'lines', jsonb_build_array(jsonb_build_object('item_id',(select v from ctx where k='latte'),'qty',1,'discount',300)),
    'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',1200))));
  raise exception 'expected approval error';
exception when sqlstate 'ZT401' then null; end $$;

-- wrong PIN → ZT403 ; owner PIN → ok and audited with approver
do $$ begin
  perform public.complete_sale(jsonb_build_object(
    'tenant_id',(select v from ctx where k='tenant'),'branch_id',(select v from ctx where k='branch'),
    'client_id','aaaaaaaa-0000-0000-0000-000000000002','approver_pin','0000',
    'lines', jsonb_build_array(jsonb_build_object('item_id',(select v from ctx where k='latte'),'qty',1,'discount',300)),
    'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',1200))));
  raise exception 'expected denial';
exception when sqlstate 'ZT403' then null; end $$;

insert into ctx select 'sale2', (public.complete_sale(jsonb_build_object(
  'tenant_id',(select v from ctx where k='tenant'),'branch_id',(select v from ctx where k='branch'),
  'shift_id',(select v from ctx where k='shift'),'client_id','aaaaaaaa-0000-0000-0000-000000000002','approver_pin','9999',
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select v from ctx where k='latte'),'qty',1,'discount',300)),
  'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',1200)))))->>'id';

-- payments must equal total
do $$ begin
  perform public.complete_sale(jsonb_build_object(
    'tenant_id',(select v from ctx where k='tenant'),'branch_id',(select v from ctx where k='branch'),
    'client_id','aaaaaaaa-0000-0000-0000-000000000003',
    'lines', jsonb_build_array(jsonb_build_object('item_id',(select v from ctx where k='latte'),'qty',1)),
    'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',1000))));
  raise exception 'expected mismatch';
exception when sqlstate 'ZT422' then null; end $$;

-- sale 3: on account 9.000 + payment link 6.000 for a customer (total 15.000 = 10 lattes)
insert into ctx select 'sale3', (public.complete_sale(jsonb_build_object(
  'tenant_id',(select v from ctx where k='tenant'),'branch_id',(select v from ctx where k='branch'),
  'shift_id',(select v from ctx where k='shift'),'client_id','aaaaaaaa-0000-0000-0000-000000000004',
  'customer_id',(select v from ctx where k='customer'),
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select v from ctx where k='latte'),'qty',10)),
  'payments', jsonb_build_array(jsonb_build_object('tender','on_account','amount',9000),
                                jsonb_build_object('tender','payment_link','amount',6000)))))->>'id';

do $$ begin
  assert public.customer_balance((select v::uuid from ctx where k='customer')) = 15000, 'AR should be 15000';
end $$;

-- cashier refund of 3.900 sale exceeds 10.000 limit? no: within limit → allowed without PIN (partial: 1 latte)
insert into ctx select 'cn1', (public.refund_sale(jsonb_build_object(
  'sale_id',(select v from ctx where k='sale1'),'client_id','bbbbbbbb-0000-0000-0000-000000000001',
  'tender','cash','reason','Customer changed mind','shift_id',(select v from ctx where k='shift'),
  'lines', jsonb_build_array(jsonb_build_object('line_id',
     (select id::text from sale_lines where sale_id=(select v::uuid from ctx where k='sale1') and name='Latte'),'qty',1)))))->>'id';

-- cancel needs sale.cancel which cashiers lack → approval required
do $$ begin
  perform public.refund_sale(jsonb_build_object('sale_id',(select v from ctx where k='sale2'),
    'client_id','bbbbbbbb-0000-0000-0000-000000000002','tender','cash','reason','Wrong order','cancel',true));
  raise exception 'expected approval';
exception when sqlstate 'ZT401' then null; end $$;
select public.refund_sale(jsonb_build_object('sale_id',(select v from ctx where k='sale2'),
    'client_id','bbbbbbbb-0000-0000-0000-000000000002','tender','cash','reason','Wrong order','cancel',true,
    'approver_pin','9999','shift_id',(select v from ctx where k='shift'))) is not null;

-- unpaid on-account sale cannot be refunded in cash
do $$ begin
  perform public.refund_sale(jsonb_build_object('sale_id',(select v from ctx where k='sale3'),
    'client_id','bbbbbbbb-0000-0000-0000-000000000003','tender','cash','reason','x','approver_pin','9999'));
  raise exception 'expected block';
exception when sqlstate 'ZT422' then null; end $$;

-- cashier cannot read the ledger or edit a posted sale
do $$ declare n int; begin
  select count(*) into n from journal_entries; assert n = 0, 'cashier must not see journal';
  begin update sales set total = 1 where id = (select v::uuid from ctx where k='sale1'); raise exception 'update should fail';
  exception when insufficient_privilege then null; end;
end $$;

-- collect 9.000 on account by bank transfer
select public.receive_payment((select v::uuid from ctx where k='sale3'), 'bank_transfer', 9000, 'TRX-1',
                              (select v::uuid from ctx where k='shift')) is not null;

-- close shift: float 10.000 + cash 2.000 + 1.200 − refund 1.500 − cancel 1.200 = 10.500 ; count 10.400 → short 0.100
insert into ctx select 'close', public.close_shift((select v::uuid from ctx where k='shift'), 10400)::text;
reset role;

-- gateway webhook pays the link
set role service_role;
select public.mark_payment_link_paid((select token from payment_links where tenant_id = (select v::uuid from ctx where k='tenant') limit 1), 'GW-123') is not null;
reset role;

-- ---------- assertions as owner
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
do $$ declare c jsonb := (select v::jsonb from ctx where k='close'); r record; begin
  assert (c->>'expected_cash')::bigint = 10500, format('expected cash 10500 got %s', c->>'expected_cash');
  assert (c->'shift'->>'variance')::bigint = -100, 'variance -100';
  assert (select sum(debit) - sum(credit) from journal_lines where tenant_id=(select v::uuid from ctx where k='tenant')) = 0, 'ledger must balance';
  assert public.customer_balance((select v::uuid from ctx where k='customer')) = 0, 'AR cleared';
  assert (select qty from v_stock_levels where item_id = (select v::uuid from ctx where k='latte')) = -11, 'latte stock: sold 13, refunded 1, cancelled 1';
  assert (select count(*) from audit_log where tenant_id = (select v::uuid from ctx where k='tenant') and action in ('sale.discount','sale.refund','sale.cancel','shift.variance')) = 4, 'audit rows';
  assert (select approved_by from audit_log where action='sale.cancel') = '11111111-1111-1111-1111-111111111111', 'cancel approver';
  assert (select status from sales where id=(select v::uuid from ctx where k='sale2')) = 'cancelled', 'sale2 cancelled';
  assert (select status from sales where id=(select v::uuid from ctx where k='sale1')) = 'partially_refunded', 'sale1 partial';
  assert (select paid_total from sales where id=(select v::uuid from ctx where k='sale3')) = 15000, 'sale3 paid';
  -- KW has 0 VAT; sales account = 3.900 + 1.200 + 15.000 − 1.500 − 1.200 = 17.400 credit
  assert (select -balance from v_trial_balance where system_key='sales' and tenant_id = (select v::uuid from ctx where k='tenant')) = 17400, 'sales 17400';
  -- hash chain intact
  assert not exists (select 1 from journal_entries e where e.prev_hash is distinct from
     (select hash from journal_entries p where p.tenant_id=e.tenant_id and p.id < e.id order by id desc limit 1)), 'hash chain';
end $$;

-- the posted ledger is immutable even for the owner
reset role;
do $$ begin
  begin delete from journal_lines; raise exception 'delete should fail';
  exception when sqlstate 'P0001' then null; end;
end $$;

-- ---------- VAT-inclusive country (Saudi, 15%)
set role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
insert into ctx values ('sa', public.create_tenant('{"name":"Riyadh Shop","country_code":"SA"}')::text);
reset role;
insert into items(tenant_id, name, price, cost) select v::uuid, 'Shirt', 11500, 5000 from ctx where k='sa';
set role authenticated;
do $$ declare r jsonb; begin
  r := public.complete_sale(jsonb_build_object('tenant_id',(select v from ctx where k='sa'),
    'branch_id',(select id from branches where tenant_id=(select v::uuid from ctx where k='sa')),
    'client_id','cccccccc-0000-0000-0000-000000000001',
    'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Shirt'),'qty',1)),
    'payments', jsonb_build_array(jsonb_build_object('tender','card','amount',11500))));
  assert (r->>'tax_total')::bigint = 1500 and (r->>'subtotal')::bigint = 10000, 'SA inclusive VAT split 10000 + 1500';
  assert r->>'number' = 'B01-INV-000001', 'numbering';
  -- tenant isolation: SA owner cannot see Kuwait data
  assert (select count(*) from sales where tenant_id = (select v::uuid from ctx where k='tenant')) = 0, 'tenant isolation';
end $$;
reset role;

\o
\echo 'ALL POS FLOW TESTS PASSED'

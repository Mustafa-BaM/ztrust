-- Restaurants & retail: quantity tiers, spend thresholds, loyalty tiers, punch cards, coursing, delivery zones,
-- digital receipt (anonymous), checklists, payroll deductions (social insurance + fixed).
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null
create temp table c(k text primary key, v text);
grant all on c to authenticated, service_role, anon;
create or replace function pg_temp.v(text) returns text language sql as $$ select v from c where k = $1 $$;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', '81111111-1111-1111-1111-111111111111', false);
insert into c values ('t', public.create_tenant('{"name":"Bait Burger","country_code":"KW","business_type":"food","branch_name":"Salmiya","display_name":"Nora","pin":"8888"}')::text);
insert into c select 'b', id::text from branches where tenant_id = pg_temp.v('t')::uuid;
reset role;
update tenants set features = features || '{"own_delivery":true,"kitchen":true,"promotions":true,"loyalty":true}', settings = settings || '{"loyalty_earn": 1}' where id = pg_temp.v('t')::uuid;
insert into items(tenant_id, name, price, cost, course) values (pg_temp.v('t')::uuid, 'Soup', 1000, 300, 1), (pg_temp.v('t')::uuid, 'Burger', 3000, 1200, 2), (pg_temp.v('t')::uuid, 'Coffee', 1000, 200, null);
insert into c select lower(name), id::text from items where tenant_id = pg_temp.v('t')::uuid;
insert into customers(tenant_id, name, phone) values (pg_temp.v('t')::uuid, 'Fahad', '+96550000001');
insert into c select 'cust', id::text from customers where tenant_id = pg_temp.v('t')::uuid;
insert into kitchen_stations(tenant_id, branch_id, name, is_default) values (pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, 'Kitchen', true) on conflict do nothing;

-- promotions: 3+ coffees 20%, spend 10+ get 1.000 off
insert into promotions(tenant_id, name, kind, params, item_ids) values (pg_temp.v('t')::uuid, 'Coffee tiers', 'qty_tier', '{"tiers":[{"qty":3,"percent":20},{"qty":6,"percent":30}]}', array[pg_temp.v('coffee')::uuid]);
do $$ declare r jsonb; begin
  r := public.promo_allowance(pg_temp.v('t')::uuid, now(), jsonb_build_array(jsonb_build_object('idx',1,'item_id',pg_temp.v('coffee'),'qty',3,'gross',3000)));
  assert (r->0->>'discount')::bigint = 600, 'qty tier 20% of 3.000';
  r := public.promo_allowance(pg_temp.v('t')::uuid, now(), jsonb_build_array(jsonb_build_object('idx',1,'item_id',pg_temp.v('coffee'),'qty',2,'gross',2000)));
  assert jsonb_array_length(r) = 0, 'below the first tier';
end $$;
update promotions set is_active = false where tenant_id = pg_temp.v('t')::uuid;
insert into promotions(tenant_id, name, kind, params) values (pg_temp.v('t')::uuid, 'Spend more', 'threshold', '{"tiers":[{"min":5000,"percent":5},{"min":10000,"amount":1500}]}');
do $$ declare r jsonb; begin
  r := public.promo_allowance(pg_temp.v('t')::uuid, now(), jsonb_build_array(jsonb_build_object('idx',1,'item_id',pg_temp.v('burger'),'qty',4,'gross',12000)));
  assert (r->0->>'discount')::bigint = 1500, 'threshold 10.000 → 1.500 off';
end $$;
update promotions set is_active = false where tenant_id = pg_temp.v('t')::uuid;

-- loyalty tier and punch card
insert into loyalty_tiers(tenant_id, name, min_spend, earn_multiplier) values (pg_temp.v('t')::uuid, 'Gold', 0, 2);
insert into punch_programs(tenant_id, name, item_ids, punches_needed, reward_item_id) values (pg_temp.v('t')::uuid, 'Coffee card', array[pg_temp.v('coffee')::uuid], 3, pg_temp.v('coffee')::uuid);
insert into c select 'card', id::text from punch_programs where tenant_id = pg_temp.v('t')::uuid;
insert into delivery_zones(tenant_id, name, fee, min_order) values (pg_temp.v('t')::uuid, 'Salmiya', 500, 4000);
insert into c select 'zone', id::text from delivery_zones where tenant_id = pg_temp.v('t')::uuid;
insert into checklists(tenant_id, name, items) values (pg_temp.v('t')::uuid, 'Opening', array['Lights on','Float counted']);

set role authenticated;
select set_config('request.jwt.claim.sub', '81111111-1111-1111-1111-111111111111', false);
insert into c select 'shift', public.open_shift(pg_temp.v('b')::uuid, 10000)::text;
-- 3 coffees: 3 punches, points ×2 (Gold)
select public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'), 'client_id', 'dddddddd-0000-0000-0000-000000000001',
  'customer_id', pg_temp.v('cust'), 'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('coffee'), 'qty', 3)), 'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',3000))));
do $$ begin
  assert (select punches from public.customer_punches(pg_temp.v('cust')::uuid)) = 3, '3 punches';
  assert public.customer_points(pg_temp.v('cust')::uuid) = 6, 'Gold doubles points: 3 × 2';
end $$;
-- the 4th coffee is free with the card
select public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'), 'client_id', 'dddddddd-0000-0000-0000-000000000002',
  'customer_id', pg_temp.v('cust'), 'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('coffee'), 'qty', 1, 'punch_program_id', pg_temp.v('card'), 'promo_discount', 1000)),
  'payments', '[]'::jsonb));
do $$ begin
  assert (select punches from public.customer_punches(pg_temp.v('cust')::uuid)) = 0, 'card used';
  assert (select total from sales where client_id = 'dddddddd-0000-0000-0000-000000000002') = 0, 'free coffee';
end $$;
do $$ begin
  perform public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'client_id', 'dddddddd-0000-0000-0000-000000000003',
    'customer_id', pg_temp.v('cust'), 'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('coffee'), 'qty', 1, 'punch_program_id', pg_temp.v('card'), 'promo_discount', 1000)), 'payments', '[]'::jsonb));
  raise exception 'no punches left';
exception when sqlstate 'ZT422' then null; end $$;

-- delivery zone: below the minimum is refused; soup + burger + fee, courses held
do $$ begin
  perform public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'client_id', 'dddddddd-0000-0000-0000-000000000004', 'customer_id', pg_temp.v('cust'),
    'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('soup'), 'qty', 1), jsonb_build_object('name', 'Delivery fee', 'qty', 1, 'unit_price', 500)),
    'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',1500)), 'delivery', jsonb_build_object('address', 'Block 1', 'zone_id', pg_temp.v('zone'))));
  raise exception 'minimum order';
exception when sqlstate 'ZT422' then null; end $$;
insert into c select 'del', (public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'shift_id', pg_temp.v('shift'), 'client_id', 'dddddddd-0000-0000-0000-000000000005', 'customer_id', pg_temp.v('cust'),
  'kitchen', jsonb_build_object('order_type', 'dine_in', 'table_no', '4'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('soup'), 'qty', 1), jsonb_build_object('item_id', pg_temp.v('burger'), 'qty', 1), jsonb_build_object('name', 'Delivery fee', 'qty', 1, 'unit_price', 500)),
  'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',4500)), 'delivery', jsonb_build_object('address', 'Block 1', 'zone_id', pg_temp.v('zone')))))->>'number';
do $$ declare v_ref text; begin
  assert (select fee from deliveries d join sales s on s.id = d.sale_id where s.number = pg_temp.v('del') and s.tenant_id = pg_temp.v('t')::uuid) = 500, 'zone fee recorded';
  select k.order_ref into v_ref from kitchen_tickets k where k.tenant_id = pg_temp.v('t')::uuid order by created_at desc limit 1;
  assert (select held from kitchen_ticket_items i join kitchen_tickets k on k.id = i.ticket_id where k.order_ref = v_ref and k.tenant_id = pg_temp.v('t')::uuid and i.name like 'Burger%') = true, 'mains wait';
  assert (select held from kitchen_ticket_items i join kitchen_tickets k on k.id = i.ticket_id where k.order_ref = v_ref and k.tenant_id = pg_temp.v('t')::uuid and i.name like 'Soup%') = false, 'starter goes first';
  assert public.fire_course(pg_temp.v('b')::uuid, v_ref, 2::smallint) = 1, 'mains fired';
end $$;

-- checklist tick
do $$ declare r jsonb; begin
  r := public.tick_checklist((select id from checklists where tenant_id = pg_temp.v('t')::uuid), pg_temp.v('b')::uuid, 0, true);
  r := public.tick_checklist((select id from checklists where tenant_id = pg_temp.v('t')::uuid), pg_temp.v('b')::uuid, 1, true);
  assert r->>'completed_at' is not null, 'checklist complete';
end $$;

-- digital receipt without login
reset role;
insert into c select 'tok', public_token::text from sales where number = pg_temp.v('del') and tenant_id = pg_temp.v('t')::uuid;
set role anon;
do $$ begin assert (public.receipt_public(pg_temp.v('tok')::uuid)->>'total')::bigint = 4500, 'public receipt'; end $$;
reset role;

-- payroll: 10.5% employee + 11.5% employer social insurance, 20.000 fixed deduction
set role authenticated;
select set_config('request.jwt.claim.sub', '81111111-1111-1111-1111-111111111111', false);
insert into employees(tenant_id, name, basic_salary, allowances, insurance_pct, insurance_employer_pct, fixed_deduction, fixed_deduction_label)
values (pg_temp.v('t')::uuid, 'Ali', 400000, 100000, 10.5, 11.5, 20000, 'Housing');
insert into c select 'run', public.prepare_payroll(pg_temp.v('t')::uuid, current_date)::text;
do $$ declare l payroll_lines%rowtype; begin
  select * into l from payroll_lines where run_id = pg_temp.v('run')::uuid;
  assert l.insurance = 42000 and l.insurance_employer = 46000 and l.fixed_deduction = 20000, 'insurance on basic + fixed deduction';
  assert l.net = 500000 - 42000 - 20000, 'net after deductions';
end $$;
select public.post_payroll(pg_temp.v('run')::uuid);
reset role;
do $$ begin
  assert (select sum(credit - debit) from journal_lines l join accounts a on a.id = l.account_id where l.tenant_id = pg_temp.v('t')::uuid and a.system_key = 'social_insurance_payable') = 88000, 'owed to the authority 42.000 + 46.000';
  assert (select sum(debit) = sum(credit) from journal_lines where tenant_id = pg_temp.v('t')::uuid), 'ledger balanced';
end $$;
\o
select 'ALL RESTAURANT, RETAIL AND PAYROLL DEDUCTION TESTS PASSED';

-- Phases B–D: add-ons, variants, batches/FEFO, weighed items, promotions, appointments & online booking, commissions,
-- packages, job cards & deposits, open table orders, loyalty — with the ledger checked at the end.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null
create temp table mx(k text primary key, v text);
grant all on mx to authenticated, anon, service_role;
insert into mx values ('O','a7000000-0000-0000-0000-00000000000a'),('C','a7000000-0000-0000-0000-00000000000b'),('S','a7000000-0000-0000-0000-00000000000c');
create or replace function pg_temp.v(k text) returns text language sql as $$ select v from mx where mx.k = $1 $$;
create or replace function pg_temp.as_user(k text) returns void language sql as $$ select set_config('request.jwt.claim.sub', (select v from mx where mx.k = $1), false) $$;
create or replace function pg_temp.fails(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlstate || ':' || sqlerrm; end $$;
grant execute on function pg_temp.fails(text) to authenticated, anon, service_role;
-- a sale as the cashier: lines + cash for the given amount
create or replace function pg_temp.sell(p_lines jsonb, p_pay jsonb, p_extra jsonb default '{}') returns jsonb language sql as $$
  select public.complete_sale(jsonb_build_object('tenant_id', pg_temp.v('t'), 'branch_id', pg_temp.v('b'), 'client_id', gen_random_uuid(),
    'lines', p_lines, 'payments', p_pay) || p_extra) $$;
grant execute on function pg_temp.sell(jsonb, jsonb, jsonb) to authenticated;

do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('O');
insert into mx values ('t', public.create_tenant('{"name":"Mega Test","country_code":"KW","business_profile":"cafe","pin":"9999"}')::text);
reset role;
-- every built module on for this test business (set directly by the platform)
update tenants set features = (select jsonb_object_agg(key, true) from feature_modules where built),
       settings = settings || '{"loyalty_earn": 10, "loyalty_point_value": 5, "loyalty_min_points": 20}', booking_slug = 'mega-test'
 where id = pg_temp.v('t')::uuid;
update tenants set settings = settings || '{"booking_online": true}' where id = pg_temp.v('t')::uuid;
insert into mx select 'b', id::text from branches where tenant_id = pg_temp.v('t')::uuid;
insert into memberships(tenant_id, user_id, role, display_name, pin_hash) values
  (pg_temp.v('t')::uuid, pg_temp.v('C')::uuid, 'cashier', 'Ali', null),
  (pg_temp.v('t')::uuid, pg_temp.v('S')::uuid, 'cashier', 'Noura', null);
update memberships set bookable = true, commission_pct = 10 where user_id = pg_temp.v('S')::uuid;
insert into staff_hours(tenant_id, branch_id, user_id, weekday, start_time, end_time)
select pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, pg_temp.v('S')::uuid, d, '09:00', '21:00' from generate_series(1, 7) d;
insert into customers(tenant_id, name, phone, credit_limit) values (pg_temp.v('t')::uuid, 'Reem', '+96550001111', 0);
insert into mx select 'cust', id::text from customers where tenant_id = pg_temp.v('t')::uuid;

-- ================================================================ B · add-ons
insert into items(tenant_id, name, price, cost, track_stock, item_type, unit) values
  (pg_temp.v('t')::uuid, 'Latte', 1500, 300, false, 'standard', 'pcs'),
  (pg_temp.v('t')::uuid, 'Oat milk', 0, 400, true, 'ingredient', 'l');
insert into mx select lower(replace(name,' ','_')), id::text from items where tenant_id = pg_temp.v('t')::uuid;
insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost) values (pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, pg_temp.v('oat_milk')::uuid, 10, 'receipt', 400);
insert into modifier_groups(tenant_id, name, min_select, max_select, sort) values (pg_temp.v('t')::uuid, 'Size', 1, 1, 1), (pg_temp.v('t')::uuid, 'Milk', 0, 1, 2);
insert into mx select 'g_' || lower(name), id::text from modifier_groups where tenant_id = pg_temp.v('t')::uuid;
insert into modifier_options(tenant_id, group_id, name, price, item_id, qty, sort) values
  (pg_temp.v('t')::uuid, pg_temp.v('g_size')::uuid, 'Small', 0, null, 0, 1),
  (pg_temp.v('t')::uuid, pg_temp.v('g_size')::uuid, 'Large', 500, null, 0, 2),
  (pg_temp.v('t')::uuid, pg_temp.v('g_milk')::uuid, 'Oat milk', 250, pg_temp.v('oat_milk')::uuid, 0.2, 1);
insert into mx select 'o_' || lower(replace(name,' ','_')), id::text from modifier_options where tenant_id = pg_temp.v('t')::uuid;
insert into item_modifier_groups(tenant_id, item_id, group_id, sort) values
  (pg_temp.v('t')::uuid, pg_temp.v('latte')::uuid, pg_temp.v('g_size')::uuid, 1), (pg_temp.v('t')::uuid, pg_temp.v('latte')::uuid, pg_temp.v('g_milk')::uuid, 2);

do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
do $$ declare r jsonb; begin
  assert pg_temp.fails($q$select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('latte'), 'qty', 1)), '[{"tender":"cash","amount":1500}]')$q$) like 'ZT422:choose Size%', 'size is required';
  -- 2 large oat lattes: (1.500 + 0.500 + 0.250) × 2 = 4.500
  r := pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('latte'), 'qty', 2, 'modifiers', jsonb_build_array(pg_temp.v('o_large'), pg_temp.v('o_oat_milk')))),
                    '[{"tender":"cash","amount":4500}]');
  assert (r->>'total')::bigint = 4500, 'add-ons priced: ' || (r->>'total');
  assert r->'lines'->0->>'name' = 'Latte (Large, Oat milk)', 'add-ons in the line name';
end $$;
reset role;
do $$ begin
  assert (select sum(qty) from stock_movements where item_id = pg_temp.v('oat_milk')::uuid) = 9.6, 'oat milk used: 0.2 l × 2';
end $$;

-- ================================================================ B · variants
insert into items(tenant_id, name, price, cost, sku) values (pg_temp.v('t')::uuid, 'Abaya', 25000, 9000, 'ABY');
insert into mx select 'abaya', id::text from items where tenant_id = pg_temp.v('t')::uuid and name = 'Abaya';
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('O');
do $$ begin
  assert public.generate_variants(jsonb_build_object('template_id', pg_temp.v('abaya'), 'attrs', '{"Size":["S","M"],"Colour":["Black","Navy"]}'::jsonb)) = 4, 'four variants';
  assert public.generate_variants(jsonb_build_object('template_id', pg_temp.v('abaya'), 'attrs', '{"Size":["S","M","L"],"Colour":["Black","Navy"]}'::jsonb)) = 2, 'only the new size added';
end $$;
reset role;
do $$ begin
  assert (select is_template and not track_stock from items where id = pg_temp.v('abaya')::uuid), 'template not stocked';
  assert (select sku from items where parent_id = pg_temp.v('abaya')::uuid and variant_attrs = '{"Size":"M","Colour":"Navy"}') = 'ABY-NAV-M', 'variant sku';
end $$;
insert into mx select 'abaya_m_black', id::text from items where parent_id = pg_temp.v('abaya')::uuid and variant_attrs = '{"Size":"M","Colour":"Black"}';
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
do $$ begin
  assert pg_temp.fails($q$select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('abaya'), 'qty', 1)), '[{"tender":"cash","amount":25000}]')$q$) like 'ZT422:choose a size%', 'template cannot be sold';
  perform pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('abaya_m_black'), 'qty', 1)), '[{"tender":"cash","amount":25000}]');
end $$;
reset role;

-- ================================================================ B · batches & expiry (FEFO), weighed items
insert into items(tenant_id, name, price, cost, unit, track_expiry, sold_by_weight, plu) values (pg_temp.v('t')::uuid, 'Labneh', 2000, 800, 'kg', true, true, '00042');
insert into mx select 'labneh', id::text from items where tenant_id = pg_temp.v('t')::uuid and name = 'Labneh';
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('O');
select public.receive_stock_batch(pg_temp.v('b')::uuid, pg_temp.v('labneh')::uuid, 5, 800, 'Almarai', 'L-LATE', current_date + 30);
select public.receive_stock_batch(pg_temp.v('b')::uuid, pg_temp.v('labneh')::uuid, 3, 800, 'Almarai', 'L-SOON', current_date + 3);
select pg_temp.as_user('C');
-- 4.250 kg sold by weight: the soon-to-expire batch goes first
select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('labneh'), 'qty', 4.25)), '[{"tender":"cash","amount":8500}]');
reset role;
do $$ begin
  assert (select on_hand from v_batches where item_id = pg_temp.v('labneh')::uuid and batch_no = 'L-SOON') = 0, 'FEFO: L-SOON emptied first';
  assert (select on_hand from v_batches where item_id = pg_temp.v('labneh')::uuid and batch_no = 'L-LATE') = 3.75, 'FEFO: rest from L-LATE';
end $$;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('O');
select public.write_off_batch((select id from stock_batches where batch_no = 'L-LATE' and item_id = pg_temp.v('labneh')::uuid), 0.75, 'Damaged');
reset role;
do $$ begin
  assert (select on_hand from v_batches where batch_no = 'L-LATE' and item_id = pg_temp.v('labneh')::uuid) = 3, 'write-off from that batch';
  assert (select sum(qty) from stock_movements where item_id = pg_temp.v('labneh')::uuid) = 3, 'stock matches batches';
end $$;

-- ================================================================ B · promotions & bundles
insert into items(tenant_id, name, price, cost, track_stock) values
  (pg_temp.v('t')::uuid, 'Notebook', 1000, 300, false), (pg_temp.v('t')::uuid, 'Pen', 250, 50, false), (pg_temp.v('t')::uuid, 'Ruler', 300, 60, false);
insert into mx select lower(name), id::text from items where tenant_id = pg_temp.v('t')::uuid and name in ('Notebook','Pen','Ruler');
insert into promotions(tenant_id, name, kind, params, item_ids) values
  (pg_temp.v('t')::uuid, 'Pens 3 for 2', 'bxgy', '{"buy":2,"get":1,"percent":100}', array[pg_temp.v('pen')::uuid]),
  (pg_temp.v('t')::uuid, 'School kit', 'bundle', jsonb_build_object('price', 1200, 'components', jsonb_build_array(
     jsonb_build_object('item_id', pg_temp.v('notebook'), 'qty', 1), jsonb_build_object('item_id', pg_temp.v('pen'), 'qty', 1), jsonb_build_object('item_id', pg_temp.v('ruler'), 'qty', 1))), null),
  (pg_temp.v('t')::uuid, '10% notebooks', 'percent', '{"percent":10}', array[pg_temp.v('notebook')::uuid]);
insert into promotions(tenant_id, name, kind, params, coupon_code) values (pg_temp.v('t')::uuid, '5 off', 'amount', '{"amount":500,"min_amount":3000}', 'SAVE5');
do $$ declare a jsonb; begin
  -- 1 notebook + 4 pens + 1 ruler
  a := promo_allowance(pg_temp.v('t')::uuid, now(), jsonb_build_array(
    jsonb_build_object('idx', 1, 'item_id', pg_temp.v('notebook'), 'qty', 1, 'gross', 1000),
    jsonb_build_object('idx', 2, 'item_id', pg_temp.v('pen'), 'qty', 4, 'gross', 1000),
    jsonb_build_object('idx', 3, 'item_id', pg_temp.v('ruler'), 'qty', 1, 'gross', 300)));
  -- kit: 1000+250+300 = 1550 → 1200 saves 350 (notebook 226, pen 56, ruler 68); notebook 10% = 100 < 226; pens 3-for-2 = 250 > 56
  assert a = jsonb_build_array(
    jsonb_build_object('idx', 1, 'promo_id', (select id from promotions where name = 'School kit'), 'discount', 226),
    jsonb_build_object('idx', 2, 'promo_id', (select id from promotions where name = 'Pens 3 for 2'), 'discount', 250),
    jsonb_build_object('idx', 3, 'promo_id', (select id from promotions where name = 'School kit'), 'discount', 68)), 'best per line: ' || a::text;
  -- coupon only with the code
  assert jsonb_array_length(promo_allowance(pg_temp.v('t')::uuid, now(), '[{"idx":1,"item_id":null,"qty":1,"gross":4000}]')) = 0, 'no coupon, no discount';
  assert promo_allowance(pg_temp.v('t')::uuid, now(), '[{"idx":1,"item_id":null,"qty":1,"gross":4000}]', 'save5')->0->>'discount' = '500', 'coupon applies';
end $$;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
do $$ declare r jsonb; begin
  -- the POS claims the promotions: no approval needed
  r := pg_temp.sell(jsonb_build_array(
         jsonb_build_object('item_id', pg_temp.v('notebook'), 'qty', 1, 'promo_discount', 226),
         jsonb_build_object('item_id', pg_temp.v('pen'), 'qty', 4, 'promo_discount', 250),
         jsonb_build_object('item_id', pg_temp.v('ruler'), 'qty', 1, 'promo_discount', 68)), '[{"tender":"cash","amount":1756}]');
  assert (r->>'total')::bigint = 1756 and (r->>'discount_total')::bigint = 544, 'promotions applied without approval';
  -- claiming more than the rules allow is capped, so the payment no longer matches
  assert pg_temp.fails($q$select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('pen'), 'qty', 1, 'promo_discount', 250)), '[{"tender":"cash","amount":0.0}]')$q$) <> '', 'over-claim refused';
  assert pg_temp.fails($q$select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('pen'), 'qty', 1, 'discount', 100)), '[{"tender":"cash","amount":150}]')$q$) like 'ZT401%', 'manual discount still needs approval';
end $$;
reset role;

-- ================================================================ C · appointments & online booking
insert into items(tenant_id, name, price, item_type, duration_min, commission_pct) values
  (pg_temp.v('t')::uuid, 'Haircut', 5000, 'service', 45, null), (pg_temp.v('t')::uuid, 'Colour', 15000, 'service', 90, 20);
insert into mx select lower(name), id::text from items where tenant_id = pg_temp.v('t')::uuid and item_type = 'service';
insert into mx select 'day', (current_date + 2)::text;
insert into mx select 'slot', (((current_date + 2) + time '10:00')::timestamp at time zone (select timezone from branches where id = pg_temp.v('b')::uuid))::text;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
insert into mx select 'appt', public.save_appointment(jsonb_build_object('branch_id', pg_temp.v('b'), 'customer_id', pg_temp.v('cust'), 'staff_id', pg_temp.v('S'),
  'starts_at', pg_temp.v('slot'), 'service_ids', jsonb_build_array(pg_temp.v('haircut'))))::text;
do $$ begin
  assert pg_temp.fails(format($q$select public.save_appointment(jsonb_build_object('branch_id', %L, 'staff_id', %L, 'starts_at', (%L::timestamptz + interval '30 minutes'), 'service_ids', jsonb_build_array(%L)))$q$,
    pg_temp.v('b'), pg_temp.v('S'), pg_temp.v('slot'), pg_temp.v('colour'))) like 'ZT422:This staff member is already booked%', 'no double booking';
  assert pg_temp.fails(format($q$select public.save_appointment(jsonb_build_object('branch_id', %L, 'staff_id', %L, 'starts_at', %L, 'service_ids', jsonb_build_array(%L)))$q$,
    pg_temp.v('b'), pg_temp.v('C'), pg_temp.v('slot'), pg_temp.v('colour'))) like 'ZT422:choose a staff member%', 'only bookable staff';
end $$;
reset role;
set role anon;
do $$ declare info jsonb; slots jsonb; r jsonb; begin
  info := booking_info('Mega-Test');
  assert jsonb_array_length(info->'services') = 2 and jsonb_array_length(info->'staff') = 1, 'public booking info';
  slots := booking_slots('mega-test', pg_temp.v('b')::uuid, array[pg_temp.v('colour')::uuid], pg_temp.v('day')::date);
  assert not exists (select 1 from jsonb_array_elements(slots) x where (x->>'starts_at')::timestamptz > pg_temp.v('slot')::timestamptz - interval '90 minutes'
                     and (x->>'starts_at')::timestamptz < pg_temp.v('slot')::timestamptz + interval '45 minutes'), 'booked time not offered';
  assert exists (select 1 from jsonb_array_elements(slots) x where (x->>'starts_at')::timestamptz = pg_temp.v('slot')::timestamptz + interval '45 minutes'), 'right after is free';
  r := book_online('mega-test', jsonb_build_object('branch_id', pg_temp.v('b'), 'staff_id', pg_temp.v('S'), 'service_ids', jsonb_build_array(pg_temp.v('colour')),
        'starts_at', (pg_temp.v('slot')::timestamptz + interval '45 minutes'), 'name', 'Huda', 'phone', '+965 5000 2222'));
  assert r->>'id' is not null, 'booked online';
  assert pg_temp.fails(format($q$select book_online('mega-test', jsonb_build_object('branch_id', %L, 'staff_id', %L, 'service_ids', jsonb_build_array(%L), 'starts_at', %L, 'name', 'X', 'phone', '+96550003333'))$q$,
    pg_temp.v('b'), pg_temp.v('S'), pg_temp.v('colour'), pg_temp.v('slot')::timestamptz + interval '45 minutes')) like 'ZT422:This time was just taken%', 'taken slot refused';
  assert pg_temp.fails($q$select save_appointment('{"branch_id":"00000000-0000-0000-0000-000000000000"}')$q$) <> '', 'anon cannot book as staff';
end $$;
reset role;
do $$ begin
  assert (select source from appointments a join customers c on c.id = a.customer_id where c.phone = '+96550002222') = 'online', 'online source';
end $$;

-- checkout the appointment: haircut by Noura → commission 10% of net; the appointment is completed
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('haircut'), 'qty', 1, 'staff_id', pg_temp.v('S'))),
  '[{"tender":"card","amount":5000}]', jsonb_build_object('customer_id', pg_temp.v('cust'), 'appointment_id', pg_temp.v('appt')));
reset role;
do $$ begin
  assert (select status from appointments where id = pg_temp.v('appt')::uuid) = 'completed', 'appointment completed';
  assert (select sum(commission) from v_commissions where tenant_id = pg_temp.v('t')::uuid and staff_id = pg_temp.v('S')::uuid) = 500, 'commission 10% of 5.000';
end $$;

-- ================================================================ C · packages (prepaid sessions)
insert into items(tenant_id, name, price, item_type) values (pg_temp.v('t')::uuid, '4 haircuts', 16000, 'package');
insert into mx select 'pkg_item', id::text from items where tenant_id = pg_temp.v('t')::uuid and name = '4 haircuts';
insert into package_defs(tenant_id, item_id, kind, sessions, validity_days, covers) values (pg_temp.v('t')::uuid, pg_temp.v('pkg_item')::uuid, 'sessions', 4, 180, array[pg_temp.v('haircut')::uuid]);
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('pkg_item'), 'qty', 1)), '[{"tender":"cash","amount":16000}]', jsonb_build_object('customer_id', pg_temp.v('cust')));
reset role;
insert into mx select 'cp', id::text from customer_packages where customer_id = pg_temp.v('cust')::uuid;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
do $$ declare r jsonb; begin
  -- a haircut (5.000) from the package: valued at 16.000 / 4 = 4.000, paid by the package, nothing to pay
  r := pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('haircut'), 'qty', 1, 'staff_id', pg_temp.v('S'), 'customer_package_id', pg_temp.v('cp'))),
         '[]', jsonb_build_object('customer_id', pg_temp.v('cust')));
  assert (r->>'total')::bigint = 4000 and r->'payments'->0->>'tender' = 'package', 'session paid by the package';
  assert pg_temp.fails(format($q$select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', %L, 'qty', 1, 'customer_package_id', %L)), '[]', '{}')$q$, pg_temp.v('colour'), pg_temp.v('cp'))) like 'ZT422:%', 'not for another service or customer';
end $$;
reset role;
do $$ begin
  assert (select sessions_used || '/' || sessions_total || ' ' || released from customer_packages where id = pg_temp.v('cp')::uuid) = '1/4 4000', 'one session used';
  assert (select sum(jl.credit - jl.debit) from journal_lines jl join accounts a on a.id = jl.account_id where a.system_key = 'deferred_revenue' and jl.tenant_id = pg_temp.v('t')::uuid) = 12000, 'deferred 16.000, 4.000 released';
end $$;

-- ================================================================ D · job card with deposit
insert into items(tenant_id, name, price, item_type) values (pg_temp.v('t')::uuid, 'Shirt wash & iron', 500, 'service'), (pg_temp.v('t')::uuid, 'Suit dry clean', 3000, 'service');
insert into mx select lower(split_part(name, ' ', 1)), id::text from items where tenant_id = pg_temp.v('t')::uuid and name in ('Shirt wash & iron','Suit dry clean');
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
insert into mx select 'job', (public.save_work_order(jsonb_build_object('branch_id', pg_temp.v('b'), 'kind', 'job', 'customer_id', pg_temp.v('cust'), 'tags', '101-106',
  'lines', jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('shirt'), 'qty', 5), jsonb_build_object('item_id', pg_temp.v('suit'), 'qty', 1)))))->>'id';
select public.take_deposit(pg_temp.v('job')::uuid, 'cash', 2000);
select public.set_work_order_status(pg_temp.v('job')::uuid, 'ready');
-- collected: 5.500 total, 2.000 deposit applied automatically, 3.500 card
select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('shirt'), 'qty', 5), jsonb_build_object('item_id', pg_temp.v('suit'), 'qty', 1)),
  '[{"tender":"card","amount":3500}]', jsonb_build_object('customer_id', pg_temp.v('cust'), 'work_order_id', pg_temp.v('job')));
reset role;
do $$ begin
  assert (select number || ' ' || status || ' ' || deposit_used from work_orders where id = pg_temp.v('job')::uuid) = 'B01-JOB-00001 collected 2000', 'job collected, deposit used';
  assert (select coalesce(sum(jl.credit - jl.debit), 0) from journal_lines jl join accounts a on a.id = jl.account_id where a.system_key = 'customer_deposits' and jl.tenant_id = pg_temp.v('t')::uuid) = 0, 'deposit liability cleared';
end $$;

-- ================================================================ D · table order: send to kitchen, add more, void needs approval, split the bill
insert into dining_tables(tenant_id, branch_id, name, seats) values (pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, 'T1', 4);
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
insert into mx select 'oo', (public.save_open_order(jsonb_build_object('branch_id', pg_temp.v('b'), 'table_id', (select id from dining_tables where name = 'T1'), 'guests', 2, 'fire', true,
  'lines', jsonb_build_array(jsonb_build_object('key', 'a', 'item_id', pg_temp.v('latte'), 'qty', 2, 'modifiers', jsonb_build_array(pg_temp.v('o_small')))))))->>'id';
do $$ begin
  assert pg_temp.fails(format($q$select public.save_open_order(jsonb_build_object('branch_id', %L, 'table_id', (select id from dining_tables where name = 'T1'), 'lines', '[]'::jsonb))$q$, pg_temp.v('b'))) like 'ZT422:This table already%', 'one open order per table';
  -- reducing a line already in the kitchen needs a PIN
  assert pg_temp.fails(format($q$select public.save_open_order(jsonb_build_object('id', %L, 'branch_id', %L, 'lines', jsonb_build_array(jsonb_build_object('key','a','item_id',%L,'qty',1,'modifiers',jsonb_build_array(%L)))))$q$,
    pg_temp.v('oo'), pg_temp.v('b'), pg_temp.v('latte'), pg_temp.v('o_small'))) like 'ZT401%', 'void needs approval';
end $$;
select public.save_open_order(jsonb_build_object('id', pg_temp.v('oo'), 'branch_id', pg_temp.v('b'), 'table_id', (select id from dining_tables where name = 'T1'), 'fire', true,
  'lines', jsonb_build_array(jsonb_build_object('key', 'a', 'item_id', pg_temp.v('latte'), 'qty', 2, 'modifiers', jsonb_build_array(pg_temp.v('o_small'))),
                             jsonb_build_object('key', 'b', 'item_id', pg_temp.v('notebook'), 'qty', 1))));
-- guest 1 pays the notebook, guest 2 the lattes
select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('notebook'), 'qty', 1)), '[{"tender":"cash","amount":1000}]',
  jsonb_build_object('open_order_id', pg_temp.v('oo'), 'open_order_keys', jsonb_build_array('b')));
reset role;
do $$ begin
  assert (select count(*) from kitchen_tickets where open_order_id = pg_temp.v('oo')::uuid) = 2, 'two rounds sent to the kitchen';
  assert (select status || ' ' || jsonb_array_length(lines) from open_orders where id = pg_temp.v('oo')::uuid) = 'open 1', 'one line left';
end $$;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('latte'), 'qty', 2, 'modifiers', jsonb_build_array(pg_temp.v('o_small')))), '[{"tender":"cash","amount":3000}]',
  jsonb_build_object('open_order_id', pg_temp.v('oo'), 'kitchen', jsonb_build_object('order_type', 'dine_in')));
reset role;
do $$ begin
  assert (select status from open_orders where id = pg_temp.v('oo')::uuid) = 'closed', 'table closed';
  assert (select count(*) from kitchen_tickets where open_order_id = pg_temp.v('oo')::uuid or sale_id in (select unnest(sale_ids) from open_orders where id = pg_temp.v('oo')::uuid)) = 2, 'paying does not re-send to the kitchen';
end $$;

-- ================================================================ D · loyalty: earn 10 points per KWD, a point is worth 0.005
do $$ begin
  -- Reem paid with money: haircut 5.000 (card) + package 16.000 (cash) + job 3.500 (card) = 24.500 → 245 points; the package session and the deposit earn nothing
  assert customer_points(pg_temp.v('cust')::uuid) = 245, 'points earned: ' || customer_points(pg_temp.v('cust')::uuid);
end $$;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
do $$ declare r jsonb; begin
  assert pg_temp.fails($q$select pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('pen'), 'qty', 1)), '[{"tender":"loyalty","amount":50},{"tender":"cash","amount":200}]', jsonb_build_object('customer_id', pg_temp.v('cust')))$q$) like 'ZT422:redeem at least%', 'minimum redeem';
  -- notebook 1.000: 0.900 with 180 points + 0.100 cash
  r := pg_temp.sell(jsonb_build_array(jsonb_build_object('item_id', pg_temp.v('notebook'), 'qty', 1)), '[{"tender":"loyalty","amount":900},{"tender":"cash","amount":100}]', jsonb_build_object('customer_id', pg_temp.v('cust')));
  insert into mx values ('nb_sale', r->>'id');
end $$;
reset role;
do $$ begin
  assert customer_points(pg_temp.v('cust')::uuid) = 66, '245 − 180 + 1 earned on the 0.100 cash: ' || customer_points(pg_temp.v('cust')::uuid);
end $$;

-- ================================================================ the books still balance and the hash chain holds
do $$ begin
  assert (select sum(debit) - sum(credit) from journal_lines where tenant_id = pg_temp.v('t')::uuid) = 0, 'ledger balanced';
end $$;
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('O');
do $$ declare v jsonb := verify_ledger(pg_temp.v('t')::uuid); begin assert (v->>'chain_breaks')::int = 0 and (v->>'hash_mismatches')::int = 0 and (v->>'unbalanced_entries')::int = 0 and (v->>'numbering_gaps')::int = 0, 'hash chain intact: ' || verify_ledger(pg_temp.v('t')::uuid)::text; end $$;
reset role;
\o
\echo 'ALL PHASE B-D MODULE TESTS PASSED'

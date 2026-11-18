-- Recipes, detailed inventory, stock count, delivery platforms and kitchen timing.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null
create temp table rx(k text primary key, v text);
grant all on rx to authenticated, anon, service_role;
insert into rx values ('O','e1000000-0000-0000-0000-00000000000a'),('C','e1000000-0000-0000-0000-00000000000b');
create or replace function pg_temp.v(k text) returns text language sql as $$ select v from rx where rx.k = $1 $$;
create or replace function pg_temp.as_user(k text) returns void language sql as $$ select set_config('request.jwt.claim.sub', (select v from rx where rx.k = $1), false) $$;

set role authenticated;
select pg_temp.as_user('O');
insert into rx values ('t', public.create_tenant('{"name":"Shawarma Lab","country_code":"KW","business_type":"food","pin":"9999"}')::text);
reset role;
insert into rx select 'b', id::text from branches where tenant_id = pg_temp.v('t')::uuid;
insert into memberships(tenant_id, user_id, role, display_name) values (pg_temp.v('t')::uuid, pg_temp.v('C')::uuid, 'cashier', 'Ali');
-- ingredients (stocked, never sold) and a recipe menu item
insert into items(tenant_id, name, name_ar, item_type, unit, cost, price, track_stock) values
  (pg_temp.v('t')::uuid, 'Chicken', 'دجاج', 'ingredient', 'kg', 1200, 0, true),
  (pg_temp.v('t')::uuid, 'Bread', 'خبز', 'ingredient', 'pcs', 50, 0, true),
  (pg_temp.v('t')::uuid, 'Garlic sauce', 'ثومية', 'ingredient', 'g', 2, 0, true),
  (pg_temp.v('t')::uuid, 'Chicken shawarma', 'شاورما دجاج', 'recipe', 'pcs', 0, 1250, true);
insert into rx select lower(replace(name,' ','_')), id::text from items where tenant_id = pg_temp.v('t')::uuid;
insert into recipe_lines(tenant_id, item_id, ingredient_id, qty) values
  (pg_temp.v('t')::uuid, pg_temp.v('chicken_shawarma')::uuid, pg_temp.v('chicken')::uuid, 0.15),
  (pg_temp.v('t')::uuid, pg_temp.v('chicken_shawarma')::uuid, pg_temp.v('bread')::uuid, 1),
  (pg_temp.v('t')::uuid, pg_temp.v('chicken_shawarma')::uuid, pg_temp.v('garlic_sauce')::uuid, 30);
-- opening stock: 10 kg chicken, 100 bread, 5000 g sauce
insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost)
select pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, id, case name when 'Chicken' then 10 when 'Bread' then 100 else 5000 end, 'receipt', cost
  from items where tenant_id = pg_temp.v('t')::uuid and item_type = 'ingredient';
do $$ begin
  assert (select track_stock from items where id = pg_temp.v('chicken_shawarma')::uuid) = false, 'recipe items are not stocked';
  assert (select public.recipe_cost(pg_temp.v('chicken_shawarma')::uuid)) = 290, 'recipe cost 0.15*1200 + 50 + 30*2 = 290';
end $$;

set role authenticated;
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id','e2000000-0000-0000-0000-000000000001',
  'lines', jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('chicken_shawarma'),'qty',4)),
  'payments','[{"tender":"cash","amount":5000}]'::jsonb)) is not null;
do $$ begin
  begin perform public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id','e2000000-0000-0000-0000-000000000009',
      'lines', jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('bread'),'qty',1,'unit_price',100)),'payments','[{"tender":"cash","amount":100}]'::jsonb));
    raise exception 'ingredients must not be sold';
  exception when sqlstate 'ZT422' then null; end;
end $$;
reset role;
do $$ begin
  assert (select sum(qty) from stock_movements where item_id = pg_temp.v('chicken')::uuid) = 9.4, 'chicken 10 - 4*0.15';
  assert (select sum(qty) from stock_movements where item_id = pg_temp.v('bread')::uuid) = 96, 'bread 100 - 4';
  assert (select sum(qty) from stock_movements where item_id = pg_temp.v('garlic_sauce')::uuid) = 4880, 'sauce 5000 - 120 g';
  assert not exists (select 1 from stock_movements where item_id = pg_temp.v('chicken_shawarma')::uuid), 'recipe item itself not stocked';
  assert (select sum(jl.debit) from journal_lines jl join accounts a on a.id = jl.account_id where a.system_key='cogs' and jl.tenant_id = pg_temp.v('t')::uuid) = 1160, 'COGS 4 x 290';
  assert (select on_hand from v_inventory where item_id = pg_temp.v('chicken')::uuid) = 9.4, 'inventory view';
end $$;

-- stock count: actual chicken 9.0 kg → loss 0.4 kg x 1.200 = 0.480 posted
set role authenticated;
select pg_temp.as_user('O');
do $$ declare r jsonb; begin
  r := public.post_stock_count(pg_temp.v('b')::uuid, jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('chicken'),'counted',9),
         jsonb_build_object('item_id',pg_temp.v('bread'),'counted',96)), 'Night count');
  assert (r->>'adjusted_lines')::int = 1 and (r->>'loss')::bigint = 480, 'count result ' || r::text;
  assert (select balance from public.stock_card(pg_temp.v('chicken')::uuid, pg_temp.v('b')::uuid, current_date - 1, current_date) order by created_at desc limit 1) = 9, 'stock card running balance';
end $$;

-- delivery platform: Keeta order via webhook token, idempotent, settlement with commission
insert into delivery_channels(tenant_id, branch_id, platform, display_name, commission_pct)
values (pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, 'keeta', 'Keeta', 18);
insert into rx select 'ch', id::text from delivery_channels where tenant_id = pg_temp.v('t')::uuid;
insert into rx values ('tok', public.rotate_channel_token(pg_temp.v('ch')::uuid));
reset role;
set role anon;
do $$ declare r jsonb; r2 jsonb; begin
  r := public.ingest_delivery_order(pg_temp.v('tok'), jsonb_build_object('external_ref','KT-778899','customer_name','Fahad (Keeta)',
         'items', jsonb_build_array(jsonb_build_object('name','Chicken shawarma','qty',2,'unit_price',1400,'note','extra garlic'))));
  r2 := public.ingest_delivery_order(pg_temp.v('tok'), jsonb_build_object('external_ref','KT-778899','items','[]'::jsonb));
  assert (r2->>'duplicate')::boolean, 'duplicate webhook ignored';
  begin perform public.ingest_delivery_order('ztd_wrong', '{"external_ref":"x"}'); raise exception 'bad token';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  assert (select count(*) from sales where channel_id = pg_temp.v('ch')::uuid) = 1, 'one platform sale';
  assert (select total from sales where channel_id = pg_temp.v('ch')::uuid) = 2800, 'platform price';
  assert (select count(*) from kitchen_tickets where sale_id = (select id from sales where channel_id = pg_temp.v('ch')::uuid)) = 1, 'kitchen ticket for delivery';
  assert (select order_type from kitchen_tickets where sale_id = (select id from sales where channel_id = pg_temp.v('ch')::uuid)) = 'delivery', 'delivery type';
  assert (select sum(jl.debit - jl.credit) from journal_lines jl join accounts a on a.id = jl.account_id where a.system_key = 'platform_clearing' and jl.tenant_id = pg_temp.v('t')::uuid) = 2800, 'platform receivable';
end $$;
set role authenticated;
select pg_temp.as_user('O');
select public.record_platform_settlement(jsonb_build_object('channel_id',pg_temp.v('ch'),'gross',2800,'commission',504,'reference','KEETA-PAYOUT-W47')) is not null;
reset role;
do $$ begin
  assert (select sum(jl.debit - jl.credit) from journal_lines jl join accounts a on a.id = jl.account_id where a.system_key = 'platform_clearing' and jl.tenant_id = pg_temp.v('t')::uuid) = 0, 'receivable cleared';
  assert (select sum(jl.debit) from journal_lines jl join accounts a on a.id = jl.account_id where a.system_key = 'exp_platform_fees' and jl.tenant_id = pg_temp.v('t')::uuid) = 504, 'commission expense';
  assert (select sum(debit) - sum(credit) from journal_lines where tenant_id = pg_temp.v('t')::uuid) = 0, 'ledger balanced';
end $$;

-- kitchen timing: waiting / preparing / total / late, readable by report users
do $$ declare tk uuid; begin
  select id into tk from kitchen_tickets where tenant_id = pg_temp.v('t')::uuid limit 1;
  perform set_config('zt.allow_rehash', '', false);
  update kitchen_tickets set created_at = now() - interval '14 minutes', started_at = now() - interval '12 minutes', ready_at = now() - interval '1 minute', served_at = now() where id = tk;
end $$;
set role authenticated;
select pg_temp.as_user('O');
do $$ declare r record; begin
  select * into r from v_kitchen_times where tenant_id = pg_temp.v('t')::uuid limit 1;
  assert r.wait_s between 115 and 125 and r.prep_s between 655 and 665 and r.total_s between 775 and 785, format('stage seconds %s/%s/%s', r.wait_s, r.prep_s, r.total_s);
  assert r.late, 'over 10 minutes is late';
end $$;
reset role;
\o
\echo 'ALL RECIPES, INVENTORY, DELIVERY AND KITCHEN TIMING TESTS PASSED'

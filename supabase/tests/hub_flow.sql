-- Branch hub flow: token auth, config, offline tickets synced before/after the sale, no duplicates.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null

create temp table hx(k text primary key, v text);
grant all on hx to authenticated, anon, service_role;
insert into hx values ('O','c0000000-0000-0000-0000-00000000000a'),('C','c0000000-0000-0000-0000-00000000000b');
create or replace function pg_temp.v(k text) returns text language sql as $$ select v from hx where hx.k = $1 $$;
create or replace function pg_temp.as_user(k text) returns void language sql as
$$ select set_config('request.jwt.claim.sub', (select v from hx where hx.k = $1), false) $$;

set role authenticated;
select pg_temp.as_user('O');
insert into hx values ('t', public.create_tenant('{"name":"Hub Cafe","country_code":"KW","business_type":"food","pin":"9999"}')::text);
reset role;
insert into hx select 'b', id::text from branches where tenant_id = pg_temp.v('t')::uuid;
insert into hx select 'st', id::text from kitchen_stations where tenant_id = pg_temp.v('t')::uuid;
update kitchen_stations set printer_ip = '192.168.1.50' where id = pg_temp.v('st')::uuid;
insert into memberships(tenant_id, user_id, role, display_name) values (pg_temp.v('t')::uuid, pg_temp.v('C')::uuid, 'cashier', 'Ali');
insert into items(tenant_id, name, name_ar, price) values (pg_temp.v('t')::uuid, 'Burger', 'برجر', 3000);

-- owner creates the hub; cashier cannot
set role authenticated;
select pg_temp.as_user('C');
do $$ begin
  begin perform public.create_hub(pg_temp.v('b')::uuid, 'Counter PC'); raise exception 'cashier must not create hubs';
  exception when sqlstate 'ZT401' then null; end;
end $$;
select pg_temp.as_user('O');
insert into hx values ('token', public.create_hub(pg_temp.v('b')::uuid, 'Counter PC'));
reset role;

-- the hub (anonymous + token) reads its config
set role anon;
do $$ declare c jsonb; begin
  c := public.hub_config(pg_temp.v('token'), '0.1.0');
  assert c->'hub'->>'branch_id' = pg_temp.v('b'), 'hub branch';
  assert c->'stations'->0->>'printer_ip' = '192.168.1.50', 'printer ip in config';
  begin perform public.hub_config('zth_wrong'); raise exception 'bad token must fail';
  exception when insufficient_privilege then null; end;
  -- internet down at the till: the hub syncs the ticket BEFORE the sale exists in the cloud
  perform public.hub_sync(pg_temp.v('token'), jsonb_build_array(jsonb_build_object(
    'id','d1000000-0000-0000-0000-000000000001','station_id',pg_temp.v('st'),'sale_client_id','f1000000-0000-0000-0000-000000000001',
    'order_ref','OFF-F1000000','order_type','dine_in','table_no','4','status','ready','created_at', now() - interval '5 minutes',
    'started_at', now() - interval '4 minutes','ready_at', now(),
    'items', jsonb_build_array(jsonb_build_object('id','d2000000-0000-0000-0000-000000000001','name','Burger','name_ar','برجر','qty',1,'note','بدون بصل','done',true)))));
  -- resend is idempotent and updates the status
  perform public.hub_sync(pg_temp.v('token'), jsonb_build_array(jsonb_build_object(
    'id','d1000000-0000-0000-0000-000000000001','station_id',pg_temp.v('st'),'sale_client_id','f1000000-0000-0000-0000-000000000001',
    'order_ref','OFF-F1000000','status','served','served_at', now(),'items','[]'::jsonb)));
end $$;
reset role;
do $$ begin
  assert (select count(*) from kitchen_tickets where tenant_id = pg_temp.v('t')::uuid) = 1, 'one ticket after resend';
  assert (select status from kitchen_tickets where tenant_id = pg_temp.v('t')::uuid) = 'served', 'latest status wins';
  assert (select sale_id from kitchen_tickets where tenant_id = pg_temp.v('t')::uuid) is null, 'sale not there yet';
end $$;

-- the offline sale reaches the cloud later (with kitchen.hub = true): linked, renamed, no duplicate tickets
set role authenticated;
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id','f1000000-0000-0000-0000-000000000001',
  'kitchen', jsonb_build_object('order_type','dine_in','table_no','4','hub',true),
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Burger' and tenant_id = pg_temp.v('t')::uuid),'qty',1,'note','بدون بصل')),
  'payments','[{"tender":"cash","amount":3000}]'::jsonb)) is not null;
reset role;
do $$ begin
  assert (select count(*) from kitchen_tickets where tenant_id = pg_temp.v('t')::uuid) = 1, 'no duplicate ticket from the cloud';
  assert (select s.client_id from kitchen_tickets k join sales s on s.id = k.sale_id where k.tenant_id = pg_temp.v('t')::uuid) = 'f1000000-0000-0000-0000-000000000001', 'ticket linked to sale';
  assert (select order_ref from kitchen_tickets where tenant_id = pg_temp.v('t')::uuid) = 'B01-INV-000001', 'offline ref replaced by invoice number';
  assert (select last_seen_at is not null from hubs where tenant_id = pg_temp.v('t')::uuid), 'hub heartbeat';
  assert (select token_hash <> pg_temp.v('token') from hubs where tenant_id = pg_temp.v('t')::uuid), 'token stored hashed';
end $$;

-- the other order: the sale reaches the cloud BEFORE the hub syncs its ticket → invoice number used
set role authenticated;
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id','f1000000-0000-0000-0000-000000000003',
  'kitchen', jsonb_build_object('order_type','takeaway','hub',true),
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Burger' and tenant_id = pg_temp.v('t')::uuid),'qty',1)),
  'payments','[{"tender":"cash","amount":3000}]'::jsonb)) is not null;
set role anon;
select public.hub_sync(pg_temp.v('token'), jsonb_build_array(jsonb_build_object(
  'id','d1000000-0000-0000-0000-000000000003','station_id',pg_temp.v('st'),'sale_client_id','f1000000-0000-0000-0000-000000000003',
  'order_ref','OFF-F1000003','status','ready','items','[]'::jsonb))) is not null;
reset role;
do $$ begin
  assert (select order_ref || '|' || (sale_id is not null)::text from kitchen_tickets where id = 'd1000000-0000-0000-0000-000000000003') = 'B01-INV-000002|true', 'sale-first order gets invoice number';
  delete from kitchen_ticket_items where ticket_id = 'd1000000-0000-0000-0000-000000000003';
  delete from kitchen_tickets where id = 'd1000000-0000-0000-0000-000000000003';
end $$;

-- without a hub the cloud still creates tickets itself
set role authenticated;
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id','f1000000-0000-0000-0000-000000000002',
  'kitchen', jsonb_build_object('order_type','takeaway'),
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Burger' and tenant_id = pg_temp.v('t')::uuid),'qty',2)),
  'payments','[{"tender":"cash","amount":6000}]'::jsonb)) is not null;
reset role;
do $$ begin
  assert (select count(*) from kitchen_tickets where tenant_id = pg_temp.v('t')::uuid) = 2, 'cloud ticket without hub';
end $$;

\o
\echo 'ALL BRANCH HUB TESTS PASSED'

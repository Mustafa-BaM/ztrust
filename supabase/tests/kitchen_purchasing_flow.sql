-- Role packages, KDS and purchasing flow test. Run with: supabase/tests/run.sh
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null

create temp table kx(k text primary key, v text);
grant all on kx to authenticated, service_role;
-- user ids
insert into kx values ('O','a0000000-0000-0000-0000-00000000000a'),('M','a0000000-0000-0000-0000-00000000000b'),
  ('P','a0000000-0000-0000-0000-00000000000c'),('S','a0000000-0000-0000-0000-00000000000d'),
  ('K','a0000000-0000-0000-0000-00000000000e'),('C','a0000000-0000-0000-0000-00000000000f');
create or replace function pg_temp.as_user(k text) returns void language sql as
$$ select set_config('request.jwt.claim.sub', (select v from kx where kx.k = $1), false) $$;

-- ---------- owner creates a café; role packages + default kitchen station are seeded
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('O');
insert into kx values ('t', public.create_tenant('{"name":"Bait Coffee","country_code":"KW","business_type":"food","pin":"9999"}')::text);
reset role;
do $$ begin
  assert (select count(*) from roles where tenant_id = (select v::uuid from kx where k='t')) = 12, '12 role packages';
  assert (select limit_value from role_permissions where tenant_id=(select v::uuid from kx where k='t') and role='manager' and permission='purchase.approve') = 1000000, 'manager PO limit 1000 KWD';
  assert (select count(*) from kitchen_stations where tenant_id=(select v::uuid from kx where k='t') and is_default) = 1, 'default station';
end $$;

insert into kx select 'b', id::text from branches where tenant_id = (select v::uuid from kx where k='t');
insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
select (select v::uuid from kx where k='t'), (select v::uuid from kx where k=x.k), x.role, x.name, extensions.crypt(x.pin, extensions.gen_salt('bf'))
  from (values ('M','manager','Mona','1111'),('P','purchasing','Pari','2222'),('S','storekeeper','Saad','3333'),
               ('K','kitchen','Karim','4444'),('C','cashier','Ali','5555')) x(k, role, name, pin);
insert into kitchen_stations(tenant_id, branch_id, name) select (select v::uuid from kx where k='t'), (select v::uuid from kx where k='b'), 'Bar';
insert into categories(tenant_id, name, station_id) select (select v::uuid from kx where k='t'), 'Drinks', id from kitchen_stations where name='Bar';
insert into categories(tenant_id, name) select v::uuid, 'Food' from kx where k='t';
insert into items(tenant_id, category_id, name, price, cost) select (select v::uuid from kx where k='t'), id, 'Latte', 1500, 400 from categories where name='Drinks';
insert into items(tenant_id, category_id, name, price, cost) select (select v::uuid from kx where k='t'), id, 'Burger', 3000, 1000 from categories where name='Food';

-- ---------- cashier sells dine-in: one ticket per station, line note travels to the kitchen
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('C');
insert into kx select 's1', (public.complete_sale(jsonb_build_object(
  'tenant_id',(select v from kx where k='t'),'branch_id',(select v from kx where k='b'),'client_id','d0000000-0000-0000-0000-000000000001',
  'kitchen', jsonb_build_object('order_type','dine_in','table_no','5'),
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Latte' and tenant_id=(select v::uuid from kx where k='t')),'qty',2),
                             jsonb_build_object('item_id',(select id from items where name='Burger' and tenant_id=(select v::uuid from kx where k='t')),'qty',1,'note','no onion')),
  'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',6000)))))->>'id';
insert into kx select 's2', (public.complete_sale(jsonb_build_object(
  'tenant_id',(select v from kx where k='t'),'branch_id',(select v from kx where k='b'),'client_id','d0000000-0000-0000-0000-000000000002',
  'kitchen', jsonb_build_object('order_type','takeaway'),
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Latte' and tenant_id=(select v::uuid from kx where k='t')),'qty',1)),
  'payments', jsonb_build_array(jsonb_build_object('tender','card','amount',1500)))))->>'id';
do $$ begin
  assert (select count(*) from kitchen_tickets) = 0, 'cashier has no kds.view';
  -- internal helpers are not callable by API users
  begin perform public._post((select v::uuid from kx where k='t'), null, 'x', null, 'x', '[]'); raise exception 'should be denied';
  exception when insufficient_privilege then null; end;
  begin perform public._seed_roles((select v::uuid from kx where k='t')); raise exception 'should be denied';
  exception when insufficient_privilege then null; end;
end $$;

-- ---------- kitchen screen
select pg_temp.as_user('K');
do $$ declare t1 uuid; begin
  assert (select count(*) from kitchen_tickets where sale_id = (select v::uuid from kx where k='s1')) = 2, 'two stations → two tickets';
  assert (select table_no from kitchen_tickets where sale_id = (select v::uuid from kx where k='s1') limit 1) = '5', 'table number';
  assert (select note from kitchen_ticket_items where name='Burger') = 'no onion', 'line note reaches kitchen';
  assert (select s.name from kitchen_tickets t join kitchen_stations s on s.id=t.station_id join kitchen_ticket_items i on i.ticket_id=t.id where i.name='Burger') = 'Kitchen', 'burger → default kitchen';
  select t.id into t1 from kitchen_tickets t join kitchen_stations s on s.id = t.station_id where s.name='Bar' and t.sale_id=(select v::uuid from kx where k='s1');
  begin perform public.kds_set_status(t1, 'served'); raise exception 'new→served must fail';
  exception when sqlstate 'ZT422' then null; end;
  perform public.kds_set_status(t1, 'preparing');
  perform public.kds_toggle_item((select id from kitchen_ticket_items where ticket_id = t1 limit 1));
  perform public.kds_set_status(t1, 'ready');
  perform public.kds_set_status(t1, 'served');
  assert (select started_at is not null and ready_at is not null and served_at is not null from kitchen_tickets where id = t1), 'timestamps';
  assert (select done from kitchen_ticket_items where ticket_id = t1 limit 1), 'item ticked';
  -- the kitchen role cannot sell
  begin perform public.complete_sale(jsonb_build_object('tenant_id',(select v from kx where k='t'),'branch_id',(select v from kx where k='b'),
      'client_id','d0000000-0000-0000-0000-000000000009','lines','[{"name":"x","qty":1,"unit_price":1}]','payments','[{"tender":"cash","amount":1}]'));
    raise exception 'kitchen must not sell';
  exception when sqlstate 'ZT401' then null; end;
end $$;

-- cancelling an invoice pulls its open ticket from the kitchen
select pg_temp.as_user('O');
select public.refund_sale(jsonb_build_object('sale_id',(select v from kx where k='s2'),'client_id','d0000000-0000-0000-0000-0000000000c2',
  'tender','card','reason','Customer left','cancel',true)) is not null;
do $$ begin
  assert (select status from kitchen_tickets where sale_id=(select v::uuid from kx where k='s2')) = 'cancelled', 'ticket cancelled with invoice';
end $$;

-- ---------- purchasing: officer creates, manager approves, storekeeper receives
select pg_temp.as_user('P');
insert into suppliers(tenant_id, name, phone) select v::uuid, 'Gulf Foods', '+96522000000' from kx where k='t';
insert into kx select 'po1', public.save_po(jsonb_build_object('tenant_id',(select v from kx where k='t'),'branch_id',(select v from kx where k='b'),
  'supplier_id',(select id from suppliers limit 1),
  'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Burger' and tenant_id=(select v::uuid from kx where k='t')),'qty',10,'unit_cost',1200),
                             jsonb_build_object('item_id',(select id from items where name='Latte' and tenant_id=(select v::uuid from kx where k='t')),'qty',20,'unit_cost',300))))::text;
do $$ begin
  assert (select total from purchase_orders where id=(select v::uuid from kx where k='po1')) = 18000, 'PO total 18.000';
  assert (select number from purchase_orders where id=(select v::uuid from kx where k='po1')) = 'B01-PO-000001', 'PO number';
  begin perform public.approve_po((select v::uuid from kx where k='po1'), null); raise exception 'needs approval';
  exception when sqlstate 'ZT401' then null; end;
  begin perform public.approve_po((select v::uuid from kx where k='po1'), '2222'); raise exception 'creator PIN must be denied';
  exception when sqlstate 'ZT403' then null; end;
  begin perform public.approve_po((select v::uuid from kx where k='po1'), '5555'); raise exception 'cashier PIN must be denied';
  exception when sqlstate 'ZT403' then null; end;
  perform public.approve_po((select v::uuid from kx where k='po1'), '1111');
  assert (select approved_by from purchase_orders where id=(select v::uuid from kx where k='po1')) = (select v::uuid from kx where k='M'), 'approved by manager';
  begin perform public.receive_po(jsonb_build_object('po_id',(select v from kx where k='po1'),'lines','[]')); raise exception 'purchasing cannot receive';
  exception when sqlstate 'ZT401' then null; end;
end $$;

-- a manager cannot approve their own order, even within limit
select pg_temp.as_user('M');
insert into kx select 'po2', public.save_po(jsonb_build_object('tenant_id',(select v from kx where k='t'),'branch_id',(select v from kx where k='b'),
  'supplier_id',(select id from suppliers limit 1),'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Latte' and tenant_id=(select v::uuid from kx where k='t')),'qty',5,'unit_cost',300))))::text;
do $$ begin
  begin perform public.approve_po((select v::uuid from kx where k='po2'), null); raise exception 'self-approval must ask for PIN';
  exception when sqlstate 'ZT401' then null; end;
  begin perform public.approve_po((select v::uuid from kx where k='po2'), '1111'); raise exception 'own PIN must be denied';
  exception when sqlstate 'ZT403' then null; end;
  perform public.approve_po((select v::uuid from kx where k='po2'), '9999');
  -- staff managers cannot touch the owner membership
  update memberships set role = 'cashier' where user_id = (select v::uuid from kx where k='O');
  assert (select role from memberships where user_id = (select v::uuid from kx where k='O')) = 'owner', 'owner protected';
end $$;

select pg_temp.as_user('S');
do $$ declare burger_line uuid; latte_line uuid; begin
  select id into burger_line from purchase_order_lines l where po_id=(select v::uuid from kx where k='po1') and item_id=(select id from items where name='Burger' and tenant_id=(select v::uuid from kx where k='t'));
  select id into latte_line  from purchase_order_lines l where po_id=(select v::uuid from kx where k='po1') and item_id=(select id from items where name='Latte' and tenant_id=(select v::uuid from kx where k='t'));
  perform public.receive_po(jsonb_build_object('po_id',(select v from kx where k='po1'),'supplier_ref','GF-881',
    'lines', jsonb_build_array(jsonb_build_object('line_id',burger_line,'qty',4))));
  assert (select status from purchase_orders where id=(select v::uuid from kx where k='po1')) = 'partially_received', 'partial';
  begin perform public.receive_po(jsonb_build_object('po_id',(select v from kx where k='po1'),'lines', jsonb_build_array(jsonb_build_object('line_id',burger_line,'qty',7))));
    raise exception 'over-receipt must fail';
  exception when sqlstate 'ZT422' then null; end;
  perform public.receive_po(jsonb_build_object('po_id',(select v from kx where k='po1'),
    'lines', jsonb_build_array(jsonb_build_object('line_id',burger_line,'qty',6), jsonb_build_object('line_id',latte_line,'qty',20))));
  assert (select status from purchase_orders where id=(select v::uuid from kx where k='po1')) = 'received', 'fully received';
  -- storekeeper cannot create or approve orders
  begin perform public.save_po(jsonb_build_object('tenant_id',(select v from kx where k='t'),'branch_id',(select v from kx where k='b'),
      'supplier_id',(select id from suppliers limit 1),'lines', jsonb_build_array(jsonb_build_object('item_id',(select id from items where name='Latte' and tenant_id=(select v::uuid from kx where k='t')),'qty',1,'unit_cost',1))));
    raise exception 'storekeeper cannot create POs';
  exception when sqlstate 'ZT401' then null; end;
end $$;
reset role;

do $$ begin
  assert (select sum(qty) from stock_movements where item_id=(select id from items where name='Burger' and tenant_id=(select v::uuid from kx where k='t'))) = 9, 'burger: -1 sold +10 received';
  assert (select cost from items where name='Burger' and tenant_id=(select v::uuid from kx where k='t')) = 1200, 'moving average cost (on hand was negative → new cost)';
  assert (select sum(credit) from journal_lines jl join accounts a on a.id=jl.account_id where a.system_key='ap' and jl.supplier_id is not null and jl.tenant_id=(select v::uuid from kx where k='t')) = 18000, 'AP by supplier';
  assert (select sum(debit) - sum(credit) from journal_lines where tenant_id=(select v::uuid from kx where k='t')) = 0, 'ledger balanced';
  assert (select count(*) from audit_log where action='purchase.approve' and tenant_id=(select v::uuid from kx where k='t')) = 2, 'approvals audited';
end $$;

-- ---------- owner builds a custom role package; system packages cannot be deleted
do $$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p where p.pronamespace = pg_my_temp_schema() loop execute format('grant execute on function %s to public', f.s); end loop; end $$;
set role authenticated;
select pg_temp.as_user('O');
insert into roles(tenant_id, key, name_en, name_ar) select v::uuid, 'night_cashier', 'Night cashier', 'كاشير ليلي' from kx where k='t';
insert into role_permissions(tenant_id, role, permission, limit_value) select v::uuid, 'night_cashier', 'sale.create', null from kx where k='t';
insert into role_permissions(tenant_id, role, permission, limit_value) select v::uuid, 'night_cashier', 'sale.discount', 0 from kx where k='t';
delete from roles where key = 'cashier';
do $$ begin
  assert exists (select 1 from roles where key='cashier'), 'system package cannot be deleted';
  begin insert into roles(tenant_id, key, name_en, name_ar, is_system) select v::uuid, 'fake', 'x', 'x', true from kx where k='t';
    raise exception 'cannot create system roles';
  exception when insufficient_privilege then null; end;
  update memberships set role = 'night_cashier' where user_id = (select v::uuid from kx where k='C');
  assert (select role from memberships where user_id = (select v::uuid from kx where k='C')) = 'night_cashier', 'custom role assigned';
end $$;
reset role;

\o
\echo 'ALL KITCHEN, PURCHASING AND ROLE TESTS PASSED'

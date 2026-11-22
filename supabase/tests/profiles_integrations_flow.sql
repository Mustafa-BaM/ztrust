-- Business profiles, module switches (UI + server gates), tenant guard, shop logo info, webhooks outbox, API keys.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;
\o /dev/null
create temp table px(k text primary key, v text);
grant all on px to authenticated, anon, service_role;
insert into px values ('O','f1000000-0000-0000-0000-00000000000a'),('M','f1000000-0000-0000-0000-00000000000b'),('C','f1000000-0000-0000-0000-00000000000c');
create or replace function pg_temp.v(k text) returns text language sql as $$ select v from px where px.k = $1 $$;
create or replace function pg_temp.as_user(k text) returns void language sql as $$ select set_config('request.jwt.claim.sub', (select v from px where px.k = $1), false) $$;
-- runs a statement and returns the SQLSTATE it failed with ('' when it succeeded)
create or replace function pg_temp.fails(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlstate; end $$;
grant execute on function pg_temp.fails(text) to authenticated, service_role;

-- ---------- catalog
do $$ begin
  assert (select count(*) from business_profiles) = 19, 'profiles';
  assert (select count(*) from business_profiles where launch) = 15, 'launch profiles';
  assert (select count(*) from feature_modules where built) = 28, 'built modules';
  assert (select string_agg(key, ',' order by sort) from feature_modules where not built) = 'consignment,gold_pricing', 'planned modules';
end $$;

-- ---------- a fashion shop signs up: only its built modules are on, no kitchen
set role authenticated;
select pg_temp.as_user('O');
insert into px values ('t', public.create_tenant('{"name":"Lulu Fashion","country_code":"KW","business_profile":"fashion","pin":"9999"}')::text);
reset role;
insert into px select 'b', id::text from branches where tenant_id = pg_temp.v('t')::uuid;
insert into memberships(tenant_id, user_id, role, display_name) values
  (pg_temp.v('t')::uuid, pg_temp.v('M')::uuid, 'manager', 'Mona'), (pg_temp.v('t')::uuid, pg_temp.v('C')::uuid, 'cashier', 'Ali');
do $$ declare f jsonb; begin
  select features into f from tenants where id = pg_temp.v('t')::uuid;
  assert f = '{"loyalty": true, "variants": true, "promotions": true, "purchasing": true}'::jsonb, 'fashion defaults: ' || f::text;
  assert (select business_profile from tenants where id = pg_temp.v('t')::uuid) = 'fashion', 'profile saved';
  assert (select business_type from tenants where id = pg_temp.v('t')::uuid) = 'retail', 'legacy type follows family';
  assert not exists (select 1 from kitchen_stations where tenant_id = pg_temp.v('t')::uuid), 'no kitchen station for fashion';
end $$;
insert into items(tenant_id, name, barcode, price, cost, reorder_point) values
  (pg_temp.v('t')::uuid, 'Abaya', 'AB1', 25000, 9000, 5),
  (pg_temp.v('t')::uuid, 'Scarf', 'SC1', 4000, 1000, null);
insert into px select lower(name), id::text from items where tenant_id = pg_temp.v('t')::uuid;
insert into customers(tenant_id, name, phone, credit_limit) values (pg_temp.v('t')::uuid, 'Office Co', '+96551111111', 100000);
insert into px select 'cust', id::text from customers where tenant_id = pg_temp.v('t')::uuid;

-- ---------- module switches: owner only; planned modules cannot be switched on
set role authenticated;
select pg_temp.as_user('M');
do $$ begin
  assert pg_temp.fails(format($q$select public.set_feature(%L, 'kitchen', true)$q$, pg_temp.v('t'))) = '42501', 'manager cannot switch modules';
end $$;
select pg_temp.as_user('O');
do $$ begin
  -- business details are editable from the app; billing, currency and switches are not
  assert pg_temp.fails(format($q$update tenants set name = 'Lulu Fashion House' where id = %L$q$, pg_temp.v('t'))) = '', 'owner edits name';
  assert (select name from tenants where id = pg_temp.v('t')::uuid) = 'Lulu Fashion House', 'name changed';
  assert pg_temp.fails(format($q$update tenants set plan = 'business' where id = %L$q$, pg_temp.v('t'))) = '42501', 'plan is guarded';
  assert pg_temp.fails(format($q$update tenants set features = '{"kitchen":true}' where id = %L$q$, pg_temp.v('t'))) = '42501', 'features are guarded';
  assert pg_temp.fails(format($q$update tenants set addons = '{"ai_assistant":true}' where id = %L$q$, pg_temp.v('t'))) = '42501', 'add-ons are guarded';
  assert pg_temp.fails(format($q$update tenants set currency = 'SAR' where id = %L$q$, pg_temp.v('t'))) = '42501', 'currency is guarded';
  assert pg_temp.fails(format($q$select public.set_feature(%L, 'serials', true)$q$, pg_temp.v('t'))) = 'ZT422', 'planned module refused';
  assert pg_temp.fails(format($q$select public.set_feature(%L, 'kitchen', true)$q$, pg_temp.v('t'))) = 'ZT422', 'a fashion shop cannot switch the kitchen on';
  assert pg_temp.fails(format($q$select public.set_feature(%L, 'appointments', true)$q$, pg_temp.v('t'))) = 'ZT422', 'nor appointments';
  assert pg_temp.fails(format($q$select public.set_feature(%L, 'nonsense', true)$q$, pg_temp.v('t'))) = 'ZT422', 'unknown module refused';
end $$;
reset role;

-- ---------- server gates while modules are off
set role authenticated;
select pg_temp.as_user('C');
do $$ begin
  -- on-account sale refused: credit is off for fashion
  assert pg_temp.fails(format($q$select public.complete_sale(jsonb_build_object('tenant_id',%L,'branch_id',%L,'client_id',gen_random_uuid(),'customer_id',%L,
    'lines', jsonb_build_array(jsonb_build_object('item_id',%L,'qty',1)), 'payments', jsonb_build_array(jsonb_build_object('tender','on_account','amount',4000))))$q$,
    pg_temp.v('t'), pg_temp.v('b'), pg_temp.v('cust'), pg_temp.v('scarf'))) = 'ZT422', 'credit off blocks on-account';
end $$;
reset role;
do $$ begin
  assert pg_temp.fails(format($q$insert into recipe_lines(tenant_id, item_id, ingredient_id, qty) values (%L, %L, %L, 1)$q$,
    pg_temp.v('t'), pg_temp.v('abaya'), pg_temp.v('scarf'))) = 'ZT422', 'recipes off blocks recipe lines';
  assert pg_temp.fails(format($q$insert into delivery_channels(tenant_id, branch_id, platform, display_name) values (%L, %L, 'keeta', 'Keeta')$q$,
    pg_temp.v('t'), pg_temp.v('b'))) = 'ZT422', 'delivery off blocks channels';
end $$;

-- ---------- owner switches credit and kitchen on: kitchen station appears, tickets flow; switched off again: no tickets
set role authenticated;
select pg_temp.as_user('O');
select public.set_feature(pg_temp.v('t')::uuid, 'credit', true);
-- the shop adds a coffee corner: business type café (modules unchanged), then the kitchen can be switched on
select public.set_business_profile(pg_temp.v('t')::uuid, 'cafe', false);
select public.set_feature(pg_temp.v('t')::uuid, 'kitchen', true);
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id',gen_random_uuid(),'customer_id',pg_temp.v('cust'),
  'kitchen', jsonb_build_object('order_type','takeaway'),
  'lines', jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('scarf'),'qty',1)), 'payments', jsonb_build_array(jsonb_build_object('tender','on_account','amount',4000))));
select pg_temp.as_user('O');
select public.set_feature(pg_temp.v('t')::uuid, 'kitchen', false);
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id',gen_random_uuid(),
  'kitchen', jsonb_build_object('order_type','takeaway'),
  'lines', jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('scarf'),'qty',1)), 'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',4000))));
reset role;
do $$ begin
  assert (select count(*) from kitchen_stations where tenant_id = pg_temp.v('t')::uuid) = 1, 'station created when kitchen switched on';
  assert (select count(*) from kitchen_tickets where tenant_id = pg_temp.v('t')::uuid) = 1, 'ticket only while kitchen was on';
  assert (select count(*) from sales where tenant_id = pg_temp.v('t')::uuid) = 2, 'both sales booked';
  assert (select count(*) from audit_log where tenant_id = pg_temp.v('t')::uuid and action like 'feature.%') = 3, 'switches audited';
end $$;

-- ---------- changing the business type adds the new profile's modules, keeps the old ones
set role authenticated;
select pg_temp.as_user('O');
select public.set_business_profile(pg_temp.v('t')::uuid, 'stationery', true);
reset role;
do $$ begin
  assert (select features from tenants where id = pg_temp.v('t')::uuid) = '{"credit": true, "kitchen": false, "loyalty": true, "variants": true, "promotions": true, "purchasing": true}'::jsonb, 'stationery keeps switches';
  assert (select business_profile from tenants where id = pg_temp.v('t')::uuid) = 'stationery', 'profile changed';
end $$;

-- ---------- shop logo reaches the payment page
update tenants set logo_url = 'https://cdn.example/logo.png' where id = pg_temp.v('t')::uuid;
set role authenticated;
select pg_temp.as_user('C');
insert into px select 'tok', (public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id',gen_random_uuid(),'customer_id',pg_temp.v('cust'),
  'lines', jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('scarf'),'qty',1)), 'payments', jsonb_build_array(jsonb_build_object('tender','payment_link','amount',4000)))))->'links'->0->>'token';
reset role;
do $$ declare tok text := pg_temp.v('tok'); begin
  assert tok is not null, 'payment link created';
  assert payment_link_info(tok)->>'logo_url' = 'https://cdn.example/logo.png', 'logo on payment page';
  update tenants set settings = settings || '{"logo_show": false}' where id = pg_temp.v('t')::uuid;
  assert payment_link_info(tok)->>'logo_url' is null, 'logo hidden when switched off';
end $$;

-- ---------- webhooks: need the integrations module; secret shown once, never readable afterwards
set role authenticated;
select pg_temp.as_user('O');
do $$ begin
  assert pg_temp.fails(format($q$select public.save_webhook(%L, '{"url":"https://n8n.example/webhook/zt","events":["sale.completed"]}')$q$, pg_temp.v('t'))) = 'ZT422', 'integrations off';
end $$;
select public.set_feature(pg_temp.v('t')::uuid, 'integrations', true);
do $$ declare r jsonb; begin
  assert pg_temp.fails(format($q$select public.save_webhook(%L, '{"url":"n8n.example","events":["sale.completed"]}')$q$, pg_temp.v('t'))) = 'ZT422', 'url validated';
  assert pg_temp.fails(format($q$select public.save_webhook(%L, '{"url":"https://n8n.example/x","events":["nope"]}')$q$, pg_temp.v('t'))) = 'ZT422', 'events validated';
  r := public.save_webhook(pg_temp.v('t')::uuid, '{"name":"n8n","url":"https://n8n.example/webhook/zt","events":["sale.completed","refund.created","stock.low","customer.created","shift.closed","payment_link.paid"]}');
  assert r->>'secret' like 'whsec_%' and length(r->>'secret') = 54, 'secret returned once';
  insert into px values ('wh', r->>'id');
  assert pg_temp.fails('select secret from webhook_endpoints') = '42501', 'secret not readable by the app';
  assert (select count(*) from webhook_endpoints) = 1, 'endpoint listed';
end $$;
select pg_temp.as_user('C');
do $$ begin
  assert pg_temp.fails(format($q$select public.save_webhook(%L, '{"url":"https://evil.example","events":["sale.completed"]}')$q$, pg_temp.v('t'))) <> '', 'cashier cannot add webhooks';
end $$;
reset role;

-- events: a sale (lines included, fired at commit), stock crossing the reorder point, a new customer, a refund
insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost) values (pg_temp.v('t')::uuid, pg_temp.v('b')::uuid, pg_temp.v('abaya')::uuid, 6, 'receipt', 9000);
set role authenticated;
select pg_temp.as_user('C');
insert into px select 'sale', (public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id',gen_random_uuid(),
  'lines', jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('abaya'),'qty',2)), 'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',50000)))))->>'id';
reset role;
insert into customers(tenant_id, name, phone) values (pg_temp.v('t')::uuid, 'Sara', '+96552222222');
update payment_links set status = 'paid' where token = pg_temp.v('tok');
do $$ declare p jsonb; begin
  assert (select count(*) from event_outbox where tenant_id = pg_temp.v('t')::uuid and event = 'sale.completed') = 1, 'one sale event (earlier sales were before the module)';
  select payload into p from event_outbox where event = 'sale.completed' and tenant_id = pg_temp.v('t')::uuid;
  assert p->'data'->>'total' = '50000' and jsonb_array_length(p->'data'->'lines') = 1 and p->'data'->'lines'->0->>'name' = 'Abaya', 'sale payload with lines: ' || p::text;
  assert (select payload->'data'->>'on_hand' from event_outbox where event = 'stock.low' and tenant_id = pg_temp.v('t')::uuid) = '4.000', 'stock.low at 4 (reorder 5)';
  assert (select count(*) from event_outbox where event = 'customer.created' and tenant_id = pg_temp.v('t')::uuid) = 1, 'customer event';
  assert (select count(*) from event_outbox where event = 'payment_link.paid' and tenant_id = pg_temp.v('t')::uuid) = 1, 'link paid event';
end $$;
-- a further sale below the reorder point does not repeat stock.low
set role authenticated;
select pg_temp.as_user('C');
select public.complete_sale(jsonb_build_object('tenant_id',pg_temp.v('t'),'branch_id',pg_temp.v('b'),'client_id',gen_random_uuid(),
  'lines', jsonb_build_array(jsonb_build_object('item_id',pg_temp.v('abaya'),'qty',1)), 'payments', jsonb_build_array(jsonb_build_object('tender','cash','amount',25000))));
reset role;
do $$ begin
  assert (select count(*) from event_outbox where event = 'stock.low' and tenant_id = pg_temp.v('t')::uuid) = 1, 'stock.low fires once per crossing';
end $$;

-- test button + dispatcher contract: claim (with secret), fail with backoff, succeed
set role authenticated;
select pg_temp.as_user('O');
insert into px select 'ping', public.test_webhook(pg_temp.v('wh')::uuid)::text;
reset role;
set role service_role;
do $$ declare r record; n int := 0; begin
  for r in select * from public.claim_events(100) loop
    n := n + 1;
    assert r.secret like 'whsec_%' and r.url = 'https://n8n.example/webhook/zt', 'dispatcher gets url and secret';
    if r.event = 'ping' then perform public.finish_event(r.id, false, 502, 'Bad gateway');
    else perform public.finish_event(r.id, true, 200, null); end if;
  end loop;
  assert n = 6, 'claimed all due events (2 sales, stock.low, customer, link paid, ping): ' || n;
  assert (select count(*) from public.claim_events(100)) = 0, 'nothing due right after';
end $$;
reset role;
do $$ declare o event_outbox%rowtype; begin
  select * into o from event_outbox where id = pg_temp.v('ping')::bigint;
  assert o.status = 'pending' and o.attempts = 1 and o.next_at > now() + interval '50 seconds' and o.response_code = 502, 'failed ping retried after a minute';
  assert (select count(*) from event_outbox where tenant_id = pg_temp.v('t')::uuid and status = 'sent') = 5, 'others sent';
  assert (select failures from webhook_endpoints where id = pg_temp.v('wh')::uuid) = 1, 'failure counted';
  update event_outbox set next_at = now() where id = o.id;
end $$;
set role service_role;
do $$ declare r record; begin
  for r in select * from public.claim_events(10) loop perform public.finish_event(r.id, true, 204, null); end loop;
end $$;
reset role;
do $$ begin
  assert (select status from event_outbox where id = pg_temp.v('ping')::bigint) = 'sent', 'retry delivered';
  assert (select failures from webhook_endpoints where id = pg_temp.v('wh')::uuid) = 0, 'failures reset on success';
end $$;
do $$ begin
  assert pg_temp.fails('select public.claim_events(1)') = '', 'admin may run';
end $$;
set role authenticated;
do $$ begin
  assert pg_temp.fails('select * from public.claim_events(1)') = '42501', 'app users cannot claim events';
end $$;
reset role;

-- ---------- API keys: owner creates (shown once), scoped reads, revocation
set role authenticated;
select pg_temp.as_user('M');
do $$ begin
  assert pg_temp.fails(format($q$select public.create_api_key(%L, 'n8n', array['items.read'])$q$, pg_temp.v('t'))) = '42501', 'only the owner creates keys';
end $$;
select pg_temp.as_user('O');
insert into px select 'key', public.create_api_key(pg_temp.v('t')::uuid, 'n8n reports', array['items.read','stock.read','admin.write'])->>'key';
do $$ begin
  assert pg_temp.v('key') ~ '^ztk_[0-9a-f]{8}_[0-9a-f]{48}$', 'key format';
  assert (select scopes from api_keys where tenant_id = pg_temp.v('t')::uuid) = array['items.read','stock.read'], 'unknown scopes dropped';
  assert pg_temp.fails('select key_hash from api_keys') = '42501', 'hash not readable';
end $$;
reset role;
set role anon;
do $$ declare r jsonb; begin
  r := public.api_query(pg_temp.v('key'), 'items');
  assert jsonb_array_length(r->'data') = 2 and r->>'currency' = 'KWD', 'items via API';
  r := public.api_query(pg_temp.v('key'), 'stock');
  assert (select x->>'on_hand' from jsonb_array_elements(r->'data') x where x->>'name' = 'Abaya') = '3.000', 'stock via API';
  assert pg_temp.fails(format($q$select public.api_query(%L, 'sales')$q$, pg_temp.v('key'))) = '42501', 'no sales scope';
  assert pg_temp.fails($q$select public.api_query('ztk_00000000_bad', 'items')$q$) = '42501', 'bad key';
end $$;
reset role;
set role authenticated;
select pg_temp.as_user('O');
select public.revoke_api_key((select id from api_keys where tenant_id = pg_temp.v('t')::uuid));
reset role;
set role anon;
do $$ begin
  assert pg_temp.fails(format($q$select public.api_query(%L, 'items')$q$, pg_temp.v('key'))) = '42501', 'revoked key refused';
end $$;
reset role;

-- ---------- older callers that send only business_type keep every built module
set role authenticated;
select pg_temp.as_user('O');
insert into px values ('t2', public.create_tenant('{"name":"Legacy Cafe","country_code":"KW","business_type":"food","pin":"9999"}')::text);
reset role;
do $$ begin
  assert (select features from tenants where id = pg_temp.v('t2')::uuid) = '{"credit": true, "tables": true, "kitchen": true, "recipes": true, "delivery": true, "modifiers": true, "promotions": true, "purchasing": true}'::jsonb, 'legacy keeps its five plus restaurant defaults';
  assert (select business_profile from tenants where id = pg_temp.v('t2')::uuid) = 'restaurant', 'legacy profile';
end $$;
\o
\echo 'ALL PROFILE, MODULE, WEBHOOK AND API KEY TESTS PASSED'

-- Z Trust · business profiles, feature modules, shop logo, outbound events (n8n / any webhook) and API keys
--  * business_profiles: 18 profiles (9 open for sign-up today); each switches on the modules it needs
--  * feature_modules: the switchable modules; only built ones can be switched on, planned ones show as "coming soon"
--  * tenants.features: module → on/off, chosen by the owner; tenants.addons: paid add-ons set by Z Trust billing only
--  * switching a module off hides it and blocks its server actions; it never deletes data
--  * events: signed webhooks queued in an outbox and delivered with retries by the dispatch-events function
--  * API keys: hashed, scoped, read-only for now (items, stock, sales, customers)

-- ================================================================ catalog
create table public.feature_modules (
  key      text primary key,
  name_en  text not null,
  name_ar  text not null,
  built    boolean not null default false,
  sort     integer not null
);

create table public.business_profiles (
  key          text primary key,
  name_en      text not null,
  name_ar      text not null,
  family       text not null check (family in ('food','retail','services','wholesale')),
  pos_mode     text not null check (pos_mode in ('grid','scan','calendar','ticket')),
  launch       boolean not null default false,   -- open for sign-up today
  modules      jsonb not null,                    -- module key → 2 (on by default) | 1 (suggested, off)
  sort         integer not null
);

insert into public.feature_modules(key, name_en, name_ar, built, sort) values
  ('kitchen','Kitchen screen & printers','شاشة المطبخ والطابعات', true, 1),
  ('recipes','Recipes & ingredients','الوصفات والمكونات', true, 2),
  ('delivery','Delivery platforms','منصات التوصيل', true, 3),
  ('credit','Sell on account','البيع على الحساب', true, 4),
  ('purchasing','Purchasing','المشتريات', true, 5),
  ('integrations','Integrations (webhooks & API)','الربط (Webhooks و API)', true, 6),
  ('tables','Tables & floor plan','الطاولات ومخطط الصالة', false, 10),
  ('modifiers','Modifiers & add-ons','الإضافات والخيارات', false, 11),
  ('variants','Variants (size × colour)','المقاسات والألوان', false, 12),
  ('batches','Batches & expiry (FEFO)','الدفعات والصلاحية', false, 13),
  ('weighed','Weighed items & scale barcodes','البيع بالوزن والميزان', false, 14),
  ('serials','Serial / IMEI & warranty','الأرقام التسلسلية والضمان', false, 15),
  ('promotions','Promotions & bundles','العروض والباكجات', false, 16),
  ('loyalty','Loyalty points','نقاط الولاء', false, 17),
  ('appointments','Appointments & calendar','المواعيد والتقويم', false, 18),
  ('commissions','Staff commissions','عمولات الموظفين', false, 19),
  ('memberships','Packages & memberships','الباقات والعضويات', false, 20),
  ('job_cards','Job cards','تذاكر العمل', false, 21),
  ('preorders','Pre-orders & deposits','الطلب المسبق والعربون', false, 22),
  ('consignment','Consignment','بضاعة الأمانة', false, 23),
  ('quotations','Quotations & B2B prices','عروض الأسعار وأسعار الجملة', false, 24),
  ('gold_pricing','Gold-rate pricing','تسعير الذهب', false, 25);

insert into public.business_profiles(key, name_en, name_ar, family, pos_mode, launch, sort, modules) values
  ('restaurant','Restaurant','مطعم','food','grid',true,1,'{"kitchen":2,"tables":2,"modifiers":2,"recipes":2,"delivery":2,"promotions":2,"purchasing":2,"batches":1,"loyalty":1,"credit":1,"preorders":1}'),
  ('cafe','Café','مقهى','food','grid',true,2,'{"kitchen":2,"modifiers":2,"recipes":2,"delivery":2,"promotions":2,"loyalty":2,"purchasing":2,"tables":1,"batches":1}'),
  ('quick_service','Fast food & cloud kitchen','وجبات سريعة ومطابخ سحابية','food','grid',true,3,'{"kitchen":2,"modifiers":2,"recipes":2,"delivery":2,"promotions":2,"purchasing":2,"loyalty":1,"batches":1}'),
  ('bakery','Bakery & sweets','مخابز وحلويات','food','grid',false,4,'{"recipes":2,"weighed":2,"batches":2,"preorders":2,"promotions":2,"purchasing":2,"kitchen":1,"modifiers":1,"delivery":1,"loyalty":1}'),
  ('grocery','Grocery & supermarket','بقالة وسوبرماركت','retail','scan',true,5,'{"weighed":2,"batches":2,"promotions":2,"credit":2,"purchasing":2,"loyalty":1,"consignment":1,"delivery":1}'),
  ('fashion','Fashion & shoes','ملابس وأحذية','retail','scan',true,6,'{"variants":2,"promotions":2,"loyalty":2,"purchasing":2,"consignment":1,"commissions":1}'),
  ('electronics','Electronics & mobiles','إلكترونيات وجوالات','retail','scan',false,7,'{"serials":2,"promotions":2,"purchasing":2,"variants":1,"job_cards":1,"credit":1,"quotations":1}'),
  ('stationery','Stationery, books & gifts','قرطاسية وكتب وهدايا','retail','scan',true,8,'{"promotions":2,"purchasing":2,"variants":1,"quotations":1,"credit":1,"loyalty":1,"consignment":1,"modifiers":1}'),
  ('perfume','Perfume, oud & cosmetics','عطور وعود وتجميل','retail','grid',true,9,'{"variants":2,"promotions":2,"loyalty":2,"purchasing":2,"recipes":1,"weighed":1,"modifiers":1,"batches":1,"commissions":1}'),
  ('jewelry','Jewelry & gold','ذهب ومجوهرات','retail','scan',false,10,'{"gold_pricing":2,"serials":2,"weighed":2,"purchasing":2,"credit":1,"preorders":1,"commissions":1}'),
  ('florist','Florist','ورد وتنسيق','retail','grid',false,11,'{"preorders":2,"modifiers":2,"delivery":2,"purchasing":2,"recipes":1,"batches":1,"promotions":1}'),
  ('salon','Salon & barber','صالون وحلاقة','services','calendar',true,12,'{"appointments":2,"commissions":2,"memberships":2,"purchasing":1,"recipes":1,"promotions":1,"loyalty":1}'),
  ('spa','Spa & beauty centre','سبا ومركز تجميل','services','calendar',false,13,'{"appointments":2,"commissions":2,"memberships":2,"promotions":2,"recipes":1,"loyalty":1,"purchasing":1}'),
  ('laundry','Laundry','مغسلة ملابس','services','ticket',true,14,'{"job_cards":2,"preorders":2,"credit":2,"memberships":1,"delivery":1,"promotions":1}'),
  ('car_wash','Car wash & auto service','غسيل سيارات وخدمة','services','ticket',false,15,'{"job_cards":2,"memberships":2,"appointments":1,"commissions":1,"credit":1,"promotions":1}'),
  ('gym','Gym & fitness','نادي رياضي','services','calendar',false,16,'{"memberships":2,"appointments":1,"commissions":1,"promotions":1}'),
  ('repair','Repair shop','صيانة وتصليح','services','ticket',false,17,'{"job_cards":2,"serials":2,"appointments":1,"credit":1,"quotations":1,"purchasing":1}'),
  ('wholesale','Wholesale & distribution','جملة وتوزيع','wholesale','scan',false,18,'{"quotations":2,"credit":2,"purchasing":2,"batches":1,"variants":1,"promotions":1,"consignment":1}');

alter table public.feature_modules enable row level security;
alter table public.business_profiles enable row level security;
create policy fm_read on public.feature_modules for select to anon, authenticated using (true);
create policy bp_read on public.business_profiles for select to anon, authenticated using (true);
revoke insert, update, delete on public.feature_modules, public.business_profiles from anon, authenticated;

-- ================================================================ tenant profile & switches
alter table public.tenants add column business_profile text references public.business_profiles(key);
alter table public.tenants add column features jsonb not null default '{}';
alter table public.tenants add column addons jsonb not null default '{}';   -- paid add-ons (whatsapp, ai_assistant): billing only

-- the built modules a profile switches on by default
create or replace function public._profile_features(p_profile text) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_object_agg(m.key, true), '{}')
    from business_profiles p cross join lateral jsonb_each_text(p.modules) e(k, v)
    join feature_modules m on m.key = e.k and m.built
   where p.key = p_profile and e.v = '2';
$$;

-- existing businesses keep everything they could already use
update public.tenants set
  business_profile = case business_type when 'food' then 'restaurant' when 'services' then 'salon' when 'mixed' then 'restaurant' else 'grocery' end,
  features = (select jsonb_object_agg(key, true) from public.feature_modules where built and key <> 'integrations');
alter table public.tenants alter column business_profile set not null;

create or replace function public.has_feature(p_tenant uuid, p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (features->>p_key)::boolean from tenants where id = p_tenant), false);
$$;
grant execute on function public.has_feature(uuid, text) to authenticated, service_role;

create or replace function public._require_feature(p_tenant uuid, p_key text) returns void
language plpgsql stable set search_path = public as $$
begin
  if not has_feature(p_tenant, p_key) then
    raise exception 'The % module is switched off for this business', p_key using errcode = 'ZT422', hint = 'feature_off:' || p_key;
  end if;
end $$;

-- managers with settings.manage may edit the business details, but billing, currency and module switches only change through the functions below
create or replace function public.guard_tenant_update() returns trigger language plpgsql as $$
begin
  if current_setting('zt.trusted', true) = 'on' or current_user in ('postgres','service_role','supabase_admin') then return new; end if;
  if new.plan is distinct from old.plan or new.trial_ends_at is distinct from old.trial_ends_at
     or new.addons is distinct from old.addons or new.features is distinct from old.features
     or new.business_profile is distinct from old.business_profile or new.business_type is distinct from old.business_type
     or new.currency is distinct from old.currency or new.currency_decimals is distinct from old.currency_decimals
     or new.country_code is distinct from old.country_code then
    raise exception 'these fields cannot be changed here' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger tenants_guard before update on public.tenants for each row execute function public.guard_tenant_update();

-- owner: change the business type; apply_defaults switches on the new profile's modules (nothing is switched off)
create or replace function public.set_business_profile(p_tenant uuid, p_profile text, p_apply_defaults boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_fam text; v_features jsonb;
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can change the business type' using errcode = '42501'; end if;
  select family into v_fam from business_profiles where key = p_profile;
  if v_fam is null then raise exception 'unknown business type %', p_profile using errcode = 'ZT422'; end if;
  perform set_config('zt.trusted', 'on', true);
  update tenants set business_profile = p_profile,
         business_type = case v_fam when 'food' then 'food' when 'services' then 'services' else 'retail' end::business_type,
         features = case when p_apply_defaults then features || _profile_features(p_profile) else features end
   where id = p_tenant returning features into v_features;
  perform set_config('zt.trusted', 'off', true);
  if exists (select 1 from feature_modules where key = 'kitchen') and (v_features->>'kitchen')::boolean then
    insert into kitchen_stations(tenant_id, branch_id, name, name_ar, is_default)
    select p_tenant, b.id, 'Kitchen', 'المطبخ', true from branches b
     where b.tenant_id = p_tenant and not exists (select 1 from kitchen_stations k where k.branch_id = b.id);
  end if;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), 'business_profile.set', 'tenant', p_tenant, jsonb_build_object('profile', p_profile, 'apply_defaults', p_apply_defaults));
  return v_features;
end $$;

-- owner: switch one module on or off
create or replace function public.set_feature(p_tenant uuid, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m feature_modules%rowtype; v_features jsonb;
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can switch modules' using errcode = '42501'; end if;
  select * into m from feature_modules where key = p_key;
  if not found then raise exception 'unknown module %', p_key using errcode = 'ZT422'; end if;
  if p_on and not m.built then raise exception '% is coming soon', m.name_en using errcode = 'ZT422'; end if;
  perform set_config('zt.trusted', 'on', true);
  update tenants set features = features || jsonb_build_object(p_key, p_on) where id = p_tenant returning features into v_features;
  perform set_config('zt.trusted', 'off', true);
  if p_key = 'kitchen' and p_on then
    insert into kitchen_stations(tenant_id, branch_id, name, name_ar, is_default)
    select p_tenant, b.id, 'Kitchen', 'المطبخ', true from branches b
     where b.tenant_id = p_tenant and not exists (select 1 from kitchen_stations k where k.branch_id = b.id);
  end if;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), case when p_on then 'feature.on' else 'feature.off' end, 'tenant', p_tenant, jsonb_build_object('module', p_key));
  return v_features;
end $$;
grant execute on function public.set_business_profile(uuid, text, boolean), public.set_feature(uuid, text, boolean) to authenticated;
revoke execute on function public._require_feature(uuid, text), public._profile_features(text) from public, anon, authenticated;

-- onboarding: choose a profile (old clients may still send business_type)
create or replace function public.create_tenant(p jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  c countries%rowtype;
  v_tenant uuid;
  v_profile text;
  v_fam text;
  v_features jsonb;
begin
  if v_uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into c from countries where code = upper(coalesce(p->>'country_code',''));
  if not found then raise exception 'unknown country %', p->>'country_code'; end if;
  v_profile := coalesce(nullif(p->>'business_profile',''),
                 case coalesce(nullif(p->>'business_type',''),'retail') when 'food' then 'restaurant' when 'mixed' then 'restaurant'
                                                                        when 'services' then 'salon' else 'grocery' end);
  select family into v_fam from business_profiles where key = v_profile;
  if v_fam is null then raise exception 'unknown business type %', v_profile using errcode = 'ZT422'; end if;
  -- callers that still send only business_type (older apps, integrations) keep every built module, as before profiles existed
  v_features := case when nullif(p->>'business_profile','') is null
                     then (select jsonb_object_agg(key, true) from feature_modules where built and key <> 'integrations')
                     else _profile_features(v_profile) end;

  insert into tenants(name, name_ar, country_code, currency, currency_decimals, default_language, business_type, business_profile, features,
                      tax_number, vat_rate, prices_include_tax, brand_color)
  values (p->>'name', p->>'name_ar', c.code,
          coalesce(nullif(p->>'currency',''), c.currency), c.currency_decimals,
          coalesce(nullif(p->>'language',''), c.default_language),
          case when p->>'business_type' = 'mixed' then 'mixed' when v_fam = 'food' then 'food' when v_fam = 'services' then 'services' else 'retail' end::business_type,
          v_profile, v_features,
          nullif(p->>'tax_number',''),
          coalesce((p->>'vat_rate')::numeric, c.vat_rate),
          coalesce((p->>'prices_include_tax')::boolean, c.prices_include_tax),
          coalesce(nullif(p->>'brand_color',''), '#2346D8'))
  returning id into v_tenant;

  insert into branches(tenant_id, code, name, name_ar, address, timezone)
  values (v_tenant, 'B01', coalesce(nullif(p->>'branch_name',''), 'Main branch'), p->>'branch_name_ar',
          p->>'branch_address', c.timezone);

  perform _seed_roles(v_tenant);

  insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
  values (v_tenant, v_uid, 'owner', coalesce(nullif(p->>'display_name',''), 'Owner'),
          case when length(coalesce(p->>'pin','')) >= 4 then crypt(p->>'pin', gen_salt('bf')) end);

  insert into accounts(tenant_id, code, name_en, name_ar, type, system_key)
  select v_tenant, code, name_en, name_ar, type, system_key from coa_template;

  if (v_features->>'kitchen')::boolean then
    insert into kitchen_stations(tenant_id, branch_id, name, name_ar, is_default)
    select v_tenant, id, 'Kitchen', 'المطبخ', true from branches where tenant_id = v_tenant;
  end if;
  return v_tenant;
end $$;

-- ================================================================ server-side gates for built modules
-- kitchen off: sales simply produce no kitchen tickets
create or replace function public._kitchen_from_sale(p_sale uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s sales%rowtype; k jsonb := p->'kitchen'; r record; v_ticket uuid; v_default uuid;
begin
  if k is null or jsonb_typeof(k) <> 'object' then return; end if;
  if coalesce((k->>'hub')::boolean, false) then return; end if;
  select * into s from sales where id = p_sale;
  if not has_feature(s.tenant_id, 'kitchen') then return; end if;   -- kitchen switched off: no tickets
  select id into v_default from kitchen_stations where branch_id = s.branch_id and is_active
   order by is_default desc, sort, name limit 1;
  if v_default is null then return; end if;
  for r in
    select coalesce(ks.id, v_default) as station_id,
           jsonb_agg(jsonb_build_object('name', l.name, 'name_ar', i.name_ar, 'qty', l.qty, 'note', l.note) order by l.name) as items
      from sale_lines l
      left join items i on i.id = l.item_id
      left join categories c on c.id = i.category_id
      left join kitchen_stations ks on ks.id = c.station_id and ks.is_active and ks.branch_id = s.branch_id
     where l.sale_id = s.id
     group by 1
  loop
    insert into kitchen_tickets(tenant_id, branch_id, station_id, sale_id, sale_client_id, order_ref, order_type, table_no, customer_name, note)
    values (s.tenant_id, s.branch_id, r.station_id, s.id, s.client_id, s.number,
            coalesce(nullif(k->>'order_type',''),'takeaway'), nullif(k->>'table_no',''),
            coalesce(nullif(k->>'customer_name',''), (select name from customers where id = s.customer_id)),
            nullif(k->>'note',''))
    returning id into v_ticket;
    insert into kitchen_ticket_items(tenant_id, ticket_id, name, name_ar, qty, note)
    select s.tenant_id, v_ticket, x->>'name', x->>'name_ar', (x->>'qty')::numeric, x->>'note'
      from jsonb_array_elements(r.items) x;
  end loop;
end $$;

create or replace function public.delivery_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'delivery_channels' then perform _require_feature(new.tenant_id, 'delivery');
  elsif new.channel_id is not null then perform _require_feature(new.tenant_id, 'delivery'); end if;
  return new;
end $$;
create trigger delivery_channels_gate before insert on public.delivery_channels for each row execute function public.delivery_gate();
create trigger sales_channel_gate before insert on public.sales for each row when (new.channel_id is not null) execute function public.delivery_gate();

create or replace function public.purchasing_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _require_feature(new.tenant_id, 'purchasing'); return new; end $$;
create trigger po_gate before insert on public.purchase_orders for each row execute function public.purchasing_gate();

create or replace function public.recipes_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _require_feature(new.tenant_id, 'recipes'); return new; end $$;
create trigger recipe_lines_gate before insert on public.recipe_lines for each row execute function public.recipes_gate();

create or replace function public.credit_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.tender = 'on_account' and new.amount > 0 then perform _require_feature(new.tenant_id, 'credit'); end if;
  return new;
end $$;
create trigger payments_credit_gate before insert on public.payments for each row execute function public.credit_gate();

-- ================================================================ shop logo (receipt, invoice, payment page)
do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('branding', 'branding', true, 1048576, array['image/png','image/jpeg','image/webp','image/svg+xml'])
    on conflict (id) do nothing;
    execute $p$create policy branding_write on storage.objects for insert to authenticated
      with check (bucket_id = 'branding' and public.has_perm(((storage.foldername(name))[1])::uuid, 'settings.manage'))$p$;
    execute $p$create policy branding_update on storage.objects for update to authenticated
      using (bucket_id = 'branding' and public.has_perm(((storage.foldername(name))[1])::uuid, 'settings.manage'))$p$;
    execute $p$create policy branding_delete on storage.objects for delete to authenticated
      using (bucket_id = 'branding' and public.has_perm(((storage.foldername(name))[1])::uuid, 'settings.manage'))$p$;
  end if;
end $$;

create or replace function public.payment_link_info(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('amount', k.amount, 'status', k.status, 'expires_at', k.expires_at,
           'currency', t.currency, 'decimals', t.currency_decimals, 'business', t.name, 'business_ar', t.name_ar,
           'number', s.number, 'brand_color', t.brand_color,
           'logo_url', case when coalesce((t.settings->>'logo_show')::boolean, true) then t.logo_url end)
    from payment_links k join sales s on s.id = k.sale_id join tenants t on t.id = k.tenant_id
   where k.token = p_token;
$$;

-- ================================================================ outbound events (webhooks)
create table public.event_types (
  key      text primary key,
  name_en  text not null,
  name_ar  text not null,
  sort     integer not null
);
insert into public.event_types values
  ('sale.completed','Sale completed','اكتمال عملية بيع',1),
  ('refund.created','Refund issued','إصدار مرتجع',2),
  ('order.ready','Kitchen order ready','الطلب جاهز في المطبخ',3),
  ('stock.low','Stock reached reorder point','وصول المخزون لحد إعادة الطلب',4),
  ('shift.closed','Shift closed','إقفال وردية',5),
  ('customer.created','New customer','عميل جديد',6),
  ('payment_link.paid','Payment link paid','دفع رابط الدفع',7);
alter table public.event_types enable row level security;
create policy et_read on public.event_types for select to authenticated using (true);
revoke insert, update, delete on public.event_types from anon, authenticated;

create table public.webhook_endpoints (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  name        text not null,
  url         text not null check (url ~ '^https?://[^\s]+$'),
  secret      text not null,                       -- HMAC key; readable only by the dispatcher (service_role)
  events      text[] not null check (cardinality(events) > 0),
  is_active   boolean not null default true,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  last_status integer,
  last_at     timestamptz,
  failures    integer not null default 0           -- consecutive failed deliveries
);
create index on public.webhook_endpoints(tenant_id) where is_active;

create table public.event_outbox (
  id            bigint generated always as identity primary key,
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  endpoint_id   uuid not null references public.webhook_endpoints(id) on delete cascade,
  event         text not null,
  payload       jsonb not null,
  status        text not null default 'pending' check (status in ('pending','sending','sent','dead')),
  attempts      integer not null default 0,
  next_at       timestamptz not null default now(),
  response_code integer,
  last_error    text,
  created_at    timestamptz not null default now(),
  sent_at       timestamptz
);
create index on public.event_outbox(status, next_at);
create index on public.event_outbox(endpoint_id, id desc);

alter table public.webhook_endpoints enable row level security;
alter table public.event_outbox enable row level security;
create policy we_read on public.webhook_endpoints for select to authenticated using (public.has_perm(tenant_id, 'settings.manage'));
create policy eo_read on public.event_outbox for select to authenticated using (public.has_perm(tenant_id, 'settings.manage'));
revoke insert, update, delete on public.webhook_endpoints, public.event_outbox from anon, authenticated;
-- the signing secret never reaches the browser after creation
revoke select on public.webhook_endpoints from authenticated;
grant select (id, tenant_id, name, url, events, is_active, created_at, last_status, last_at, failures) on public.webhook_endpoints to authenticated;

-- queue one delivery per active endpoint subscribed to the event (only when the integrations module is on)
create or replace function public._emit(p_tenant uuid, p_event text, p_data jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not has_feature(p_tenant, 'integrations') then return 0; end if;
  insert into event_outbox(tenant_id, endpoint_id, event, payload)
  select p_tenant, e.id, p_event,
         jsonb_build_object('event', p_event, 'tenant_id', p_tenant, 'occurred_at', now(), 'data', p_data)
    from webhook_endpoints e
   where e.tenant_id = p_tenant and e.is_active and p_event = any(e.events);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public._emit(uuid, text, jsonb) from public, anon, authenticated;

-- sale/refund: fired at commit so the lines and payments are in place
create or replace function public.emit_sale() returns trigger language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not has_feature(new.tenant_id, 'integrations') then return null; end if;
  select jsonb_build_object('id', s.id, 'number', s.number, 'doc_type', s.doc_type, 'branch_id', s.branch_id, 'branch', b.name,
           'created_at', s.created_at, 'currency', t.currency, 'decimals', t.currency_decimals,
           'subtotal', s.subtotal, 'discount_total', s.discount_total, 'tax_total', s.tax_total, 'total', s.total,
           'original_sale_id', s.original_sale_id, 'external_ref', s.external_ref,
           'customer', (select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone) from customers c where c.id = s.customer_id),
           'lines', (select coalesce(jsonb_agg(jsonb_build_object('item_id', l.item_id, 'name', l.name, 'qty', l.qty, 'line_total', l.line_total) order by l.name), '[]')
                       from sale_lines l where l.sale_id = s.id),
           'payments', (select coalesce(jsonb_agg(jsonb_build_object('tender', p.tender, 'amount', p.amount, 'status', p.status)), '[]')
                          from payments p where p.sale_id = s.id))
    into v
    from sales s join branches b on b.id = s.branch_id join tenants t on t.id = s.tenant_id where s.id = new.id;
  perform _emit(new.tenant_id, case when new.doc_type = 'credit_note' then 'refund.created' else 'sale.completed' end, v);
  return null;
end $$;
create constraint trigger sales_emit after insert on public.sales deferrable initially deferred for each row execute function public.emit_sale();

create or replace function public.emit_kitchen_ready() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'ready' and old.status is distinct from 'ready' then
    perform _emit(new.tenant_id, 'order.ready', jsonb_build_object('ticket_id', new.id, 'order_ref', new.order_ref, 'order_type', new.order_type,
      'table_no', new.table_no, 'customer_name', new.customer_name, 'sale_id', new.sale_id, 'branch_id', new.branch_id, 'ready_at', new.ready_at));
  end if;
  return null;
end $$;
create trigger kitchen_emit after update of status on public.kitchen_tickets for each row execute function public.emit_kitchen_ready();

create or replace function public.emit_shift_closed() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.closed_at is not null and old.closed_at is null then
    perform _emit(new.tenant_id, 'shift.closed', jsonb_build_object('shift_id', new.id, 'branch_id', new.branch_id,
      'opened_at', new.opened_at, 'closed_at', new.closed_at, 'opening_float', new.opening_float,
      'expected_cash', new.expected_cash, 'counted_cash', new.counted_cash, 'variance', new.variance,
      'closed_by', (select display_name from memberships m where m.tenant_id = new.tenant_id and m.user_id = new.closed_by)));
  end if;
  return null;
end $$;
create trigger shifts_emit after update of closed_at on public.shifts for each row execute function public.emit_shift_closed();

create or replace function public.emit_customer() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform _emit(new.tenant_id, 'customer.created', jsonb_build_object('id', new.id, 'name', new.name, 'phone', new.phone, 'email', new.email));
  return null;
end $$;
create trigger customers_emit after insert on public.customers for each row execute function public.emit_customer();

-- stock.low: when a movement takes the balance from above the reorder point to at or below it
create or replace function public.emit_stock_low() returns trigger language plpgsql security definer set search_path = public as $$
declare it items%rowtype; v_after numeric;
begin
  if new.qty >= 0 or not has_feature(new.tenant_id, 'integrations') then return null; end if;
  select * into it from items where id = new.item_id;
  if it.reorder_point is null then return null; end if;
  select coalesce(sum(qty), 0) into v_after from stock_movements where item_id = new.item_id and branch_id = new.branch_id;
  if v_after <= it.reorder_point and v_after - new.qty > it.reorder_point then
    perform _emit(new.tenant_id, 'stock.low', jsonb_build_object('item_id', it.id, 'name', it.name, 'name_ar', it.name_ar, 'sku', it.sku,
      'branch_id', new.branch_id, 'on_hand', v_after, 'reorder_point', it.reorder_point, 'unit', it.unit));
  end if;
  return null;
end $$;
create trigger stock_emit after insert on public.stock_movements for each row execute function public.emit_stock_low();

create or replace function public.emit_link_paid() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    perform _emit(new.tenant_id, 'payment_link.paid', jsonb_build_object('token', new.token, 'sale_id', new.sale_id, 'amount', new.amount,
      'sale_number', (select number from sales where id = new.sale_id)));
  end if;
  return null;
end $$;
create trigger payment_links_emit after update of status on public.payment_links for each row execute function public.emit_link_paid();

-- settings: add / change / remove an endpoint; the secret is returned once, on creation
create or replace function public.save_webhook(p_tenant uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := nullif(p->>'id','')::uuid; v_secret text; v_events text[];
begin
  perform _require(p_tenant, 'settings.manage', null, null);
  perform _require_feature(p_tenant, 'integrations');
  select array_agg(e) into v_events from jsonb_array_elements_text(coalesce(p->'events','[]')) e where e in (select key from event_types);
  if coalesce(cardinality(v_events), 0) = 0 then raise exception 'choose at least one event' using errcode = 'ZT422'; end if;
  if coalesce(p->>'url','') !~ '^https?://[^\s]+$' then raise exception 'enter a full URL starting with https://' using errcode = 'ZT422'; end if;
  if v_id is null then
    v_secret := 'whsec_' || encode(gen_random_bytes(24), 'hex');
    insert into webhook_endpoints(tenant_id, name, url, secret, events, created_by)
    values (p_tenant, coalesce(nullif(p->>'name',''), 'Webhook'), p->>'url', v_secret, v_events, auth.uid()) returning id into v_id;
  else
    update webhook_endpoints set name = coalesce(nullif(p->>'name',''), name), url = p->>'url', events = v_events,
           is_active = coalesce((p->>'is_active')::boolean, is_active),
           failures = case when coalesce((p->>'is_active')::boolean, is_active) and not is_active then 0 else failures end
     where id = v_id and tenant_id = p_tenant;
    if not found then raise exception 'not found' using errcode = '42501'; end if;
  end if;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), 'webhook.save', 'webhook_endpoint', v_id, jsonb_build_object('url', p->>'url', 'events', v_events));
  return jsonb_build_object('id', v_id, 'secret', v_secret);
end $$;

create or replace function public.delete_webhook(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from webhook_endpoints where id = p_id;
  if v_tenant is null then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(v_tenant, 'settings.manage', null, null);
  delete from webhook_endpoints where id = p_id;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id) values (v_tenant, auth.uid(), 'webhook.delete', 'webhook_endpoint', p_id);
end $$;

-- "Send test": queues a ping to one endpoint regardless of its event list
create or replace function public.test_webhook(p_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare e webhook_endpoints%rowtype; v bigint;
begin
  select * into e from webhook_endpoints where id = p_id;
  if not found then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(e.tenant_id, 'settings.manage', null, null);
  insert into event_outbox(tenant_id, endpoint_id, event, payload)
  values (e.tenant_id, e.id, 'ping', jsonb_build_object('event', 'ping', 'tenant_id', e.tenant_id, 'occurred_at', now(),
          'data', jsonb_build_object('message', 'Test from Z Trust', 'endpoint', e.name)))
  returning id into v;
  return v;
end $$;

-- dispatcher (service_role only): claim due deliveries, then report each result
create or replace function public.claim_events(p_limit integer default 50) returns table(id bigint, event text, payload jsonb, url text, secret text, attempts integer)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select o.id from event_outbox o
     where (o.status = 'pending' and o.next_at <= now())
        or (o.status = 'sending' and o.next_at <= now() - interval '5 minutes')     -- a dispatcher that died mid-send
     order by o.id for update skip locked limit p_limit)
  update event_outbox o set status = 'sending', attempts = o.attempts + 1, next_at = now()
    from due, webhook_endpoints e
   where o.id = due.id and e.id = o.endpoint_id
  returning o.id, o.event, o.payload, e.url, e.secret, o.attempts;
end $$;

create or replace function public.finish_event(p_id bigint, p_ok boolean, p_code integer, p_error text) returns void
language plpgsql security definer set search_path = public as $$
declare o event_outbox%rowtype;
  -- retry after 1 min, 5 min, 30 min, 2 h, 12 h; then give up
  v_backoff interval[] := array[interval '1 minute', interval '5 minutes', interval '30 minutes', interval '2 hours', interval '12 hours'];
begin
  select * into o from event_outbox where id = p_id for update;
  if not found then return; end if;
  if p_ok then
    update event_outbox set status = 'sent', sent_at = now(), response_code = p_code, last_error = null where id = p_id;
    update webhook_endpoints set last_status = p_code, last_at = now(), failures = 0 where id = o.endpoint_id;
  else
    update event_outbox set status = case when o.attempts >= 6 then 'dead' else 'pending' end,
           next_at = now() + coalesce(v_backoff[o.attempts], interval '12 hours'), response_code = p_code, last_error = left(p_error, 500)
     where id = p_id;
    -- 50 failures in a row: the endpoint is paused so a dead URL does not pile up work
    update webhook_endpoints set last_status = p_code, last_at = now(), failures = failures + 1,
           is_active = case when failures + 1 >= 50 then false else is_active end
     where id = o.endpoint_id;
  end if;
end $$;
revoke execute on function public.claim_events(integer), public.finish_event(bigint, boolean, integer, text) from public, anon, authenticated;
grant execute on function public.claim_events(integer), public.finish_event(bigint, boolean, integer, text) to service_role;
grant execute on function public.save_webhook(uuid, jsonb), public.delete_webhook(uuid), public.test_webhook(uuid) to authenticated;

-- ================================================================ API keys (read-only for now)
create table public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  name         text not null,
  prefix       text not null unique,          -- shown in the list so a key can be recognised
  key_hash     text not null,                 -- sha256 of the full key
  scopes       text[] not null,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
alter table public.api_keys enable row level security;
create policy ak_read on public.api_keys for select to authenticated using (public.has_perm(tenant_id, 'settings.manage'));
revoke insert, update, delete on public.api_keys from anon, authenticated;
revoke select on public.api_keys from authenticated;
grant select (id, tenant_id, name, prefix, scopes, created_at, last_used_at, revoked_at) on public.api_keys to authenticated;

create or replace function public.create_api_key(p_tenant uuid, p_name text, p_scopes text[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_prefix text := 'ztk_' || encode(gen_random_bytes(4), 'hex'); v_key text; v_id uuid; v_scopes text[];
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can create API keys' using errcode = '42501'; end if;
  perform _require_feature(p_tenant, 'integrations');
  select array_agg(distinct s) into v_scopes from unnest(p_scopes) s where s in ('items.read','stock.read','sales.read','customers.read');
  if coalesce(cardinality(v_scopes), 0) = 0 then raise exception 'choose at least one permission' using errcode = 'ZT422'; end if;
  v_key := v_prefix || '_' || encode(gen_random_bytes(24), 'hex');
  insert into api_keys(tenant_id, name, prefix, key_hash, scopes, created_by)
  values (p_tenant, coalesce(nullif(p_name,''), 'API key'), v_prefix, encode(digest(v_key, 'sha256'), 'hex'), v_scopes, auth.uid()) returning id into v_id;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id, meta)
  values (p_tenant, auth.uid(), 'api_key.create', 'api_key', v_id, jsonb_build_object('name', p_name, 'scopes', v_scopes));
  return jsonb_build_object('id', v_id, 'key', v_key);
end $$;

create or replace function public.revoke_api_key(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from api_keys where id = p_id;
  if v_tenant is null or my_role(v_tenant) is distinct from 'owner' then raise exception 'not allowed' using errcode = '42501'; end if;
  update api_keys set revoked_at = now() where id = p_id and revoked_at is null;
  insert into audit_log(tenant_id, user_id, action, entity, entity_id) values (v_tenant, auth.uid(), 'api_key.revoke', 'api_key', p_id);
end $$;

-- the public-api function calls this with the caller's key; every answer is scoped to that key's business
create or replace function public.api_query(p_key text, p_resource text, p jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k api_keys%rowtype; v_limit integer := least(greatest(coalesce((p->>'limit')::int, 100), 1), 500); v jsonb;
  v_from timestamptz := coalesce((p->>'from')::timestamptz, now() - interval '1 day');
  v_to timestamptz := coalesce((p->>'to')::timestamptz, now());
begin
  select * into k from api_keys where key_hash = encode(digest(coalesce(p_key,''), 'sha256'), 'hex') and revoked_at is null;
  if not found then raise exception 'invalid API key' using errcode = '42501'; end if;
  if not has_feature(k.tenant_id, 'integrations') then raise exception 'integrations are switched off for this business' using errcode = '42501'; end if;
  if not (p_resource || '.read') = any(k.scopes) then raise exception 'this key has no % permission', p_resource || '.read' using errcode = '42501'; end if;
  update api_keys set last_used_at = now() where id = k.id and (last_used_at is null or last_used_at < now() - interval '1 minute');

  if p_resource = 'items' then
    select coalesce(jsonb_agg(x order by x->>'name'), '[]') into v from (
      select jsonb_build_object('id', i.id, 'name', i.name, 'name_ar', i.name_ar, 'sku', i.sku, 'barcode', i.barcode, 'price', i.price,
             'item_type', i.item_type, 'unit', i.unit, 'is_active', i.is_active, 'category', c.name) x
        from items i left join categories c on c.id = i.category_id
       where i.tenant_id = k.tenant_id order by i.name limit v_limit) q;
  elsif p_resource = 'stock' then
    select coalesce(jsonb_agg(x), '[]') into v from (
      select jsonb_build_object('item_id', s.item_id, 'name', s.name, 'sku', s.sku, 'branch_id', s.branch_id, 'on_hand', s.on_hand,
             'reorder_point', s.reorder_point, 'unit', s.unit) x
        from (select i.id as item_id, i.name, i.sku, b.id as branch_id, coalesce(sum(m.qty), 0) as on_hand, i.reorder_point, i.unit
                from items i join branches b on b.tenant_id = i.tenant_id
                left join stock_movements m on m.item_id = i.id and m.branch_id = b.id
               where i.tenant_id = k.tenant_id and i.track_stock and i.item_type <> 'recipe'
               group by i.id, b.id order by i.name limit v_limit) s) q;
  elsif p_resource = 'sales' then
    select coalesce(jsonb_agg(x order by x->>'created_at'), '[]') into v from (
      select jsonb_build_object('id', s.id, 'number', s.number, 'doc_type', s.doc_type, 'branch_id', s.branch_id, 'created_at', s.created_at,
             'status', s.status, 'subtotal', s.subtotal, 'discount_total', s.discount_total, 'tax_total', s.tax_total, 'total', s.total,
             'customer_id', s.customer_id, 'external_ref', s.external_ref,
             'lines', (select coalesce(jsonb_agg(jsonb_build_object('item_id', l.item_id, 'name', l.name, 'qty', l.qty, 'line_total', l.line_total)), '[]')
                         from sale_lines l where l.sale_id = s.id)) x
        from sales s where s.tenant_id = k.tenant_id and s.created_at >= v_from and s.created_at < v_to
       order by s.created_at limit v_limit) q;
  elsif p_resource = 'customers' then
    select coalesce(jsonb_agg(x order by x->>'name'), '[]') into v from (
      select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'email', c.email, 'created_at', c.created_at) x
        from customers c where c.tenant_id = k.tenant_id order by c.name limit v_limit) q;
  else
    raise exception 'unknown resource %', p_resource using errcode = 'ZT422';
  end if;
  return jsonb_build_object('data', v, 'currency', (select currency from tenants where id = k.tenant_id),
                            'decimals', (select currency_decimals from tenants where id = k.tenant_id));
end $$;
grant execute on function public.create_api_key(uuid, text, text[]), public.revoke_api_key(uuid) to authenticated;
grant execute on function public.api_query(text, text, jsonb) to anon, authenticated, service_role;

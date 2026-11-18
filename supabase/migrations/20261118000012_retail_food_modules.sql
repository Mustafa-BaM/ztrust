-- Z Trust · phase B: modifiers, variants, batches & expiry (FEFO), weighed items, promotions & bundles
-- plus: modules a business type can never use are hidden (a fashion shop never sees the kitchen)

-- ================================================================ module availability per business type
alter table public.feature_modules add column universal boolean not null default false;
update public.feature_modules set universal = true
 where key in ('credit','purchasing','integrations','promotions','loyalty','preorders','consignment','quotations');

-- a module is offered to a business when it is universal or listed in its business type
create or replace function public.module_allowed(p_profile text, p_key text) returns boolean
language sql stable set search_path = public as $$
  select coalesce((select universal from feature_modules where key = p_key), false)
      or exists (select 1 from business_profiles where key = p_profile and modules ? p_key);
$$;
grant execute on function public.module_allowed(text, text) to anon, authenticated;

create or replace function public.set_feature(p_tenant uuid, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m feature_modules%rowtype; v_features jsonb; v_profile text;
begin
  if my_role(p_tenant) is distinct from 'owner' then raise exception 'only the owner can switch modules' using errcode = '42501'; end if;
  select * into m from feature_modules where key = p_key;
  if not found then raise exception 'unknown module %', p_key using errcode = 'ZT422'; end if;
  select business_profile into v_profile from tenants where id = p_tenant;
  if p_on and not m.built then raise exception '% is coming soon', m.name_en using errcode = 'ZT422'; end if;
  if p_on and not module_allowed(v_profile, p_key) then
    raise exception '% is not available for this business type', m.name_en using errcode = 'ZT422'; end if;
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

-- ================================================================ items: new kinds and fields
alter table public.items drop constraint if exists items_item_type_check;
alter table public.items add constraint items_item_type_check check (item_type in ('standard','ingredient','recipe','service','package'));
alter table public.items
  add column parent_id      uuid references public.items(id) on delete cascade,   -- variant → its template
  add column is_template    boolean not null default false,                         -- a variant group, never sold itself
  add column variant_attrs  jsonb,                                                  -- {"Size":"M","Colour":"Black"}
  add column sold_by_weight boolean not null default false,
  add column plu            text,                                                   -- scale code (digits)
  add column track_expiry   boolean not null default false,
  add column commission_pct numeric(5,2) check (commission_pct between 0 and 100),
  add column duration_min   integer check (duration_min between 5 and 720);         -- services
create unique index items_plu_uq on public.items(tenant_id, plu) where plu is not null;
create index on public.items(parent_id) where parent_id is not null;

create or replace function public.normalize_item_type() returns trigger language plpgsql as $$
begin
  if new.item_type in ('recipe','service','package') or new.is_template then new.track_stock := false; end if;
  if new.item_type = 'ingredient' then new.track_stock := true; end if;
  if new.item_type = 'service' and new.duration_min is null then new.duration_min := 30; end if;
  return new;
end $$;
drop trigger if exists items_type_guard on public.items;
create trigger items_type_guard before insert or update of item_type, track_stock, is_template on public.items
  for each row execute function public.normalize_item_type();

-- inventory and stock views leave templates out
create or replace view public.v_inventory with (security_invoker = true) as
select i.tenant_id, b.id as branch_id, i.id as item_id, i.name, i.name_ar, i.sku, i.barcode, i.item_type, i.unit, i.cost, i.reorder_point, i.category_id,
       coalesce(sum(m.qty), 0) as on_hand,
       (coalesce(sum(m.qty), 0) * i.cost)::bigint as value,
       max(m.created_at) as last_movement,
       coalesce(sum(-m.qty) filter (where m.reason = 'sale' and m.created_at > now() - interval '30 days'), 0) as used_30d,
       i.parent_id, i.variant_attrs, i.track_expiry
  from public.items i
  join public.branches b on b.tenant_id = i.tenant_id
  left join public.stock_movements m on m.item_id = i.id and m.branch_id = b.id
 where i.track_stock and i.item_type not in ('recipe','service','package') and not i.is_template
 group by i.id, b.id;
grant select on public.v_inventory to authenticated;

-- variants: create the size × colour matrix under a template in one call
-- p = { template_id, attrs: {"Size":["S","M"],"Colour":["Black"]}, price?, cost?, sku_prefix? }
create or replace function public.generate_variants(p jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare tpl items%rowtype; combo jsonb; n int := 0; k text; v_name text; v_sku text; v_id uuid;
begin
  select * into tpl from items where id = (p->>'template_id')::uuid;
  if not found then raise exception 'item not found'; end if;
  perform _require(tpl.tenant_id, 'catalog.manage', null, null);
  perform _require_feature(tpl.tenant_id, 'variants');
  update items set is_template = true where id = tpl.id;
  -- every combination of the attribute values
  for combo in
    with recursive a as (select key, value, row_number() over () rn from jsonb_each(coalesce(p->'attrs','{}'))),
    c(rn, obj) as (
      select 0::bigint, '{}'::jsonb
      union all
      select a.rn, c.obj || jsonb_build_object(a.key, v) from c join a on a.rn = c.rn + 1 cross join jsonb_array_elements_text(a.value) v)
    select obj from c where rn = (select count(*) from a) and rn > 0
  loop
    if exists (select 1 from items where parent_id = tpl.id and variant_attrs = combo) then continue; end if;
    select string_agg(value, ' / ' order by key) into v_name from jsonb_each_text(combo);
    select string_agg(upper(left(regexp_replace(value, '\s', '', 'g'), 3)), '-' order by key) into v_sku from jsonb_each_text(combo);
    insert into items(tenant_id, category_id, name, name_ar, sku, price, cost, tax_rate, track_stock, image_url, parent_id, variant_attrs,
                      item_type, reorder_point, track_expiry, commission_pct)
    values (tpl.tenant_id, tpl.category_id, tpl.name || ' · ' || v_name, case when tpl.name_ar is not null then tpl.name_ar || ' · ' || v_name end,
            case when coalesce(p->>'sku_prefix', tpl.sku) is not null then coalesce(p->>'sku_prefix', tpl.sku) || '-' || v_sku end,
            coalesce((p->>'price')::bigint, tpl.price), coalesce((p->>'cost')::bigint, tpl.cost), tpl.tax_rate, true, tpl.image_url, tpl.id, combo,
            'standard', tpl.reorder_point, tpl.track_expiry, tpl.commission_pct)
    returning id into v_id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ modifiers & add-ons
create table public.modifier_groups (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  name       text not null,
  name_ar    text,
  min_select integer not null default 0 check (min_select >= 0),
  max_select integer not null default 1 check (max_select >= 1),
  sort       integer not null default 0,
  check (max_select >= min_select)
);
create table public.modifier_options (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  group_id   uuid not null references public.modifier_groups(id) on delete cascade,
  name       text not null,
  name_ar    text,
  price      bigint not null default 0 check (price >= 0),        -- added to the item price
  item_id    uuid references public.items(id) on delete set null,  -- optional stock it uses (oat milk, extra cheese)
  qty        numeric(14,4) not null default 0 check (qty >= 0),
  is_active  boolean not null default true,
  sort       integer not null default 0
);
create table public.item_modifier_groups (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  item_id   uuid not null references public.items(id) on delete cascade,
  group_id  uuid not null references public.modifier_groups(id) on delete cascade,
  sort      integer not null default 0,
  primary key (item_id, group_id)
);
alter table public.sale_lines add column modifiers jsonb;          -- [{option_id, name, name_ar, price}]
alter table public.sale_lines add column staff_id uuid;            -- who served (commissions)
alter table public.sale_lines add column promo_id uuid;
alter table public.sale_lines add column promo_discount bigint not null default 0;
alter table public.sale_lines add column customer_package_id uuid;

-- ================================================================ batches & expiry (FEFO)
create table public.stock_batches (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  item_id     uuid not null references public.items(id),
  batch_no    text not null,
  expiry_date date,
  created_at  timestamptz not null default now()
);
create index on public.stock_batches(item_id, branch_id, expiry_date);
create table public.batch_moves (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  batch_id    uuid not null references public.stock_batches(id),
  movement_id bigint not null references public.stock_movements(id),
  qty         numeric(14,3) not null
);
create index on public.batch_moves(batch_id);
create trigger batch_moves_immutable before update or delete on public.batch_moves for each row execute function public.forbid_change();

-- each movement of an expiry-tracked item is split over batches:
--   in  → the batch named in zt.batch_map {item_id: {batch_no, expiry}} (receiving), else the newest batch
--   out → zt.batch_force (write-off of one batch) or first-expiry-first-out over batches with stock
create or replace function public.allocate_batches() returns trigger language plpgsql security definer set search_path = public as $$
declare it items%rowtype; m jsonb; v_batch uuid; v_left numeric; r record; v_take numeric;
begin
  select * into it from items where id = new.item_id;
  if not it.track_expiry then return null; end if;
  if new.qty > 0 then
    m := nullif(current_setting('zt.batch_map', true), '')::jsonb -> new.item_id::text;
    if m is not null and coalesce(m->>'batch_no','') <> '' then
      select id into v_batch from stock_batches where item_id = new.item_id and branch_id = new.branch_id and batch_no = m->>'batch_no'
        and expiry_date is not distinct from nullif(m->>'expiry','')::date;
      if v_batch is null then
        insert into stock_batches(tenant_id, branch_id, item_id, batch_no, expiry_date)
        values (new.tenant_id, new.branch_id, new.item_id, m->>'batch_no', nullif(m->>'expiry','')::date) returning id into v_batch;
      end if;
    else
      select id into v_batch from stock_batches where item_id = new.item_id and branch_id = new.branch_id order by expiry_date desc nulls first, created_at desc limit 1;
      if v_batch is null then
        insert into stock_batches(tenant_id, branch_id, item_id, batch_no, expiry_date)
        values (new.tenant_id, new.branch_id, new.item_id, 'NO-BATCH', null) returning id into v_batch;
      end if;
    end if;
    insert into batch_moves(tenant_id, batch_id, movement_id, qty) values (new.tenant_id, v_batch, new.id, new.qty);
  else
    v_left := -new.qty;
    v_batch := nullif(current_setting('zt.batch_force', true), '')::uuid;
    if v_batch is not null then
      insert into batch_moves(tenant_id, batch_id, movement_id, qty) values (new.tenant_id, v_batch, new.id, new.qty);
      return null;
    end if;
    for r in select b.id, coalesce(sum(bm.qty), 0) as left_qty
               from stock_batches b left join batch_moves bm on bm.batch_id = b.id
              where b.item_id = new.item_id and b.branch_id = new.branch_id
              group by b.id, b.expiry_date, b.created_at having coalesce(sum(bm.qty), 0) > 0
              order by b.expiry_date nulls last, b.created_at loop
      exit when v_left <= 0;
      v_take := least(v_left, r.left_qty);
      insert into batch_moves(tenant_id, batch_id, movement_id, qty) values (new.tenant_id, r.id, new.id, -v_take);
      v_left := v_left - v_take;
    end loop;
  end if;
  return null;
end $$;
create trigger stock_batches_alloc after insert on public.stock_movements for each row execute function public.allocate_batches();

create or replace view public.v_batches with (security_invoker = true) as
select b.id, b.tenant_id, b.branch_id, b.item_id, i.name, i.name_ar, i.unit, i.cost, b.batch_no, b.expiry_date, b.created_at,
       coalesce(sum(bm.qty), 0) as on_hand,
       (b.expiry_date - (now() at time zone br.timezone)::date) as days_left
  from public.stock_batches b join public.items i on i.id = b.item_id join public.branches br on br.id = b.branch_id
  left join public.batch_moves bm on bm.batch_id = b.id
 group by b.id, i.id, br.timezone;
grant select on public.v_batches to authenticated;

-- receiving with batch numbers and expiry dates: p.batches = {item_id: {batch_no, expiry}}
create or replace function public.receive_po_batches(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('zt.batch_map', coalesce(p->'batches', '{}')::text, true);
  return receive_po(p);
end $$;
create or replace function public.receive_stock_batch(p_branch uuid, p_item uuid, p_qty numeric, p_unit_cost bigint, p_note text, p_batch_no text, p_expiry date) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('zt.batch_map', jsonb_build_object(p_item, jsonb_build_object('batch_no', p_batch_no, 'expiry', p_expiry))::text, true);
  perform receive_stock(p_branch, p_item, p_qty, p_unit_cost, p_note);
end $$;
-- write off what is left of one batch (expired, damaged): stock and ledger through adjust_stock
create or replace function public.write_off_batch(p_batch uuid, p_qty numeric, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare b stock_batches%rowtype; v_left numeric;
begin
  select * into b from stock_batches where id = p_batch;
  if not found then raise exception 'batch not found'; end if;
  select coalesce(sum(qty), 0) into v_left from batch_moves where batch_id = p_batch;
  if p_qty <= 0 or p_qty > v_left then raise exception 'you can write off at most %', v_left using errcode = 'ZT422'; end if;
  perform set_config('zt.batch_force', p_batch::text, true);
  perform adjust_stock(b.branch_id, b.item_id, -p_qty, coalesce(nullif(p_reason,''), 'Expired') || ' · ' || b.batch_no);
  perform set_config('zt.batch_force', '', true);
end $$;

-- ================================================================ promotions & bundles
create table public.promotions (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  name        text not null,
  name_ar     text,
  kind        text not null check (kind in ('percent','amount','bxgy','bundle')),
  -- percent: {percent}; amount: {amount, min_amount}; bxgy: {buy, get, percent}; bundle: {price, components:[{item_id, qty}]}
  params      jsonb not null default '{}',
  item_ids    uuid[],                 -- scope (percent, amount, bxgy); both null = everything
  category_ids uuid[],
  min_qty     numeric(14,3) not null default 0,
  coupon_code text,                   -- when set, applies only with this code
  starts_on   date,
  ends_on     date,
  weekdays    integer[],              -- ISO 1 = Monday … 7 = Sunday; null = every day
  time_from   time,
  time_to     time,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index on public.promotions(tenant_id) where is_active;

-- The promotion engine. lines: [{idx, item_id, qty, gross}] (gross = qty × price incl. add-ons, before manual discounts).
-- Returns [{idx, promo_id, discount}]: per line the single best promotion (promotions do not stack on one line).
-- The POS runs the same rules (app/src/lib/promotions.ts); the server caps what the POS claims at this result.
create or replace function public.promo_allowance(p_tenant uuid, p_at timestamptz, p_lines jsonb, p_coupon text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  pr promotions%rowtype; v_tz text; v_local timestamp; best jsonb := '{}'; d jsonb; l jsonb; c jsonb;
  v_q numeric; v_sum bigint; v_disc bigint; v_sets numeric; v_set_value bigint; v_share bigint; v_given bigint;
  v_units jsonb; v_chunk int; v_i int; v_n int; u jsonb;
begin
  select b.timezone into v_tz from branches b where b.tenant_id = p_tenant order by code limit 1;
  v_local := p_at at time zone coalesce(v_tz, 'UTC');
  for pr in select * from promotions where tenant_id = p_tenant and is_active
      and (starts_on is null or v_local::date >= starts_on) and (ends_on is null or v_local::date <= ends_on)
      and (weekdays is null or extract(isodow from v_local)::int = any(weekdays))
      and (time_from is null or v_local::time >= time_from) and (time_to is null or v_local::time < time_to)
      and (coupon_code is null or upper(coupon_code) = upper(coalesce(p_coupon, '')))
  loop
    d := '{}';   -- idx → discount for this promotion
    -- qualifying lines
    with q as (
      select (x->>'idx')::int idx, (x->>'item_id')::uuid item_id, (x->>'qty')::numeric qty, (x->>'gross')::bigint gross, i.category_id, i.parent_id
        from jsonb_array_elements(p_lines) x left join items i on i.id = (x->>'item_id')::uuid
       where pr.kind = 'bundle'
          or (pr.item_ids is null and pr.category_ids is null)
          or (x->>'item_id')::uuid = any(coalesce(pr.item_ids, '{}')) or i.parent_id = any(coalesce(pr.item_ids, '{}'))
          or i.category_id = any(coalesce(pr.category_ids, '{}')))
    select jsonb_agg(jsonb_build_object('idx', idx, 'item_id', item_id, 'qty', qty, 'gross', gross)) into l from q;
    if l is null then continue; end if;
    select coalesce(sum((x->>'qty')::numeric), 0), coalesce(sum((x->>'gross')::bigint), 0) into v_q, v_sum from jsonb_array_elements(l) x;
    if pr.kind <> 'bundle' and v_q < pr.min_qty then continue; end if;

    if pr.kind = 'percent' then
      select jsonb_object_agg(x->>'idx', round((x->>'gross')::bigint * (pr.params->>'percent')::numeric / 100)) into d from jsonb_array_elements(l) x;
    elsif pr.kind = 'amount' then
      if v_sum <= 0 or v_sum < coalesce((pr.params->>'min_amount')::bigint, 0) then continue; end if;
      v_disc := least((pr.params->>'amount')::bigint, v_sum); v_given := 0; v_n := jsonb_array_length(l); v_i := 0;
      for c in select x from jsonb_array_elements(l) x order by (x->>'idx')::int loop
        v_i := v_i + 1;
        v_share := case when v_i = v_n then v_disc - v_given else round(v_disc * (c->>'gross')::bigint / v_sum::numeric) end;
        v_given := v_given + v_share; d := d || jsonb_build_object(c->>'idx', v_share);
      end loop;
    elsif pr.kind = 'bxgy' then
      -- whole units, dearest first; in every group of buy+get units the cheapest "get" units are discounted
      select jsonb_agg(jsonb_build_object('idx', x->>'idx', 'unit', round((x->>'gross')::bigint / (x->>'qty')::numeric)) order by (x->>'gross')::bigint / (x->>'qty')::numeric desc, (x->>'idx')::int)
        into v_units from jsonb_array_elements(l) x cross join generate_series(1, floor((x->>'qty')::numeric)::int);
      v_chunk := (pr.params->>'buy')::int + (pr.params->>'get')::int;
      v_n := coalesce(jsonb_array_length(v_units), 0);
      for v_i in 0 .. (v_n / v_chunk) * v_chunk - 1 loop
        if v_i % v_chunk >= (pr.params->>'buy')::int then
          u := v_units -> v_i;
          d := d || jsonb_build_object(u->>'idx', coalesce((d->>(u->>'idx'))::bigint, 0) + round((u->>'unit')::bigint * coalesce((pr.params->>'percent')::numeric, 100) / 100));
        end if;
      end loop;
    elsif pr.kind = 'bundle' then
      -- complete sets of the components; the saving is spread over the component lines by value
      v_sets := null; v_set_value := 0;
      for c in select * from jsonb_array_elements(pr.params->'components') loop
        select coalesce(sum((x->>'qty')::numeric), 0), coalesce(sum((x->>'gross')::bigint)::numeric / nullif(sum((x->>'qty')::numeric), 0), 0)
          into v_q, v_share from jsonb_array_elements(l) x where (x->>'item_id') = c->>'item_id';
        v_sets := least(coalesce(v_sets, 1e9), floor(v_q / (c->>'qty')::numeric));
        v_set_value := v_set_value + round(v_share * (c->>'qty')::numeric);
      end loop;
      if coalesce(v_sets, 0) < 1 or v_set_value <= (pr.params->>'price')::bigint then continue; end if;
      v_disc := round(v_sets * (v_set_value - (pr.params->>'price')::bigint)); v_given := 0;
      v_n := jsonb_array_length(pr.params->'components'); v_i := 0;
      for c in select * from jsonb_array_elements(pr.params->'components') loop
        v_i := v_i + 1;
        select min((x->>'idx')::int), coalesce(sum((x->>'gross')::bigint)::numeric / nullif(sum((x->>'qty')::numeric), 0), 0)
          into v_n, v_share from jsonb_array_elements(l) x where (x->>'item_id') = c->>'item_id';
        v_share := case when v_i = jsonb_array_length(pr.params->'components') then v_disc - v_given
                        else round(v_disc * v_share * (c->>'qty')::numeric / v_set_value) end;
        v_given := v_given + v_share;
        d := d || jsonb_build_object(v_n::text, coalesce((d->>v_n::text)::bigint, 0) + v_share);
      end loop;
    end if;

    -- keep the best promotion per line
    for c in select jsonb_build_object('k', key, 'v', value) from jsonb_each(coalesce(d, '{}')) loop
      if (c->>'v')::bigint > 0 and (c->>'v')::bigint > coalesce((best->(c->>'k')->>'discount')::bigint, 0) then
        best := best || jsonb_build_object(c->>'k', jsonb_build_object('idx', (c->>'k')::int, 'promo_id', pr.id, 'discount',
                  least((c->>'v')::bigint, (select (x->>'gross')::bigint from jsonb_array_elements(p_lines) x where x->>'idx' = c->>'k'))));
      end if;
    end loop;
  end loop;
  return coalesce((select jsonb_agg(value order by (value->>'idx')::int) from jsonb_each(best)), '[]');
end $$;
grant execute on function public.promo_allowance(uuid, timestamptz, jsonb, text) to authenticated;

-- ================================================================ RLS for the new tables
alter table public.modifier_groups enable row level security;
alter table public.modifier_options enable row level security;
alter table public.item_modifier_groups enable row level security;
alter table public.stock_batches enable row level security;
alter table public.batch_moves enable row level security;
alter table public.promotions enable row level security;
create policy mg_read on public.modifier_groups for select to authenticated using (public.is_member(tenant_id));
create policy mg_write on public.modifier_groups for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy mo_read on public.modifier_options for select to authenticated using (public.is_member(tenant_id));
create policy mo_write on public.modifier_options for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy img_read on public.item_modifier_groups for select to authenticated using (public.is_member(tenant_id));
create policy img_write on public.item_modifier_groups for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy sb_read on public.stock_batches for select to authenticated using (public.has_perm(tenant_id, 'inventory.view') or public.has_perm(tenant_id, 'catalog.manage') or public.has_perm(tenant_id, 'inventory.receive'));
create policy bm_read on public.batch_moves for select to authenticated using (public.has_perm(tenant_id, 'inventory.view') or public.has_perm(tenant_id, 'catalog.manage'));
create policy pr_read on public.promotions for select to authenticated using (public.is_member(tenant_id));
create policy pr_write on public.promotions for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
revoke insert, update, delete on public.stock_batches, public.batch_moves from authenticated;

-- writes to module tables need the module switched on
create or replace function public.module_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _require_feature(new.tenant_id, tg_argv[0]); return new; end $$;
create trigger modifier_groups_gate before insert on public.modifier_groups for each row execute function public.module_gate('modifiers');
create trigger promotions_gate before insert on public.promotions for each row execute function public.module_gate('promotions');

grant execute on function public.generate_variants(jsonb), public.receive_po_batches(jsonb),
  public.receive_stock_batch(uuid, uuid, numeric, bigint, text, text, date), public.write_off_batch(uuid, numeric, text) to authenticated;
revoke execute on function public.allocate_batches(), public.module_gate() from public, anon, authenticated;

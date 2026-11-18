-- Z Trust · Branch Hub (local network kitchen, works without internet)
-- A hub is a small program on one always-on device in the branch (PC, mini-PC, Raspberry Pi).
-- POS and kitchen screens talk to it over the shop Wi-Fi; it prints to network kitchen printers
-- and syncs kitchen tickets to the cloud whenever the internet is available.
-- The hub authenticates with a per-branch token (stored hashed); it never holds a user password.

alter table public.kitchen_stations add column printer_ip text check (printer_ip is null or printer_ip ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$');
alter table public.kitchen_stations add column printer_port integer not null default 9100;
alter table public.kitchen_stations add column printer_width integer not null default 80 check (printer_width in (58, 80));

alter table public.kitchen_tickets add column sale_client_id uuid;
alter table public.kitchen_tickets add column source text not null default 'cloud' check (source in ('cloud','hub'));
create index on public.kitchen_tickets(tenant_id, sale_client_id) where sale_client_id is not null;

create table public.hubs (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  branch_id    uuid not null references public.branches(id) on delete cascade,
  name         text not null,
  token_hash   text not null unique,
  last_seen_at timestamptz,
  last_ip      text,
  version      text,
  is_active    boolean not null default true,
  created_by   uuid not null,
  created_at   timestamptz not null default now()
);
alter table public.hubs enable row level security;
create policy hubs_read on public.hubs for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy hubs_update on public.hubs for update to authenticated
  using (public.has_perm(tenant_id, 'settings.manage')) with check (public.has_perm(tenant_id, 'settings.manage'));
revoke insert, delete on public.hubs from anon, authenticated;

-- returns the token ONCE; only its SHA-256 is stored
create or replace function public.create_hub(p_branch uuid, p_name text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_tenant uuid; v_token text := 'zth_' || encode(gen_random_bytes(24), 'hex');
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if v_tenant is null or not can_see_branch(v_tenant, p_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'settings.manage', null, null);
  insert into hubs(tenant_id, branch_id, name, token_hash, created_by)
  values (v_tenant, p_branch, coalesce(nullif(trim(p_name),''), 'Branch hub'), encode(digest(v_token, 'sha256'), 'hex'), auth.uid());
  perform _audit(v_tenant, p_branch, 'hub.create', 'branch', p_branch, null, p_name, null);
  return v_token;
end $$;

create or replace function public._hub(p_token text) returns public.hubs
language plpgsql security definer set search_path = public, extensions as $$
declare h hubs%rowtype;
begin
  select * into h from hubs where token_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex') and is_active;
  if not found then raise exception 'invalid hub token' using errcode = '42501'; end if;
  return h;
end $$;

-- everything the hub needs to route and print without asking anyone
create or replace function public.hub_config(p_token text, p_version text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h hubs%rowtype := _hub(p_token);
begin
  update hubs set last_seen_at = now(), version = coalesce(p_version, version) where id = h.id;
  return jsonb_build_object(
    'hub', jsonb_build_object('id', h.id, 'name', h.name, 'tenant_id', h.tenant_id, 'branch_id', h.branch_id),
    'tenant', (select jsonb_build_object('name', name, 'name_ar', name_ar, 'currency', currency) from tenants where id = h.tenant_id),
    'branch', (select jsonb_build_object('code', code, 'name', name, 'name_ar', name_ar) from branches where id = h.branch_id),
    'stations', (select coalesce(jsonb_agg(to_jsonb(s) order by s.sort, s.name), '[]') from kitchen_stations s where s.branch_id = h.branch_id and s.is_active),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'station_id', c.station_id)), '[]') from categories c where c.tenant_id = h.tenant_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'category_id', i.category_id, 'name_ar', i.name_ar)), '[]') from items i where i.tenant_id = h.tenant_id and i.is_active));
end $$;

-- p_tickets: [{id, station_id, sale_client_id, order_ref, order_type, table_no, customer_name, note, status,
--              created_at, started_at, ready_at, served_at, items:[{id, name, name_ar, qty, note, done}]}]
-- Idempotent: the hub may resend the same tickets; the latest state wins.
create or replace function public.hub_sync(p_token text, p_tickets jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h hubs%rowtype := _hub(p_token); t jsonb; v_sale uuid; v_number text; n int := 0;
begin
  for t in select * from jsonb_array_elements(coalesce(p_tickets, '[]')) loop
    if not exists (select 1 from kitchen_stations where id = (t->>'station_id')::uuid and branch_id = h.branch_id) then continue; end if;
    select id, number into v_sale, v_number from sales where tenant_id = h.tenant_id and client_id = nullif(t->>'sale_client_id','')::uuid;
    insert into kitchen_tickets(id, tenant_id, branch_id, station_id, sale_id, sale_client_id, order_ref, order_type, table_no,
                                customer_name, note, status, created_at, started_at, ready_at, served_at, source)
    values ((t->>'id')::uuid, h.tenant_id, h.branch_id, (t->>'station_id')::uuid, v_sale, nullif(t->>'sale_client_id','')::uuid,
            case when v_number is not null and coalesce(t->>'order_ref','') like 'OFF-%' then v_number else coalesce(nullif(t->>'order_ref',''), '—') end,
            coalesce(nullif(t->>'order_type',''), 'takeaway'), nullif(t->>'table_no',''),
            nullif(t->>'customer_name',''), nullif(t->>'note',''), coalesce(nullif(t->>'status',''), 'new'),
            coalesce((t->>'created_at')::timestamptz, now()), (t->>'started_at')::timestamptz, (t->>'ready_at')::timestamptz,
            (t->>'served_at')::timestamptz, 'hub')
    on conflict (id) do update set status = excluded.status, started_at = excluded.started_at, ready_at = excluded.ready_at,
           served_at = excluded.served_at, sale_id = coalesce(kitchen_tickets.sale_id, excluded.sale_id),
           order_ref = case when kitchen_tickets.order_ref like 'OFF-%' and excluded.order_ref not like 'OFF-%' then excluded.order_ref
                            when kitchen_tickets.order_ref like 'OFF-%' and v_number is not null then v_number else kitchen_tickets.order_ref end
     where kitchen_tickets.tenant_id = h.tenant_id;
    insert into kitchen_ticket_items(id, tenant_id, ticket_id, name, name_ar, qty, note, done)
    select (i->>'id')::uuid, h.tenant_id, (t->>'id')::uuid, i->>'name', nullif(i->>'name_ar',''), (i->>'qty')::numeric, nullif(i->>'note',''),
           coalesce((i->>'done')::boolean, false)
      from jsonb_array_elements(coalesce(t->'items','[]')) i
    on conflict (id) do update set done = excluded.done;
    n := n + 1;
  end loop;
  update hubs set last_seen_at = now() where id = h.id;
  return jsonb_build_object('synced', n);
end $$;

-- when an offline sale finally reaches the cloud, attach the tickets the hub already synced
create or replace function public.link_hub_tickets() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update kitchen_tickets set sale_id = new.id,
         order_ref = case when order_ref like 'OFF-%' then new.number else order_ref end
   where tenant_id = new.tenant_id and sale_client_id = new.client_id and sale_id is null;
  return new;
end $$;
create trigger sales_link_hub_tickets after insert on public.sales for each row execute function public.link_hub_tickets();

-- with a hub, the kitchen tickets come from the hub (instantly, over the LAN); the cloud must not create duplicates
create or replace function public._kitchen_from_sale(p_sale uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s sales%rowtype; k jsonb := p->'kitchen'; r record; v_ticket uuid; v_default uuid;
begin
  if k is null or jsonb_typeof(k) <> 'object' then return; end if;
  if coalesce((k->>'hub')::boolean, false) then return; end if;
  select * into s from sales where id = p_sale;
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

grant execute on function public.create_hub(uuid, text) to authenticated;
grant execute on function public.hub_config(text, text), public.hub_sync(text, jsonb) to anon, authenticated;
revoke execute on function public._hub(text), public._kitchen_from_sale(uuid, jsonb), public.link_hub_tickets() from public, anon, authenticated;

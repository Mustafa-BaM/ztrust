-- Z Trust · phase C: appointments & calendar (with an online booking page), staff commissions, packages & memberships
create extension if not exists btree_gist with schema extensions;

-- ================================================================ staff who take bookings
alter table public.memberships
  add column bookable       boolean not null default false,
  add column commission_pct numeric(5,2) check (commission_pct between 0 and 100),
  add column color          text;

create table public.staff_hours (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  branch_id  uuid not null references public.branches(id) on delete cascade,
  user_id    uuid not null,
  weekday    integer not null check (weekday between 1 and 7),      -- ISO: 1 Monday … 7 Sunday
  start_time time not null,
  end_time   time not null,
  check (end_time > start_time)
);
create index on public.staff_hours(branch_id, user_id, weekday);

-- public booking page: z-trust.app/book/<slug>
alter table public.tenants add column booking_slug text unique check (booking_slug ~ '^[a-z0-9][a-z0-9-]{2,40}$');

-- ================================================================ appointments
create table public.appointments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  customer_id uuid references public.customers(id),
  staff_id    uuid not null,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  status      text not null default 'booked' check (status in ('booked','confirmed','arrived','in_service','completed','no_show','cancelled')),
  source      text not null default 'staff' check (source in ('staff','online')),
  note        text,
  sale_id     uuid references public.sales(id),
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (ends_at > starts_at),
  -- one person cannot be in two appointments at once
  constraint appointments_no_overlap exclude using gist (staff_id with =, tstzrange(starts_at, ends_at) with &&)
    where (status not in ('cancelled','no_show'))
);
create index on public.appointments(branch_id, starts_at);
create table public.appointment_services (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  item_id        uuid not null references public.items(id),
  name           text not null,
  duration_min   integer not null,
  price          bigint not null
);

alter table public.staff_hours enable row level security;
alter table public.appointments enable row level security;
alter table public.appointment_services enable row level security;
create policy sh_read on public.staff_hours for select to authenticated using (public.is_member(tenant_id));
create policy sh_write on public.staff_hours for all to authenticated using (public.has_perm(tenant_id, 'staff.manage')) with check (public.has_perm(tenant_id, 'staff.manage'));
create policy ap_read on public.appointments for select to authenticated using (public.can_see_branch(tenant_id, branch_id));
create policy aps_read on public.appointment_services for select to authenticated using (public.is_member(tenant_id));
revoke insert, update, delete on public.appointments, public.appointment_services from authenticated;

-- p = { id?, branch_id, customer_id?, customer:{name, phone}?, staff_id, starts_at, service_ids:[uuid], note }
create or replace function public.save_appointment(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_tenant uuid; v_id uuid := nullif(p->>'id','')::uuid; v_cust uuid := nullif(p->>'customer_id','')::uuid;
  v_start timestamptz := (p->>'starts_at')::timestamptz; v_min int;
  -- only book_online may create 'online' bookings (it sets this flag); everyone else books as staff
  v_src text := case when current_setting('zt.online_booking', true) = 'on' then 'online' else 'staff' end;
begin
  select tenant_id into v_tenant from branches where id = v_branch;
  if v_src = 'staff' then
    if v_tenant is null or not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
    perform _require(v_tenant, 'sale.create', null, null);
  end if;
  perform _require_feature(v_tenant, 'appointments');
  if not exists (select 1 from memberships where tenant_id = v_tenant and user_id = (p->>'staff_id')::uuid and is_active and bookable) then
    raise exception 'choose a staff member who takes bookings' using errcode = 'ZT422'; end if;
  select sum(duration_min) into v_min from items where tenant_id = v_tenant and item_type = 'service' and id in (select jsonb_array_elements_text(p->'service_ids')::uuid);
  if v_min is null then raise exception 'choose at least one service' using errcode = 'ZT422'; end if;
  if v_cust is null and coalesce(p->'customer'->>'name','') <> '' then
    select id into v_cust from customers where tenant_id = v_tenant and phone = nullif(p->'customer'->>'phone','');
    if v_cust is null then
      insert into customers(tenant_id, name, phone) values (v_tenant, p->'customer'->>'name', nullif(p->'customer'->>'phone','')) returning id into v_cust;
    end if;
  end if;
  begin
    if v_id is null then
      insert into appointments(tenant_id, branch_id, customer_id, staff_id, starts_at, ends_at, note, source, created_by)
      values (v_tenant, v_branch, v_cust, (p->>'staff_id')::uuid, v_start, v_start + make_interval(mins => v_min), nullif(p->>'note',''), v_src, auth.uid())
      returning id into v_id;
    else
      update appointments set customer_id = v_cust, staff_id = (p->>'staff_id')::uuid, starts_at = v_start, ends_at = v_start + make_interval(mins => v_min),
             note = nullif(p->>'note',''), updated_at = now()
       where id = v_id and tenant_id = v_tenant and status in ('booked','confirmed');
      if not found then raise exception 'this appointment can no longer be changed' using errcode = 'ZT422'; end if;
      delete from appointment_services where appointment_id = v_id;
    end if;
  exception when exclusion_violation then
    raise exception 'This staff member is already booked at that time' using errcode = 'ZT422', hint = 'slot_taken';
  end;
  insert into appointment_services(tenant_id, appointment_id, item_id, name, duration_min, price)
  select v_tenant, v_id, i.id, i.name, i.duration_min, i.price from items i
   where i.tenant_id = v_tenant and i.id in (select jsonb_array_elements_text(p->'service_ids')::uuid);
  return v_id;
end $$;

create or replace function public.set_appointment_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare a appointments%rowtype;
begin
  select * into a from appointments where id = p_id for update;
  if not found or not can_see_branch(a.tenant_id, a.branch_id) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(a.tenant_id, 'sale.create', null, null);
  if p_status not in ('confirmed','arrived','in_service','no_show','cancelled','booked') then raise exception 'unknown status' using errcode = 'ZT422'; end if;
  if a.status = 'completed' then raise exception 'this appointment is already paid' using errcode = 'ZT422'; end if;
  update appointments set status = p_status, updated_at = now() where id = p_id;
end $$;

-- free start times for a staff member (or anyone) on a day, in the branch's local time
create or replace function public._free_slots(p_branch uuid, p_minutes int, p_day date, p_staff uuid default null, p_step int default 15)
returns table(staff_id uuid, starts_at timestamptz)
language sql stable security definer set search_path = public as $$
  with b as (select id, tenant_id, timezone from branches where id = p_branch),
  hrs as (
    select h.user_id, h.start_time, h.end_time from staff_hours h join b on b.id = h.branch_id
      join memberships m on m.tenant_id = h.tenant_id and m.user_id = h.user_id and m.is_active and m.bookable
     where h.weekday = extract(isodow from p_day)::int and (p_staff is null or h.user_id = p_staff)),
  cand as (
    select hrs.user_id, (t at time zone b.timezone) as s
      from hrs cross join b
      cross join generate_series(p_day + hrs.start_time, p_day + hrs.end_time - make_interval(mins => p_minutes), make_interval(mins => p_step)) t)
  select c.user_id, c.s from cand c
   where c.s > now()
     and not exists (select 1 from appointments a where a.staff_id = c.user_id and a.status not in ('cancelled','no_show')
                       and tstzrange(a.starts_at, a.ends_at) && tstzrange(c.s, c.s + make_interval(mins => p_minutes)))
   order by c.s, c.user_id;
$$;

-- ---- the public booking page (no sign-in)
create or replace function public.booking_info(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'business', t.name, 'business_ar', t.name_ar, 'logo_url', t.logo_url, 'brand_color', t.brand_color,
    'currency', t.currency, 'decimals', t.currency_decimals,
    'branches', (select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'name_ar', b.name_ar, 'address', b.address) order by b.code) from branches b where b.tenant_id = t.id and b.is_active),
    'services', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'name_ar', i.name_ar, 'duration_min', i.duration_min, 'price', i.price, 'image_url', i.image_url) order by i.name), '[]')
                   from items i where i.tenant_id = t.id and i.item_type = 'service' and i.is_active),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', m.user_id, 'name', m.display_name, 'color', m.color) order by m.display_name), '[]')
                from memberships m where m.tenant_id = t.id and m.is_active and m.bookable))
  from tenants t where t.booking_slug = lower(p_slug) and has_feature(t.id, 'appointments') and coalesce((t.settings->>'booking_online')::boolean, false);
$$;

create or replace function public.booking_slots(p_slug text, p_branch uuid, p_services uuid[], p_day date, p_staff uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tenant uuid; v_min int;
begin
  select id into v_tenant from tenants where booking_slug = lower(p_slug) and has_feature(id, 'appointments') and coalesce((settings->>'booking_online')::boolean, false);
  if v_tenant is null or not exists (select 1 from branches where id = p_branch and tenant_id = v_tenant) then raise exception 'booking page not found' using errcode = '42501'; end if;
  if p_day > current_date + 60 then return '[]'; end if;
  select sum(duration_min) into v_min from items where tenant_id = v_tenant and item_type = 'service' and is_active and id = any(p_services);
  if v_min is null then return '[]'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('staff_id', staff_id, 'starts_at', starts_at)) from _free_slots(p_branch, v_min, p_day, p_staff)), '[]');
end $$;

-- p = { branch_id, service_ids, staff_id, starts_at, name, phone, note }; at most 3 online bookings per phone per day
create or replace function public.book_online(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_id uuid; v_phone text := regexp_replace(coalesce(p->>'phone',''), '[^0-9+]', '', 'g'); v_min int;
begin
  select id into v_tenant from tenants where booking_slug = lower(p_slug) and has_feature(id, 'appointments') and coalesce((settings->>'booking_online')::boolean, false);
  if v_tenant is null then raise exception 'booking page not found' using errcode = '42501'; end if;
  if length(v_phone) < 7 or coalesce(trim(p->>'name'), '') = '' then raise exception 'enter your name and phone number' using errcode = 'ZT422'; end if;
  if (select count(*) from appointments a join customers c on c.id = a.customer_id
       where a.tenant_id = v_tenant and c.phone = v_phone and a.source = 'online' and a.created_at > now() - interval '1 day') >= 3 then
    raise exception 'too many bookings from this number today; please call the shop' using errcode = 'ZT422'; end if;
  select sum(duration_min) into v_min from items where tenant_id = v_tenant and item_type = 'service' and is_active and id in (select jsonb_array_elements_text(p->'service_ids')::uuid);
  if not exists (select 1 from _free_slots((p->>'branch_id')::uuid, coalesce(v_min, 0), ((p->>'starts_at')::timestamptz at time zone (select timezone from branches where id = (p->>'branch_id')::uuid))::date, (p->>'staff_id')::uuid, 5)
                  where starts_at = (p->>'starts_at')::timestamptz) then
    raise exception 'This time was just taken. Please choose another.' using errcode = 'ZT422', hint = 'slot_taken'; end if;
  perform set_config('zt.online_booking', 'on', true);
  v_id := save_appointment(p || jsonb_build_object('customer', jsonb_build_object('name', trim(p->>'name'), 'phone', v_phone)));
  perform set_config('zt.online_booking', 'off', true);
  perform _emit(v_tenant, 'appointment.booked', jsonb_build_object('appointment_id', v_id, 'starts_at', p->>'starts_at', 'name', trim(p->>'name'), 'phone', v_phone, 'source', 'online'));
  return jsonb_build_object('id', v_id, 'starts_at', p->>'starts_at');
end $$;

insert into public.event_types values
  ('appointment.booked','Appointment booked online','حجز موعد أونلاين',8),
  ('job.ready','Job or pre-order ready','الطلب أو التذكرة جاهزة',9)
on conflict do nothing;

-- ================================================================ commissions
-- rate: the item's own %, else the staff member's %; base: the line's net amount (excl. VAT, after discounts)
create or replace view public.v_commissions with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day, l.staff_id, m.display_name as staff_name,
       l.name as item, case when s.doc_type = 'credit_note' then -l.net_amount else l.net_amount end as net,
       coalesce(i.commission_pct, m.commission_pct, 0) as pct,
       round(case when s.doc_type = 'credit_note' then -l.net_amount else l.net_amount end * coalesce(i.commission_pct, m.commission_pct, 0) / 100)::bigint as commission
  from public.sale_lines l join public.sales s on s.id = l.sale_id join public.branches b on b.id = s.branch_id
  left join public.items i on i.id = l.item_id
  left join public.sale_lines o on o.id = l.original_line_id
  left join public.memberships m on m.tenant_id = s.tenant_id and m.user_id = coalesce(l.staff_id, o.staff_id)
 where coalesce(l.staff_id, o.staff_id) is not null;
grant select on public.v_commissions to authenticated;

-- ================================================================ packages & memberships
-- the package is sold as an item (item_type 'package'); its definition says what it covers
create table public.package_defs (
  item_id       uuid primary key references public.items(id) on delete cascade,
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  kind          text not null default 'sessions' check (kind in ('sessions','unlimited')),
  sessions      integer check (sessions between 1 and 1000),
  validity_days integer not null default 365 check (validity_days between 1 and 3660),
  covers        uuid[]                                       -- service items covered; null = any service
);
create table public.customer_packages (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  customer_id    uuid not null references public.customers(id),
  item_id        uuid not null references public.items(id),
  name           text not null,
  kind           text not null,
  sessions_total integer,
  sessions_used  integer not null default 0,
  price_paid     bigint not null,             -- deferred revenue released session by session
  released       bigint not null default 0,
  covers         uuid[],
  sale_id        uuid references public.sales(id),
  starts_on      date not null default current_date,
  expires_on     date not null,
  status         text not null default 'active' check (status in ('active','used','expired','frozen','refunded')),
  created_at     timestamptz not null default now(),
  check (sessions_total is null or sessions_used <= sessions_total)
);
create index on public.customer_packages(customer_id) where status = 'active';
create table public.package_uses (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  package_id  uuid not null references public.customer_packages(id),
  sale_id     uuid references public.sales(id),
  sessions    integer not null,
  amount      bigint not null,
  used_at     timestamptz not null default now(),
  used_by     uuid
);
alter table public.package_defs enable row level security;
alter table public.customer_packages enable row level security;
alter table public.package_uses enable row level security;
create policy pd_read on public.package_defs for select to authenticated using (public.is_member(tenant_id));
create policy pd_write on public.package_defs for all to authenticated using (public.has_perm(tenant_id, 'catalog.manage')) with check (public.has_perm(tenant_id, 'catalog.manage'));
create policy cp_read on public.customer_packages for select to authenticated using (public.is_member(tenant_id));
create policy pu_read on public.package_uses for select to authenticated using (public.is_member(tenant_id));
revoke insert, update, delete on public.customer_packages, public.package_uses from authenticated;
create trigger package_defs_gate before insert on public.package_defs for each row execute function public.module_gate('memberships');

-- value released per session: the price split evenly, the last session takes the remainder
create or replace function public.package_session_value(p_id uuid, p_sessions int) returns bigint
language sql stable security definer set search_path = public as $$
  select case when c.kind = 'unlimited' then 0
              when c.sessions_used + p_sessions >= c.sessions_total then c.price_paid - c.released
              else (c.price_paid / c.sessions_total) * p_sessions end
    from customer_packages c where c.id = p_id;
$$;

-- unlimited memberships (gym, car wash): record a visit
create or replace function public.use_membership(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c customer_packages%rowtype;
begin
  select * into c from customer_packages where id = p_id for update;
  if not found or not is_member(c.tenant_id) then raise exception 'not found' using errcode = '42501'; end if;
  perform _require(c.tenant_id, 'sale.create', null, null);
  if c.status <> 'active' or c.expires_on < current_date then raise exception 'this membership is not active' using errcode = 'ZT422'; end if;
  if c.kind <> 'unlimited' then raise exception 'use sessions at checkout' using errcode = 'ZT422'; end if;
  insert into package_uses(tenant_id, package_id, sessions, amount, used_by) values (c.tenant_id, c.id, 1, 0, auth.uid());
  return jsonb_build_object('visits', (select count(*) from package_uses where package_id = c.id), 'expires_on', c.expires_on);
end $$;

-- expiry: unused value becomes revenue (breakage); run daily (pg_cron) or on demand
create or replace function public.expire_packages(p_tenant uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare c customer_packages%rowtype; n int := 0; v bigint;
begin
  if auth.uid() is not null and not has_perm(p_tenant, 'finance.view') then raise exception 'not allowed' using errcode = '42501'; end if;
  for c in select * from customer_packages where tenant_id = p_tenant and status = 'active' and expires_on < current_date for update loop
    v := c.price_paid - c.released;
    update customer_packages set status = 'expired', released = price_paid where id = c.id;
    if v > 0 then
      perform _post(c.tenant_id, (select branch_id from sales where id = c.sale_id), 'package_expiry', c.id, c.name, jsonb_build_array(
        jsonb_build_object('key','deferred_revenue','debit', v), jsonb_build_object('key','sales','credit', v)));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

insert into public.coa_template(system_key, code, name_en, name_ar, type, section) values
  ('deferred_revenue', '2250', 'Prepaid packages (deferred revenue)', 'باقات مدفوعة مقدماً (إيراد مؤجل)', 'liability', 'current_liability'),
  ('customer_deposits', '2260', 'Customer deposits', 'عربون العملاء', 'liability', 'current_liability'),
  ('exp_loyalty', '6450', 'Loyalty rewards', 'مكافآت الولاء', 'expense', 'operating_expense')
on conflict (system_key) do nothing;
insert into public.accounts(tenant_id, code, name_en, name_ar, type, system_key)
select t.id, c.code, c.name_en, c.name_ar, c.type, c.system_key from public.tenants t cross join public.coa_template c
 where c.system_key in ('deferred_revenue','customer_deposits','exp_loyalty')
on conflict do nothing;

grant execute on function public.save_appointment(jsonb), public.set_appointment_status(uuid, text), public.use_membership(uuid),
  public.expire_packages(uuid), public.package_session_value(uuid, int) to authenticated;
grant execute on function public.booking_info(text), public.booking_slots(text, uuid, uuid[], date, uuid), public.book_online(text, jsonb) to anon, authenticated;
revoke execute on function public._free_slots(uuid, int, date, uuid, int) from public, anon, authenticated;

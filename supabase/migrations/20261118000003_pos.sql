-- Z Trust MVP · POS money functions, ledger posting, onboarding
-- All money-moving operations are atomic SECURITY DEFINER functions:
--   create_tenant, complete_sale, refund_sale, receive_payment, mark_payment_link_paid,
--   open_shift, close_shift, log_drawer_open, adjust_stock, receive_stock, set_my_pin
-- Errors that the POS turns into a PIN prompt use SQLSTATE 'ZT401' with message 'APPROVAL_REQUIRED:<permission>'.

alter table public.journal_lines add column customer_id uuid references public.customers(id);
create index on public.journal_lines(tenant_id, customer_id) where customer_id is not null;

-- ================================================================ internal helpers
create or replace function public._acct(p_tenant uuid, p_key text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from accounts where tenant_id = p_tenant and system_key = p_key;
  if v is null then raise exception 'missing system account %', p_key; end if;
  return v;
end $$;

-- p_lines: [{"key":"cash","debit":1000}, {"key":"sales","credit":870,"customer_id":"..."}]
create or replace function public._post(p_tenant uuid, p_branch uuid, p_source text, p_source_id uuid,
                                        p_memo text, p_lines jsonb) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_dr bigint := 0; v_cr bigint := 0; v_prev text; v_hash text; v_id bigint; l jsonb;
begin
  -- drop zero lines, check balance
  select coalesce(sum((x->>'debit')::bigint),0), coalesce(sum((x->>'credit')::bigint),0)
    into v_dr, v_cr
    from jsonb_array_elements(p_lines) x;
  if v_dr <> v_cr then
    raise exception 'unbalanced journal: debit % credit %', v_dr, v_cr;
  end if;
  if v_dr = 0 then return null; end if;

  perform pg_advisory_xact_lock(hashtext('je:' || p_tenant::text));
  select hash into v_prev from journal_entries where tenant_id = p_tenant order by id desc limit 1;
  v_hash := encode(digest(coalesce(v_prev,'') || p_source || coalesce(p_source_id::text,'') || p_lines::text || clock_timestamp()::text, 'sha256'), 'hex');

  insert into journal_entries(tenant_id, branch_id, source_type, source_id, memo, prev_hash, hash, created_by)
  values (p_tenant, p_branch, p_source, p_source_id, p_memo, v_prev, v_hash, auth.uid())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'debit')::bigint,0) = 0 and coalesce((l->>'credit')::bigint,0) = 0 then continue; end if;
    insert into journal_lines(tenant_id, entry_id, account_id, branch_id, debit, credit, customer_id)
    values (p_tenant, v_id, _acct(p_tenant, l->>'key'), p_branch,
            coalesce((l->>'debit')::bigint,0), coalesce((l->>'credit')::bigint,0),
            nullif(l->>'customer_id','')::uuid);
  end loop;
  return v_id;
end $$;

create or replace function public._tender_account(p_tender public.tender_type) returns text
language sql immutable as $$
  select case p_tender
    when 'cash' then 'cash'
    when 'card' then 'card_clearing'
    when 'bank_transfer' then 'bank'
    when 'store_credit' then 'store_credit'
    when 'on_account' then 'ar'
    when 'payment_link' then 'ar'
    else 'other_clearing' end;
$$;

-- returns the approver's user id, or null when the caller is allowed on their own.
-- p_value is compared with the permission limit (percent or minor units).
create or replace function public._require(p_tenant uuid, p_perm text, p_value numeric, p_pin text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role public.member_role := my_role(p_tenant);
  v_lim numeric;
  v_approver uuid;
begin
  if v_role is null then raise exception 'not a member of this business' using errcode = '42501'; end if;
  if role_has(p_tenant, v_role, p_perm) then
    v_lim := role_limit(p_tenant, v_role, p_perm);
    if v_lim is null or p_value is null or p_value <= v_lim then return null; end if;
  end if;
  if p_pin is null or length(p_pin) < 4 then
    raise exception 'APPROVAL_REQUIRED:%', p_perm using errcode = 'ZT401';
  end if;
  select m.user_id into v_approver
    from memberships m
   where m.tenant_id = p_tenant and m.is_active and m.pin_hash is not null
     and m.pin_hash = crypt(p_pin, m.pin_hash)
     and role_has(p_tenant, m.role, p_perm)
     and (role_limit(p_tenant, m.role, p_perm) is null or p_value is null
          or p_value <= role_limit(p_tenant, m.role, p_perm))
   limit 1;
  if v_approver is null then
    raise exception 'APPROVAL_DENIED:%', p_perm using errcode = 'ZT403';
  end if;
  return v_approver;
end $$;

create or replace function public._units(p_tenant uuid, p_units numeric) returns bigint
language sql stable security definer set search_path = public as $$
  select (p_units * power(10, currency_decimals))::bigint from tenants where id = p_tenant;
$$;

create or replace function public.customer_balance(p_customer uuid) returns bigint
language sql stable security definer set search_path = public as $$
  -- receivable owed by the customer (positive = customer owes us)
  select coalesce(sum(jl.debit - jl.credit),0)::bigint
    from journal_lines jl join accounts a on a.id = jl.account_id
   where jl.customer_id = p_customer and a.system_key = 'ar'
     and is_member(jl.tenant_id);
$$;

create or replace function public.customer_store_credit(p_customer uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(jl.credit - jl.debit),0)::bigint
    from journal_lines jl join accounts a on a.id = jl.account_id
   where jl.customer_id = p_customer and a.system_key = 'store_credit'
     and is_member(jl.tenant_id);
$$;

create or replace function public._next_number(p_tenant uuid, p_branch uuid, p_doc public.doc_type) returns text
language plpgsql security definer set search_path = public as $$
declare v_no bigint; v_code text;
begin
  insert into doc_sequences(tenant_id, branch_id, doc_type, next_no) values (p_tenant, p_branch, p_doc, 2)
  on conflict (tenant_id, branch_id, doc_type) do update set next_no = doc_sequences.next_no + 1
  returning next_no - 1 into v_no;
  select code into v_code from branches where id = p_branch;
  return v_code || '-' || case p_doc when 'invoice' then 'INV' else 'CN' end || '-' || lpad(v_no::text, 6, '0');
end $$;

create or replace function public._audit(p_tenant uuid, p_branch uuid, p_action text, p_entity text, p_entity_id uuid,
                                         p_amount bigint, p_reason text, p_approver uuid, p_meta jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into audit_log(tenant_id, branch_id, user_id, approved_by, action, entity, entity_id, amount, reason, meta)
  values (p_tenant, p_branch, auth.uid(), p_approver, p_action, p_entity, p_entity_id, p_amount, p_reason, coalesce(p_meta,'{}'));
$$;

create or replace function public.sale_json(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(s) || jsonb_build_object(
    'lines',    (select coalesce(jsonb_agg(to_jsonb(l) order by l.name),'[]') from sale_lines l where l.sale_id = s.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at),'[]') from payments p where p.sale_id = s.id),
    'links',    (select coalesce(jsonb_agg(jsonb_build_object('token',k.token,'amount',k.amount,'status',k.status,'expires_at',k.expires_at)),'[]')
                   from payment_links k where k.sale_id = s.id),
    'customer', (select to_jsonb(c) from customers c where c.id = s.customer_id))
  from sales s where s.id = p_sale and can_see_branch(s.tenant_id, s.branch_id);
$$;

-- ================================================================ onboarding
create or replace function public.create_tenant(p jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  c countries%rowtype;
  v_tenant uuid;
  v_branch uuid;
  u bigint;
begin
  if v_uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into c from countries where code = upper(coalesce(p->>'country_code','')) ;
  if not found then raise exception 'unknown country %', p->>'country_code'; end if;

  insert into tenants(name, name_ar, country_code, currency, currency_decimals, default_language, business_type,
                      tax_number, vat_rate, prices_include_tax, brand_color)
  values (p->>'name', p->>'name_ar', c.code,
          coalesce(nullif(p->>'currency',''), c.currency), c.currency_decimals,
          coalesce(nullif(p->>'language',''), c.default_language),
          coalesce(nullif(p->>'business_type','')::business_type, 'retail'),
          nullif(p->>'tax_number',''),
          coalesce((p->>'vat_rate')::numeric, c.vat_rate),
          coalesce((p->>'prices_include_tax')::boolean, c.prices_include_tax),
          coalesce(nullif(p->>'brand_color',''), '#2346D8'))
  returning id into v_tenant;

  insert into branches(tenant_id, code, name, name_ar, address, timezone)
  values (v_tenant, 'B01', coalesce(nullif(p->>'branch_name',''), 'Main branch'), p->>'branch_name_ar',
          p->>'branch_address', c.timezone)
  returning id into v_branch;

  insert into memberships(tenant_id, user_id, role, display_name, pin_hash)
  values (v_tenant, v_uid, 'owner', coalesce(nullif(p->>'display_name',''), 'Owner'),
          case when length(coalesce(p->>'pin','')) >= 4 then crypt(p->>'pin', gen_salt('bf')) end);

  insert into accounts(tenant_id, code, name_en, name_ar, type, system_key)
  select v_tenant, code, name_en, name_ar, type, system_key from coa_template;

  u := power(10, c.currency_decimals)::bigint;   -- one currency unit in minor units
  insert into role_permissions(tenant_id, role, permission, limit_value) values
    -- manager
    (v_tenant,'manager','sale.create',null),(v_tenant,'manager','sale.discount',30),
    (v_tenant,'manager','sale.refund',null),(v_tenant,'manager','sale.cancel',null),
    (v_tenant,'manager','sale.over_credit',null),(v_tenant,'manager','drawer.no_sale',null),
    (v_tenant,'manager','catalog.manage',null),(v_tenant,'manager','customers.manage',null),
    (v_tenant,'manager','staff.manage',null),(v_tenant,'manager','inventory.adjust',null),
    (v_tenant,'manager','reports.all',null),(v_tenant,'manager','reports.exceptions',null),
    (v_tenant,'manager','reports.costs',null),(v_tenant,'manager','finance.view',null),
    (v_tenant,'manager','shift.view_expected',null),(v_tenant,'manager','payments.receive',null),
    -- supervisor
    (v_tenant,'supervisor','sale.create',null),(v_tenant,'supervisor','sale.discount',15),
    (v_tenant,'supervisor','sale.refund',50*u),(v_tenant,'supervisor','sale.cancel',50*u),
    (v_tenant,'supervisor','drawer.no_sale',null),(v_tenant,'supervisor','customers.manage',null),
    (v_tenant,'supervisor','inventory.adjust',null),(v_tenant,'supervisor','shift.view_expected',null),
    (v_tenant,'supervisor','payments.receive',null),
    -- cashier
    (v_tenant,'cashier','sale.create',null),(v_tenant,'cashier','sale.discount',5),
    (v_tenant,'cashier','sale.refund',10*u),(v_tenant,'cashier','payments.receive',null),
    -- accountant
    (v_tenant,'accountant','finance.view',null),(v_tenant,'accountant','reports.all',null),
    (v_tenant,'accountant','reports.exceptions',null),(v_tenant,'accountant','reports.costs',null),
    (v_tenant,'accountant','payments.receive',null);

  return v_tenant;
end $$;

create or replace function public.set_my_pin(p_tenant uuid, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'PIN must be 4 to 6 digits'; end if;
  update memberships set pin_hash = crypt(p_pin, gen_salt('bf'))
   where tenant_id = p_tenant and user_id = auth.uid();
  if not found then raise exception 'not a member' using errcode = '42501'; end if;
end $$;

-- ================================================================ shifts
create or replace function public.open_shift(p_branch uuid, p_float bigint) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_id uuid;
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if v_tenant is null or not can_see_branch(v_tenant, p_branch) then raise exception 'branch not allowed' using errcode='42501'; end if;
  perform _require(v_tenant, 'sale.create', null, null);
  select id into v_id from shifts where branch_id = p_branch and opened_by = auth.uid() and closed_at is null;
  if v_id is not null then return v_id; end if;
  insert into shifts(tenant_id, branch_id, opened_by, opening_float) values (v_tenant, p_branch, auth.uid(), greatest(p_float,0))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.shift_summary(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s shifts%rowtype; v jsonb; v_show boolean;
begin
  select * into s from shifts where id = p_shift;
  if not found or not can_see_branch(s.tenant_id, s.branch_id) then raise exception 'shift not found'; end if;
  v_show := s.closed_at is not null or has_perm(s.tenant_id, 'shift.view_expected');
  select jsonb_build_object(
    'shift', to_jsonb(s) - case when v_show then 'x' else 'expected_cash' end,
    'invoices', (select count(*) from sales where shift_id = s.id and doc_type='invoice'),
    'credit_notes', (select count(*) from sales where shift_id = s.id and doc_type='credit_note'),
    'sales_total', (select coalesce(sum(total),0) from sales where shift_id = s.id and doc_type='invoice'),
    'refunds_total', (select coalesce(sum(total),0) from sales where shift_id = s.id and doc_type='credit_note'),
    'tax_total', (select coalesce(sum(case when doc_type='invoice' then tax_total else -tax_total end),0) from sales where shift_id = s.id),
    'tenders', (select coalesce(jsonb_object_agg(tender, amt),'{}') from
                 (select p.tender, sum(p.amount) amt from payments p where p.shift_id = s.id group by p.tender) t),
    'expected_cash', case when v_show then s.opening_float + (select coalesce(sum(amount),0) from payments
                        where shift_id = s.id and tender='cash' and status='captured') end
  ) into v;
  return v;
end $$;

create or replace function public.close_shift(p_shift uuid, p_counted bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s shifts%rowtype; v_expected bigint; v_var bigint;
begin
  select * into s from shifts where id = p_shift for update;
  if not found or not can_see_branch(s.tenant_id, s.branch_id) then raise exception 'shift not found'; end if;
  if s.closed_at is not null then raise exception 'shift already closed'; end if;
  if s.opened_by <> auth.uid() then perform _require(s.tenant_id, 'shift.view_expected', null, null); end if;

  v_expected := s.opening_float + (select coalesce(sum(amount),0) from payments
                 where shift_id = s.id and tender = 'cash' and status = 'captured');
  v_var := p_counted - v_expected;
  update shifts set closed_at = now(), closed_by = auth.uid(), expected_cash = v_expected,
                    counted_cash = p_counted, variance = v_var where id = s.id;
  if v_var <> 0 then
    perform _post(s.tenant_id, s.branch_id, 'shift_variance', s.id, 'Cash over/short',
      case when v_var > 0
        then jsonb_build_array(jsonb_build_object('key','cash','debit',v_var), jsonb_build_object('key','cash_over_short','credit',v_var))
        else jsonb_build_array(jsonb_build_object('key','cash_over_short','debit',-v_var), jsonb_build_object('key','cash','credit',-v_var)) end);
    perform _audit(s.tenant_id, s.branch_id, 'shift.variance', 'shift', s.id, v_var, null, null);
  end if;
  return shift_summary(s.id);
end $$;

create or replace function public.log_drawer_open(p_branch uuid, p_reason text, p_pin text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_appr uuid;
begin
  select tenant_id into v_tenant from branches where id = p_branch;
  if coalesce(trim(p_reason),'') = '' then raise exception 'reason required'; end if;
  v_appr := _require(v_tenant, 'drawer.no_sale', null, p_pin);
  perform _audit(v_tenant, p_branch, 'drawer.no_sale', 'branch', p_branch, null, p_reason, v_appr);
end $$;

-- ================================================================ sale
-- p = {
--   tenant_id, branch_id, shift_id?, client_id, customer_id?, device_created_at?, approver_pin?, note?,
--   lines: [{ item_id?, name?, qty, unit_price?, discount? }],
--   payments: [{ tender, amount, reference? }]
-- }
create or replace function public.complete_sale(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t tenants%rowtype;
  v_branch uuid := (p->>'branch_id')::uuid;
  v_shift uuid := nullif(p->>'shift_id','')::uuid;
  v_client uuid := (p->>'client_id')::uuid;
  v_customer uuid := nullif(p->>'customer_id','')::uuid;
  v_existing uuid; v_sale uuid; v_number text; v_appr uuid;
  l jsonb; it items%rowtype; pay jsonb;
  v_qty numeric; v_price bigint; v_disc bigint; v_rate numeric; v_gross bigint; v_tax bigint; v_net bigint; v_total_line bigint;
  v_list bigint := 0; v_discount_total bigint := 0;
  v_sub bigint := 0; v_taxsum bigint := 0; v_total bigint := 0; v_cogs bigint := 0;
  v_paysum bigint := 0; v_captured bigint := 0; v_credit_use bigint := 0; v_sc_use bigint := 0;
  v_lines jsonb := '[]'; v_je jsonb := '[]'; v_pid uuid; v_tender tender_type; v_amt bigint;
begin
  select * into t from tenants where id = (p->>'tenant_id')::uuid;
  if not found or not is_member(t.id) then raise exception 'not a member of this business' using errcode = '42501'; end if;
  if not can_see_branch(t.id, v_branch) or not exists (select 1 from branches where id = v_branch and tenant_id = t.id) then
    raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(t.id, 'sale.create', null, null);

  -- idempotency: replays from the offline outbox return the original sale
  select id into v_existing from sales where tenant_id = t.id and client_id = v_client;
  if v_existing is not null then return sale_json(v_existing); end if;

  if v_shift is not null and not exists (select 1 from shifts where id = v_shift and branch_id = v_branch and closed_at is null) then
    v_shift := null;   -- shift closed while offline: keep the sale, detach from the shift
  end if;
  if v_customer is not null and not exists (select 1 from customers where id = v_customer and tenant_id = t.id) then
    raise exception 'unknown customer'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'empty sale'; end if;

  -- ---- price lines
  for l in select * from jsonb_array_elements(p->'lines') loop
    it := null;
    if nullif(l->>'item_id','') is not null then
      select * into it from items where id = (l->>'item_id')::uuid and tenant_id = t.id;
      if not found then raise exception 'unknown item %', l->>'item_id'; end if;
    end if;
    v_qty   := (l->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'quantity must be positive'; end if;
    v_price := coalesce((l->>'unit_price')::bigint, it.price, 0);
    v_disc  := coalesce((l->>'discount')::bigint, 0);
    if v_price < 0 or v_disc < 0 then raise exception 'negative price or discount'; end if;
    v_gross := round(v_qty * v_price)::bigint - v_disc;
    if v_gross < 0 then raise exception 'discount larger than line'; end if;
    v_rate  := coalesce(it.tax_rate, t.vat_rate);
    if t.prices_include_tax then
      v_tax := round(v_gross * v_rate / (100 + v_rate))::bigint; v_net := v_gross - v_tax; v_total_line := v_gross;
    else
      v_net := v_gross; v_tax := round(v_net * v_rate / 100)::bigint; v_total_line := v_net + v_tax;
    end if;
    v_list := v_list + round(v_qty * coalesce(it.price, v_price))::bigint;
    v_discount_total := v_discount_total + v_disc + greatest(round(v_qty * (coalesce(it.price, v_price) - v_price))::bigint, 0);
    v_sub := v_sub + v_net; v_taxsum := v_taxsum + v_tax; v_total := v_total + v_total_line;
    if it.id is not null and it.track_stock then v_cogs := v_cogs + round(v_qty * it.cost)::bigint; end if;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'name', coalesce(nullif(l->>'name',''), it.name, 'Item'),
      'qty', v_qty, 'unit_price', v_price, 'discount', v_disc, 'tax_rate', v_rate, 'net', v_net, 'tax', v_tax,
      'total', v_total_line, 'unit_cost', coalesce(it.cost,0), 'track', coalesce(it.track_stock,false));
  end loop;

  -- ---- discount / price override approval
  if v_discount_total > 0 then
    v_appr := _require(t.id, 'sale.discount', round(v_discount_total * 100.0 / nullif(v_list,0), 2), p->>'approver_pin');
  end if;

  -- ---- tenders
  for pay in select * from jsonb_array_elements(coalesce(p->'payments','[]')) loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    if v_amt is null or v_amt <= 0 then raise exception 'payment amounts must be positive'; end if;
    v_paysum := v_paysum + v_amt;
    if v_tender in ('on_account','payment_link','store_credit') and v_customer is null then
      raise exception 'choose a customer for % payments', v_tender; end if;
    if v_tender = 'on_account' then v_credit_use := v_credit_use + v_amt; end if;
    if v_tender = 'store_credit' then v_sc_use := v_sc_use + v_amt; end if;
  end loop;
  if v_paysum <> v_total then
    raise exception 'payments (%) must equal the total (%)', v_paysum, v_total using errcode = 'ZT422'; end if;
  if v_credit_use > 0 and customer_balance(v_customer) + v_credit_use > (select credit_limit from customers where id = v_customer) then
    v_appr := coalesce(_require(t.id, 'sale.over_credit', null, p->>'approver_pin'), v_appr);
  end if;
  if v_sc_use > customer_store_credit(v_customer) then raise exception 'not enough store credit'; end if;

  -- ---- write documents
  v_number := _next_number(t.id, v_branch, 'invoice');
  insert into sales(tenant_id, branch_id, shift_id, client_id, doc_type, number, customer_id, subtotal, discount_total,
                    tax_total, total, paid_total, approved_by, created_by, device_created_at, reason)
  values (t.id, v_branch, v_shift, v_client, 'invoice', v_number, v_customer, v_sub, v_discount_total, v_taxsum, v_total, 0,
          v_appr, auth.uid(), nullif(p->>'device_created_at','')::timestamptz, nullif(p->>'note',''))
  returning id into v_sale;

  for l in select * from jsonb_array_elements(v_lines) loop
    insert into sale_lines(tenant_id, sale_id, item_id, name, qty, unit_price, discount, tax_rate, net_amount, tax_amount, line_total, unit_cost)
    values (t.id, v_sale, nullif(l->>'item_id','')::uuid, l->>'name', (l->>'qty')::numeric, (l->>'unit_price')::bigint,
            (l->>'discount')::bigint, (l->>'tax_rate')::numeric, (l->>'net')::bigint, (l->>'tax')::bigint, (l->>'total')::bigint,
            (l->>'unit_cost')::bigint);
    if (l->>'track')::boolean then
      insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, created_by)
      values (t.id, v_branch, (l->>'item_id')::uuid, -(l->>'qty')::numeric, 'sale', v_sale, (l->>'unit_cost')::bigint, auth.uid());
    end if;
  end loop;

  for pay in select * from jsonb_array_elements(p->'payments') loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    insert into payments(tenant_id, sale_id, tender, amount, reference, status, shift_id, created_by)
    values (t.id, v_sale, v_tender, v_amt, nullif(pay->>'reference',''),
            case when v_tender in ('payment_link') then 'pending' else 'captured' end, v_shift, auth.uid())
    returning id into v_pid;
    if v_tender = 'payment_link' then
      insert into payment_links(tenant_id, sale_id, payment_id, amount) values (t.id, v_sale, v_pid, v_amt);
    end if;
    if v_tender not in ('on_account','payment_link') then v_captured := v_captured + v_amt; end if;
    v_je := v_je || jsonb_build_object('key', _tender_account(v_tender), 'debit', v_amt,
              'customer_id', case when v_tender in ('on_account','payment_link','store_credit') then v_customer end);
  end loop;
  update sales set paid_total = v_captured where id = v_sale;

  v_je := v_je || jsonb_build_array(
    jsonb_build_object('key','sales','credit', v_sub),
    jsonb_build_object('key','vat_payable','credit', v_taxsum),
    jsonb_build_object('key','cogs','debit', v_cogs),
    jsonb_build_object('key','inventory','credit', v_cogs));
  perform _post(t.id, v_branch, 'sale', v_sale, v_number, v_je);

  if v_discount_total > 0 then
    perform _audit(t.id, v_branch, 'sale.discount', 'sale', v_sale, v_discount_total, nullif(p->>'note',''), v_appr,
                   jsonb_build_object('percent', round(v_discount_total * 100.0 / nullif(v_list,0), 2)));
  end if;
  return sale_json(v_sale);
end $$;

-- ================================================================ refund / cancel
-- p = { sale_id, client_id, tender, reason, approver_pin?, shift_id?, cancel?: bool,
--       lines?: [{ line_id, qty }]   (omit = everything still refundable) }
create or replace function public.refund_sale(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o sales%rowtype; ol sale_lines%rowtype;
  v_cancel boolean := coalesce((p->>'cancel')::boolean, false);
  v_tender tender_type := coalesce(nullif(p->>'tender',''),'cash')::tender_type;
  v_reason text := nullif(trim(coalesce(p->>'reason','')),'');
  v_shift uuid := nullif(p->>'shift_id','')::uuid;
  v_existing uuid; v_cn uuid; v_number text; v_appr uuid;
  v_req numeric; v_done numeric; v_q numeric;
  v_net bigint; v_tax bigint; v_tot bigint;
  v_sub bigint := 0; v_taxsum bigint := 0; v_total bigint := 0; v_cogs bigint := 0;
  v_rows jsonb := '[]'; r jsonb;
begin
  select * into o from sales where id = (p->>'sale_id')::uuid for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'sale not found'; end if;
  if o.doc_type <> 'invoice' then raise exception 'only invoices can be refunded'; end if;
  if v_reason is null then raise exception 'a reason is required' using errcode = 'ZT422'; end if;

  select id into v_existing from sales where tenant_id = o.tenant_id and client_id = (p->>'client_id')::uuid;
  if v_existing is not null then return sale_json(v_existing); end if;

  if v_tender = 'payment_link' then raise exception 'refunds cannot go to a payment link'; end if;
  if v_tender in ('on_account','store_credit') and o.customer_id is null then
    raise exception 'this sale has no customer; refund in cash or card'; end if;
  if o.paid_total < o.total and v_tender <> 'on_account' then
    raise exception 'the sale is not fully paid; refund to the customer account' using errcode = 'ZT422'; end if;
  if v_shift is not null and not exists (select 1 from shifts where id = v_shift and closed_at is null) then v_shift := null; end if;

  for ol in select * from sale_lines where sale_id = o.id loop
    select coalesce(sum(x.qty),0) into v_done from sale_lines x where x.original_line_id = ol.id;
    if p ? 'lines' and not v_cancel then
      select (e->>'qty')::numeric into v_req from jsonb_array_elements(p->'lines') e where (e->>'line_id')::uuid = ol.id;
      if v_req is null then continue; end if;
    else
      v_req := ol.qty - v_done;
    end if;
    if v_req <= 0 then continue; end if;
    if v_req > ol.qty - v_done then raise exception 'cannot refund more than sold for %', ol.name; end if;
    v_q := v_req / ol.qty;
    v_net := round(ol.net_amount * v_q)::bigint; v_tax := round(ol.tax_amount * v_q)::bigint; v_tot := v_net + v_tax;
    v_sub := v_sub + v_net; v_taxsum := v_taxsum + v_tax; v_total := v_total + v_tot;
    if ol.item_id is not null and exists (select 1 from items where id = ol.item_id and track_stock) then
      v_cogs := v_cogs + round(v_req * ol.unit_cost)::bigint;
    end if;
    v_rows := v_rows || jsonb_build_object('line', to_jsonb(ol), 'qty', v_req, 'net', v_net, 'tax', v_tax, 'total', v_tot);
  end loop;
  if v_total <= 0 then raise exception 'nothing left to refund'; end if;

  v_appr := _require(o.tenant_id, case when v_cancel then 'sale.cancel' else 'sale.refund' end, v_total, p->>'approver_pin');

  v_number := _next_number(o.tenant_id, o.branch_id, 'credit_note');
  insert into sales(tenant_id, branch_id, shift_id, client_id, doc_type, number, original_sale_id, customer_id,
                    subtotal, discount_total, tax_total, total, paid_total, reason, approved_by, created_by)
  values (o.tenant_id, o.branch_id, v_shift, (p->>'client_id')::uuid, 'credit_note', v_number, o.id, o.customer_id,
          v_sub, 0, v_taxsum, v_total, case when v_tender = 'on_account' then 0 else v_total end, v_reason, v_appr, auth.uid())
  returning id into v_cn;

  for r in select * from jsonb_array_elements(v_rows) loop
    insert into sale_lines(tenant_id, sale_id, original_line_id, item_id, name, qty, unit_price, discount, tax_rate,
                           net_amount, tax_amount, line_total, unit_cost)
    values (o.tenant_id, v_cn, (r->'line'->>'id')::uuid, nullif(r->'line'->>'item_id','')::uuid, r->'line'->>'name',
            (r->>'qty')::numeric, (r->'line'->>'unit_price')::bigint, 0, (r->'line'->>'tax_rate')::numeric,
            (r->>'net')::bigint, (r->>'tax')::bigint, (r->>'total')::bigint, (r->'line'->>'unit_cost')::bigint);
    if nullif(r->'line'->>'item_id','') is not null and exists (select 1 from items where id = (r->'line'->>'item_id')::uuid and track_stock) then
      insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, created_by)
      values (o.tenant_id, o.branch_id, (r->'line'->>'item_id')::uuid, (r->>'qty')::numeric, 'refund', v_cn,
              (r->'line'->>'unit_cost')::bigint, auth.uid());
    end if;
  end loop;

  insert into payments(tenant_id, sale_id, tender, amount, status, shift_id, created_by)
  values (o.tenant_id, v_cn, v_tender, -v_total, 'captured', v_shift, auth.uid());

  perform _post(o.tenant_id, o.branch_id, case when v_cancel then 'cancel' else 'refund' end, v_cn, v_number,
    jsonb_build_array(
      jsonb_build_object('key','sales','debit', v_sub),
      jsonb_build_object('key','vat_payable','debit', v_taxsum),
      jsonb_build_object('key', _tender_account(v_tender), 'credit', v_total,
                         'customer_id', case when v_tender in ('on_account','store_credit') then o.customer_id end),
      jsonb_build_object('key','inventory','debit', v_cogs),
      jsonb_build_object('key','cogs','credit', v_cogs)));

  update sales set refunded_total = refunded_total + v_total,
                   status = case when v_cancel then 'cancelled'
                                 when refunded_total + v_total >= total then 'refunded'
                                 else 'partially_refunded' end
   where id = o.id;

  perform _audit(o.tenant_id, o.branch_id, case when v_cancel then 'sale.cancel' else 'sale.refund' end, 'sale', o.id,
                 v_total, v_reason, v_appr, jsonb_build_object('credit_note', v_number, 'tender', v_tender,
                 'same_shift', o.shift_id is not distinct from v_shift));
  return sale_json(v_cn);
end $$;

-- ================================================================ collections
create or replace function public.receive_payment(p_sale uuid, p_tender public.tender_type, p_amount bigint, p_reference text default null,
                                                  p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o sales%rowtype;
begin
  select * into o from sales where id = p_sale for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'sale not found'; end if;
  perform _require(o.tenant_id, 'payments.receive', null, null);
  if p_tender in ('on_account','payment_link') then raise exception 'choose a real tender'; end if;
  if p_amount <= 0 or p_amount > o.total - o.paid_total - o.refunded_total then raise exception 'amount exceeds the balance due'; end if;
  insert into payments(tenant_id, sale_id, tender, amount, reference, status, shift_id, created_by)
  values (o.tenant_id, o.id, p_tender, p_amount, p_reference, 'captured', p_shift, auth.uid());
  update sales set paid_total = paid_total + p_amount where id = o.id;
  perform _post(o.tenant_id, o.branch_id, 'collection', o.id, o.number, jsonb_build_array(
    jsonb_build_object('key', _tender_account(p_tender), 'debit', p_amount),
    jsonb_build_object('key','ar','credit', p_amount, 'customer_id', o.customer_id)));
  return sale_json(o.id);
end $$;

create or replace function public.create_payment_link(p_sale uuid, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o sales%rowtype; v_pid uuid; v_link payment_links%rowtype;
begin
  select * into o from sales where id = p_sale for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'sale not found'; end if;
  perform _require(o.tenant_id, 'payments.receive', null, null);
  if p_amount <= 0 or p_amount > o.total - o.paid_total - o.refunded_total
     - (select coalesce(sum(amount),0) from payment_links where sale_id = o.id and status = 'pending') then
    raise exception 'amount exceeds the open balance'; end if;
  insert into payments(tenant_id, sale_id, tender, amount, status, created_by)
  values (o.tenant_id, o.id, 'payment_link', p_amount, 'pending', auth.uid()) returning id into v_pid;
  insert into payment_links(tenant_id, sale_id, payment_id, amount) values (o.tenant_id, o.id, v_pid, p_amount)
  returning * into v_link;
  return to_jsonb(v_link);
end $$;

-- called only by the payment gateway webhook (service role)
create or replace function public.mark_payment_link_paid(p_token text, p_gateway_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k payment_links%rowtype; o sales%rowtype;
begin
  select * into k from payment_links where token = p_token for update;
  if not found then raise exception 'unknown link'; end if;
  if k.status = 'paid' then return to_jsonb(k); end if;
  if k.status <> 'pending' then raise exception 'link is %', k.status; end if;
  select * into o from sales where id = k.sale_id for update;
  update payment_links set status = 'paid', paid_at = now(), gateway_ref = p_gateway_ref where id = k.id returning * into k;
  update payments set status = 'captured', reference = p_gateway_ref where id = k.payment_id;
  update sales set paid_total = paid_total + k.amount where id = o.id;
  perform _post(o.tenant_id, o.branch_id, 'payment_link', o.id, o.number, jsonb_build_array(
    jsonb_build_object('key','gateway_clearing','debit', k.amount),
    jsonb_build_object('key','ar','credit', k.amount, 'customer_id', o.customer_id)));
  return to_jsonb(k);
end $$;

-- public lookup for the hosted payment page (no login)
create or replace function public.payment_link_info(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('amount', k.amount, 'status', k.status, 'expires_at', k.expires_at,
           'currency', t.currency, 'decimals', t.currency_decimals, 'business', t.name, 'business_ar', t.name_ar,
           'number', s.number, 'brand_color', t.brand_color)
    from payment_links k join sales s on s.id = k.sale_id join tenants t on t.id = k.tenant_id
   where k.token = p_token;
$$;

-- ================================================================ stock
create or replace function public.adjust_stock(p_branch uuid, p_item uuid, p_qty numeric, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare it items%rowtype; v_val bigint;
begin
  select * into it from items where id = p_item;
  if not found or not can_see_branch(it.tenant_id, p_branch) then raise exception 'not allowed' using errcode='42501'; end if;
  perform _require(it.tenant_id, 'inventory.adjust', null, null);
  if p_qty = 0 then return; end if;
  insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost, note, created_by)
  values (it.tenant_id, p_branch, p_item, p_qty, 'adjustment', it.cost, p_note, auth.uid());
  v_val := abs(round(p_qty * it.cost))::bigint;
  perform _post(it.tenant_id, p_branch, 'stock_adjustment', p_item, coalesce(p_note, it.name),
    case when p_qty > 0
      then jsonb_build_array(jsonb_build_object('key','inventory','debit',v_val), jsonb_build_object('key','inventory_adjustments','credit',v_val))
      else jsonb_build_array(jsonb_build_object('key','inventory_adjustments','debit',v_val), jsonb_build_object('key','inventory','credit',v_val)) end);
  perform _audit(it.tenant_id, p_branch, 'inventory.adjust', 'item', p_item, v_val, p_note, null, jsonb_build_object('qty', p_qty));
end $$;

-- goods received from a supplier; updates moving-average cost
create or replace function public.receive_stock(p_branch uuid, p_item uuid, p_qty numeric, p_unit_cost bigint, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare it items%rowtype; v_onhand numeric; v_val bigint;
begin
  select * into it from items where id = p_item for update;
  if not found or not can_see_branch(it.tenant_id, p_branch) then raise exception 'not allowed' using errcode='42501'; end if;
  perform _require(it.tenant_id, 'inventory.adjust', null, null);
  if p_qty <= 0 or p_unit_cost < 0 then raise exception 'quantity must be positive'; end if;
  select coalesce(sum(qty),0) into v_onhand from stock_movements where item_id = p_item;
  update items set cost = case when greatest(v_onhand,0) + p_qty = 0 then p_unit_cost
                   else round((greatest(v_onhand,0) * it.cost + p_qty * p_unit_cost) / (greatest(v_onhand,0) + p_qty)) end
   where id = p_item;
  insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost, note, created_by)
  values (it.tenant_id, p_branch, p_item, p_qty, 'receipt', p_unit_cost, p_note, auth.uid());
  v_val := round(p_qty * p_unit_cost)::bigint;
  perform _post(it.tenant_id, p_branch, 'stock_receipt', p_item, coalesce(p_note, it.name), jsonb_build_array(
    jsonb_build_object('key','inventory','debit',v_val), jsonb_build_object('key','ap','credit',v_val)));
end $$;

-- ================================================================ privileges
revoke execute on all functions in schema public from public, anon;
grant execute on function public.create_tenant(jsonb), public.set_my_pin(uuid,text), public.open_shift(uuid,bigint),
  public.close_shift(uuid,bigint), public.shift_summary(uuid), public.log_drawer_open(uuid,text,text),
  public.complete_sale(jsonb), public.refund_sale(jsonb), public.receive_payment(uuid,public.tender_type,bigint,text,uuid),
  public.create_payment_link(uuid,bigint), public.adjust_stock(uuid,uuid,numeric,text),
  public.receive_stock(uuid,uuid,numeric,bigint,text), public.sale_json(uuid), public.customer_balance(uuid),
  public.customer_store_credit(uuid), public.is_member(uuid), public.my_role(uuid), public.can_see_branch(uuid,uuid),
  public.has_perm(uuid,text), public.role_has(uuid,public.member_role,text), public.role_limit(uuid,public.member_role,text)
  to authenticated;
grant execute on function public.payment_link_info(text) to anon, authenticated;
grant execute on function public.mark_payment_link_paid(text,text) to service_role;

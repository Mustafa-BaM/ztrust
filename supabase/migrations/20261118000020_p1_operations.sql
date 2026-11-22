-- Z Trust · P1 before launch
--   cash in / cash out in the shift (and an X report), price change with its own permission, exchanges,
--   customer and supplier statements, a cash ceiling per invoice, supplier invoices with three-way matching,
--   purchase requests and returns to suppliers.
-- Built on the schema as of 0018; every new function is granted explicitly.

-- ================================================================ accounts
insert into public.coa_template(system_key, code, name_en, name_ar, type, section) values
  ('cash_safe',         '1012', 'Cash in safe',                 'نقدية في الخزنة',               'asset',   'current_asset'),
  ('exchange_clearing', '1075', 'Exchanges clearing',           'حساب وسيط للاستبدال',           'asset',   'current_asset'),
  ('purchase_variance', '5150', 'Purchase price variance',      'فروقات أسعار الشراء',           'expense', 'cogs')
on conflict (system_key) do nothing;
insert into public.accounts(tenant_id, code, name_en, name_ar, type, system_key)
select t.id, c.code, c.name_en, c.name_ar, c.type, c.system_key from public.tenants t cross join public.coa_template c
 where c.system_key in ('cash_safe','exchange_clearing','purchase_variance') on conflict do nothing;

create or replace function public._tender_account(p_tender public.tender_type) returns text
language sql immutable as $$
  select case p_tender::text
    when 'cash' then 'cash' when 'card' then 'card_clearing' when 'bank_transfer' then 'bank' when 'store_credit' then 'store_credit'
    when 'on_account' then 'ar' when 'payment_link' then 'ar' when 'platform' then 'platform_clearing'
    when 'package' then 'deferred_revenue' when 'deposit' then 'customer_deposits' when 'loyalty' then 'exp_loyalty'
    when 'gift_card' then 'gift_cards' when 'cod' then 'cod_clearing' when 'exchange' then 'exchange_clearing'
    else 'other_clearing' end;
$$;

-- ================================================================ permissions
insert into public.permission_catalog(key, module, name_en, name_ar, limit_kind, sort) values
  ('sale.price',        'sales',      'Change the selling price on the POS', 'تغيير سعر البيع في نقطة البيع', null, 6),
  ('drawer.cash_move',  'sales',      'Cash in / cash out of the drawer (max amount)', 'إيداع وسحب نقدي من الدرج (حد أقصى)', 'money', 7),
  ('purchase.request',  'purchasing', 'Request purchases', 'طلب شراء', null, 34)
on conflict (key) do nothing;
update public.role_templates set perms = perms || '{"sale.price":null,"drawer.cash_move":50}' where key = 'supervisor';
update public.role_templates set perms = perms || '{"sale.price":null,"drawer.cash_move":null,"purchase.request":null}' where key = 'manager';
update public.role_templates set perms = perms || '{"purchase.request":null}' where key in ('storekeeper','purchasing');
insert into public.role_permissions(tenant_id, role, permission, limit_value)
select r.tenant_id, r.key, x.perm, case when x.lim is null then null else x.lim * power(10, t.currency_decimals) end
  from public.roles r join public.tenants t on t.id = r.tenant_id
  join (values ('supervisor','sale.price',null::numeric),('supervisor','drawer.cash_move',50),
               ('manager','sale.price',null),('manager','drawer.cash_move',null),('manager','purchase.request',null),
               ('storekeeper','purchase.request',null),('purchasing','purchase.request',null)) x(role, perm, lim) on x.role = r.key
on conflict do nothing;

-- ================================================================ document numbers for the new documents
create table public.doc_counters (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  prefix    text not null,
  next_no   bigint not null default 1,
  primary key (tenant_id, branch_id, prefix)
);
alter table public.doc_counters enable row level security;

create or replace function public._doc_no(p_tenant uuid, p_branch uuid, p_prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare v_no bigint;
begin
  insert into doc_counters(tenant_id, branch_id, prefix, next_no) values (p_tenant, p_branch, p_prefix, 2)
  on conflict (tenant_id, branch_id, prefix) do update set next_no = doc_counters.next_no + 1
  returning next_no - 1 into v_no;
  return (select code from branches where id = p_branch) || '-' || p_prefix || '-' || lpad(v_no::text, 5, '0');
end $$;

-- ================================================================ cash in / cash out
create table public.cash_moves (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  shift_id    uuid not null references public.shifts(id),
  kind        text not null check (kind in ('in','out')),
  amount      bigint not null check (amount > 0),
  counter     text not null check (counter in ('safe','bank','expense','owner','exchange')),
  account_id  uuid references public.accounts(id),
  reason      text not null,
  sale_id     uuid references public.sales(id),
  approved_by uuid,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index on public.cash_moves(shift_id);
alter table public.cash_moves enable row level security;
create policy cm_read on public.cash_moves for select using (can_see_branch(tenant_id, branch_id));
grant select on public.cash_moves to authenticated;

/** Cash put into or taken out of the drawer during a shift. Out: to the safe, the bank, or paid for an expense. In: from the safe, the bank or the owner. */
create or replace function public.cash_move(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s shifts%rowtype; v_kind text := p->>'kind'; v_amt bigint := (p->>'amount')::bigint; v_counter text := coalesce(p->>'counter','safe');
        v_reason text := nullif(trim(coalesce(p->>'reason','')),''); v_acct uuid; a accounts%rowtype; v_appr uuid; v_id uuid := gen_random_uuid(); v_key text;
begin
  select * into s from shifts where id = (p->>'shift_id')::uuid for update;
  if not found or not can_see_branch(s.tenant_id, s.branch_id) then raise exception 'shift not found'; end if;
  if s.closed_at is not null then raise exception 'the shift is closed' using errcode = 'ZT422'; end if;
  if v_kind not in ('in','out') then raise exception 'choose cash in or cash out' using errcode = 'ZT422'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'amount must be positive' using errcode = 'ZT422'; end if;
  if v_reason is null then raise exception 'a reason is required' using errcode = 'ZT422'; end if;
  if v_counter not in ('safe','bank','expense','owner') then raise exception 'unknown destination' using errcode = 'ZT422'; end if;
  if v_counter = 'expense' and v_kind <> 'out' then raise exception 'expenses are paid out of the drawer' using errcode = 'ZT422'; end if;
  v_appr := _require(s.tenant_id, 'drawer.cash_move', v_amt, p->>'approver_pin');
  if v_kind = 'out' and v_amt > s.opening_float + coalesce((select sum(amount) from payments where shift_id = s.id and tender = 'cash' and status = 'captured'), 0)
       + coalesce((select sum(case when kind = 'in' then amount else -amount end) from cash_moves where shift_id = s.id), 0) then
    raise exception 'there is not that much cash in the drawer' using errcode = 'ZT422'; end if;
  if v_counter = 'expense' then
    select * into a from accounts where id = (p->>'account_id')::uuid and tenant_id = s.tenant_id and is_active;
    if not found or a.section not in ('operating_expense','other_expense','cogs') then raise exception 'choose an expense account' using errcode = 'ZT422'; end if;
    v_acct := a.id;
  end if;
  v_key := case v_counter when 'safe' then 'cash_safe' when 'bank' then 'bank' when 'owner' then 'equity' else null end;
  insert into cash_moves(id, tenant_id, branch_id, shift_id, kind, amount, counter, account_id, reason, approved_by, created_by)
  values (v_id, s.tenant_id, s.branch_id, s.id, v_kind, v_amt, v_counter, v_acct, v_reason, v_appr, auth.uid());
  perform _post(s.tenant_id, s.branch_id, 'cash_move', v_id, v_reason, case when v_kind = 'out'
    then jsonb_build_array(case when v_acct is not null then jsonb_build_object('account_id', v_acct, 'debit', v_amt) else jsonb_build_object('key', v_key, 'debit', v_amt) end,
                           jsonb_build_object('key','cash','credit', v_amt))
    else jsonb_build_array(jsonb_build_object('key','cash','debit', v_amt), jsonb_build_object('key', v_key, 'credit', v_amt)) end);
  perform _audit(s.tenant_id, s.branch_id, 'drawer.cash_' || v_kind, 'shift', s.id, v_amt, v_reason, v_appr, jsonb_build_object('to', v_counter));
  return shift_summary(s.id);
end $$;
grant execute on function public.cash_move(jsonb) to authenticated;

/** Cash the drawer should hold: float + cash sales and refunds + cash in − cash out. */
create or replace function public._expected_cash(p_shift uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select s.opening_float
       + coalesce((select sum(amount) from payments where shift_id = s.id and tender = 'cash' and status = 'captured'), 0)
       + coalesce((select sum(case when kind = 'in' then amount else -amount end) from cash_moves where shift_id = s.id), 0)
  from shifts s where s.id = p_shift;
$$;

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
    'discounts_total', (select coalesce(sum(discount_total),0) from sales where shift_id = s.id and doc_type='invoice'),
    'tax_total', (select coalesce(sum(case when doc_type='invoice' then tax_total else -tax_total end),0) from sales where shift_id = s.id),
    'tenders', (select coalesce(jsonb_object_agg(tender, amt),'{}') from
                 (select p.tender, sum(p.amount) amt from payments p where p.shift_id = s.id group by p.tender) t),
    'methods', (select coalesce(jsonb_object_agg(m, amt),'{}') from
                 (select coalesce(p.method, p.tender::text) m, sum(p.amount) amt from payments p where p.shift_id = s.id and p.tender = 'card' group by 1) t),
    'cash_in', (select coalesce(sum(amount),0) from cash_moves where shift_id = s.id and kind = 'in'),
    'cash_out', (select coalesce(sum(amount),0) from cash_moves where shift_id = s.id and kind = 'out'),
    'moves', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'amount', amount, 'counter', counter, 'reason', reason, 'at', created_at) order by created_at), '[]')
                from cash_moves where shift_id = s.id),
    'expected_cash', case when v_show then _expected_cash(s.id) end,
    'printed_at', now()
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

  v_expected := _expected_cash(s.id);
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

-- ================================================================ selling price per customer (price lists, see 0021) — placeholder that 0021 replaces
create or replace function public._list_price(p_tenant uuid, p_customer uuid, p_item uuid) returns bigint
language sql stable security definer set search_path = public as $$ select null::bigint $$;

-- ================================================================ statements of account
/** Customer (AR) or supplier (AP) statement: opening balance, every posting with a running balance. */
create or replace function public.party_statement(p_tenant uuid, p_kind text, p_party uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_acct uuid; v_open bigint; v_rows jsonb; v_sign int := case when p_kind = 'ar' then 1 else -1 end;
begin
  if not is_member(p_tenant) then raise exception 'not a member of this business' using errcode = '42501'; end if;
  if p_kind = 'ar' then
    if not (has_perm(p_tenant, 'payments.receive') or has_perm(p_tenant, 'customers.manage') or has_perm(p_tenant, 'finance.view')) then raise exception 'not allowed' using errcode = '42501'; end if;
  elsif p_kind = 'ap' then
    if not (has_perm(p_tenant, 'payables.pay') or has_perm(p_tenant, 'suppliers.manage') or has_perm(p_tenant, 'finance.view')) then raise exception 'not allowed' using errcode = '42501'; end if;
  else raise exception 'kind is ar or ap'; end if;
  v_acct := _acct(p_tenant, p_kind);
  select coalesce(sum(l.debit - l.credit), 0) * v_sign into v_open
    from journal_lines l join journal_entries e on e.id = l.entry_id
   where l.tenant_id = p_tenant and l.account_id = v_acct and e.entry_date < p_from
     and (case when p_kind = 'ar' then l.customer_id else l.supplier_id end) = p_party;
  select coalesce(jsonb_agg(r order by r.date, r.entry_no), '[]') into v_rows from (
    select e.entry_date as date, e.entry_no, e.source_type as source, coalesce(e.reference, e.memo) as ref, e.memo,
           l.debit, l.credit,
           v_open + sum((l.debit - l.credit) * v_sign) over (order by e.entry_date, e.entry_no, l.id) as balance
      from journal_lines l join journal_entries e on e.id = l.entry_id
     where l.tenant_id = p_tenant and l.account_id = v_acct and e.entry_date between p_from and p_to
       and (case when p_kind = 'ar' then l.customer_id else l.supplier_id end) = p_party) r;
  return jsonb_build_object('opening', v_open, 'rows', v_rows,
    'closing', v_open + coalesce((select sum(((x->>'debit')::bigint - (x->>'credit')::bigint) * v_sign) from jsonb_array_elements(v_rows) x), 0));
end $$;
grant execute on function public.party_statement(uuid, text, uuid, date, date) to authenticated;

-- ================================================================ purchase requests
create table public.purchase_requests (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  branch_id    uuid not null references public.branches(id),
  number       text not null,
  lines        jsonb not null,           -- [{item_id, qty, note}]
  note         text,
  status       text not null default 'pending' check (status in ('pending','approved','rejected','ordered')),
  po_id        uuid references public.purchase_orders(id),
  requested_by uuid,
  decided_by   uuid,
  decided_at   timestamptz,
  created_at   timestamptz not null default now()
);
alter table public.purchase_requests enable row level security;
create policy pr_read on public.purchase_requests for select using (can_see_branch(tenant_id, branch_id));
grant select on public.purchase_requests to authenticated;

create or replace function public.save_purchase_request(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_id uuid := gen_random_uuid(); e jsonb;
begin
  if not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  if not (has_perm(v_tenant, 'purchase.request') or has_perm(v_tenant, 'purchase.create')) then raise exception 'not allowed' using errcode = '42501'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'add at least one item' using errcode = 'ZT422'; end if;
  for e in select * from jsonb_array_elements(p->'lines') loop
    if not exists (select 1 from items where id = (e->>'item_id')::uuid and tenant_id = v_tenant) or coalesce((e->>'qty')::numeric, 0) <= 0 then
      raise exception 'check the items and quantities' using errcode = 'ZT422'; end if;
  end loop;
  insert into purchase_requests(id, tenant_id, branch_id, number, lines, note, requested_by)
  values (v_id, v_tenant, v_branch, _doc_no(v_tenant, v_branch, 'REQ'), p->'lines', nullif(p->>'note',''), auth.uid());
  return v_id;
end $$;
grant execute on function public.save_purchase_request(jsonb) to authenticated;

create or replace function public.decide_purchase_request(p_id uuid, p_status text, p_po uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare r purchase_requests%rowtype;
begin
  select * into r from purchase_requests where id = p_id for update;
  if not found or not can_see_branch(r.tenant_id, r.branch_id) then raise exception 'request not found'; end if;
  perform _require(r.tenant_id, 'purchase.create', null, null);
  if p_status not in ('approved','rejected','ordered') then raise exception 'unknown status'; end if;
  if r.status in ('rejected','ordered') then raise exception 'this request is closed' using errcode = 'ZT422'; end if;
  update purchase_requests set status = p_status, decided_by = auth.uid(), decided_at = now(),
         po_id = coalesce(p_po, po_id) where id = r.id;
end $$;
grant execute on function public.decide_purchase_request(uuid, text, uuid) to authenticated;

-- ================================================================ supplier invoices with three-way matching
alter table public.purchase_order_lines add column if not exists billed_qty numeric(14,3) not null default 0;

create table public.supplier_invoices (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  branch_id    uuid not null references public.branches(id),
  supplier_id  uuid not null references public.suppliers(id),
  po_id        uuid references public.purchase_orders(id),
  number       text not null,             -- our reference
  supplier_no  text not null,             -- the supplier's invoice number
  invoice_date date not null,
  due_date     date,
  subtotal     bigint not null,
  vat          bigint not null default 0,
  total        bigint not null,
  expected     bigint not null,             -- billed qty × PO price
  variance     bigint not null default 0,   -- subtotal − expected
  match_status text not null check (match_status in ('matched','variance')),
  lines        jsonb not null,             -- [{po_line_id, item_id, name, qty, unit_cost, ordered, received, billed_before, po_cost}]
  approved_by  uuid,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  unique (tenant_id, supplier_id, supplier_no)
);
alter table public.supplier_invoices enable row level security;
create policy si_read on public.supplier_invoices for select using (can_see_branch(tenant_id, branch_id));
grant select on public.supplier_invoices to authenticated;

/**
 * The supplier's bill for a purchase order. Each line is checked against what was ordered (price) and what was received (quantity).
 * Stock and the payable were booked at the goods receipt at the order price, so the bill only adds VAT and any price difference.
 * A bill that does not match needs someone who can approve purchases.
 */
create or replace function public.record_supplier_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o purchase_orders%rowtype; ol purchase_order_lines%rowtype; e jsonb; v_qty numeric; v_cost bigint;
        v_sub bigint := 0; v_exp bigint := 0; v_vat bigint := greatest(coalesce((p->>'vat')::bigint, 0), 0); v_lines jsonb := '[]';
        v_bad boolean := false; v_id uuid := gen_random_uuid(); v_appr uuid; v_no text; v_var bigint;
begin
  select * into o from purchase_orders where id = (p->>'po_id')::uuid for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'purchase order not found'; end if;
  if not (has_perm(o.tenant_id, 'payables.pay') or has_perm(o.tenant_id, 'purchase.create') or has_perm(o.tenant_id, 'finance.journal')) then
    raise exception 'not allowed' using errcode = '42501'; end if;
  if coalesce(trim(p->>'supplier_no'),'') = '' then raise exception 'enter the supplier''s invoice number' using errcode = 'ZT422'; end if;
  if exists (select 1 from supplier_invoices where tenant_id = o.tenant_id and supplier_id = o.supplier_id and supplier_no = trim(p->>'supplier_no')) then
    raise exception 'this supplier invoice is already recorded' using errcode = 'ZT422'; end if;

  for e in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    v_qty := (e->>'qty')::numeric; v_cost := (e->>'unit_cost')::bigint;
    if v_qty is null or v_qty <= 0 then continue; end if;
    if v_cost is null or v_cost < 0 then raise exception 'enter the billed price' using errcode = 'ZT422'; end if;
    select * into ol from purchase_order_lines where id = (e->>'po_line_id')::uuid and po_id = o.id for update;
    if not found then raise exception 'line not on this order'; end if;
    if ol.billed_qty + v_qty > ol.received_qty or v_cost <> ol.unit_cost then v_bad := true; end if;
    v_sub := v_sub + round(v_qty * v_cost)::bigint; v_exp := v_exp + round(v_qty * ol.unit_cost)::bigint;
    v_lines := v_lines || jsonb_build_object('po_line_id', ol.id, 'item_id', ol.item_id, 'name', (select name from items where id = ol.item_id),
      'qty', v_qty, 'unit_cost', v_cost, 'ordered', ol.qty, 'received', ol.received_qty, 'billed_before', ol.billed_qty, 'po_cost', ol.unit_cost);
    update purchase_order_lines set billed_qty = billed_qty + v_qty where id = ol.id;
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'enter at least one billed quantity' using errcode = 'ZT422'; end if;
  if v_bad then v_appr := _require(o.tenant_id, 'purchase.approve', null, p->>'approver_pin'); end if;
  v_var := v_sub - v_exp;
  v_no := _doc_no(o.tenant_id, o.branch_id, 'BILL');
  insert into supplier_invoices(id, tenant_id, branch_id, supplier_id, po_id, number, supplier_no, invoice_date, due_date, subtotal, vat, total,
                                expected, variance, match_status, lines, approved_by, created_by)
  values (v_id, o.tenant_id, o.branch_id, o.supplier_id, o.id, v_no, trim(p->>'supplier_no'), coalesce(nullif(p->>'invoice_date','')::date, current_date),
          coalesce(nullif(p->>'due_date','')::date, coalesce(nullif(p->>'invoice_date','')::date, current_date) + coalesce((select payment_terms_days from suppliers where id = o.supplier_id), 0)),
          v_sub, v_vat, v_sub + v_vat, v_exp, v_var, case when v_bad then 'variance' else 'matched' end, v_lines, v_appr, auth.uid());
  -- the receipt booked qty × order price; the bill adds VAT and the price difference
  perform _post_ex(o.tenant_id, o.branch_id, 'supplier_invoice', v_id, v_no || ' · ' || trim(p->>'supplier_no'), jsonb_build_array(
      jsonb_build_object('key','vat_input','debit', v_vat),
      jsonb_build_object('key','purchase_variance','debit', greatest(v_var, 0)),
      jsonb_build_object('key','purchase_variance','credit', greatest(-v_var, 0)),
      jsonb_build_object('key','ap','credit', v_vat + greatest(v_var, 0), 'supplier_id', o.supplier_id),
      jsonb_build_object('key','ap','debit', greatest(-v_var, 0), 'supplier_id', o.supplier_id)),
    coalesce(nullif(p->>'invoice_date','')::date, current_date), trim(p->>'supplier_no'));
  if v_bad then perform _audit(o.tenant_id, o.branch_id, 'purchase.bill_variance', 'purchase_order', o.id, v_var, trim(p->>'supplier_no'), v_appr); end if;
  return jsonb_build_object('id', v_id, 'number', v_no, 'match_status', case when v_bad then 'variance' else 'matched' end, 'variance', v_var);
end $$;
grant execute on function public.record_supplier_invoice(jsonb) to authenticated;

-- ================================================================ returns to suppliers
alter table public.stock_movements drop constraint if exists stock_movements_reason_check;
alter table public.stock_movements add constraint stock_movements_reason_check
  check (reason in ('sale','refund','adjustment','receipt','count','transfer_in','transfer_out','production','supplier_return'));

create table public.purchase_returns (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  supplier_id uuid not null references public.suppliers(id),
  po_id       uuid references public.purchase_orders(id),
  number      text not null,
  reason      text not null,
  lines       jsonb not null,          -- [{item_id, name, qty, unit_cost, stock_cost}]
  total       bigint not null,
  vat         bigint not null default 0,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
alter table public.purchase_returns enable row level security;
create policy prt_read on public.purchase_returns for select using (can_see_branch(tenant_id, branch_id));
grant select on public.purchase_returns to authenticated;

/** Goods sent back to the supplier: stock out at its average cost, the supplier owes us (debit note), price difference to purchase variance. */
create or replace function public.return_to_supplier(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_sup uuid := (p->>'supplier_id')::uuid;
        e jsonb; it items%rowtype; v_qty numeric; v_cost bigint; v_onhand numeric; v_val bigint := 0; v_stock bigint := 0;
        v_vat bigint := greatest(coalesce((p->>'vat')::bigint, 0), 0); v_lines jsonb := '[]'; v_id uuid := gen_random_uuid(); v_no text;
        v_reason text := nullif(trim(coalesce(p->>'reason','')),''); v_n int;
begin
  if not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'inventory.adjust', null, null);
  if not exists (select 1 from suppliers where id = v_sup and tenant_id = v_tenant) then raise exception 'unknown supplier'; end if;
  if v_reason is null then raise exception 'a reason is required' using errcode = 'ZT422'; end if;
  v_no := _doc_no(v_tenant, v_branch, 'RTV');
  for e in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    v_qty := (e->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then continue; end if;
    select * into it from items where id = (e->>'item_id')::uuid and tenant_id = v_tenant for update;
    if not found or not it.track_stock then raise exception 'only stock items can be returned to a supplier' using errcode = 'ZT422'; end if;
    select coalesce(sum(qty),0) into v_onhand from stock_movements where item_id = it.id and branch_id = v_branch;
    if v_qty > v_onhand then raise exception 'only % of % in stock', v_onhand, it.name using errcode = 'ZT422'; end if;
    v_cost := coalesce((e->>'unit_cost')::bigint, it.cost);
    insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
    values (v_tenant, v_branch, it.id, -v_qty, 'supplier_return', v_id, it.cost, v_no, auth.uid());
    if coalesce(it.track_serial, false) then
      if jsonb_array_length(coalesce(e->'serials','[]')) <> v_qty then raise exception 'enter one serial number per unit of %', it.name using errcode = 'ZT422'; end if;
      update item_serials set status = 'returned', source = v_no
       where tenant_id = v_tenant and item_id = it.id and status = 'in_stock' and upper(serial) in (select upper(trim(x)) from jsonb_array_elements_text(e->'serials') x);
      get diagnostics v_n = row_count;
      if v_n <> v_qty then raise exception 'a serial number of % is not in stock', it.name using errcode = 'ZT422'; end if;
    end if;
    v_val := v_val + round(v_qty * v_cost)::bigint; v_stock := v_stock + round(v_qty * it.cost)::bigint;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'name', it.name, 'qty', v_qty, 'unit_cost', v_cost, 'stock_cost', it.cost);
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'enter at least one quantity' using errcode = 'ZT422'; end if;
  insert into purchase_returns(id, tenant_id, branch_id, supplier_id, po_id, number, reason, lines, total, vat, created_by)
  values (v_id, v_tenant, v_branch, v_sup, nullif(p->>'po_id','')::uuid, v_no, v_reason, v_lines, v_val + v_vat, v_vat, auth.uid());
  perform _post(v_tenant, v_branch, 'purchase_return', v_id, v_no, jsonb_build_array(
    jsonb_build_object('key','ap','debit', v_val + v_vat, 'supplier_id', v_sup),
    jsonb_build_object('key','inventory','credit', v_stock),
    jsonb_build_object('key','vat_input','credit', v_vat),
    jsonb_build_object('key','purchase_variance','credit', greatest(v_val - v_stock, 0)),
    jsonb_build_object('key','purchase_variance','debit', greatest(v_stock - v_val, 0))));
  perform _audit(v_tenant, v_branch, 'purchase.return', 'supplier', v_sup, v_val + v_vat, v_reason, null, jsonb_build_object('number', v_no));
  return jsonb_build_object('id', v_id, 'number', v_no, 'total', v_val + v_vat);
end $$;
grant execute on function public.return_to_supplier(jsonb) to authenticated;

-- ================================================================ exchanges
/**
 * Return some lines of an invoice and sell new items in one step. The returned value pays for the new sale
 * (tender "exchange"); if the customer is owed more, the difference leaves the drawer as cash.
 * p = {refund: {refund_sale payload}, sale: {complete_sale payload incl. an "exchange" payment}}
 */
create or replace function public.exchange_sale(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_cn jsonb; v_sale jsonb; v_ret bigint; v_used bigint; v_sid uuid; s shifts%rowtype;
begin
  v_cn := refund_sale((p->'refund') || jsonb_build_object('tender','exchange','cancel',false));
  v_ret := (v_cn->>'total')::bigint;
  v_used := coalesce((select sum((x->>'amount')::bigint) from jsonb_array_elements(p->'sale'->'payments') x where x->>'tender' = 'exchange'), 0);
  v_sale := complete_sale(p->'sale');
  if v_used <> least(v_ret, (v_sale->>'total')::bigint) then
    raise exception 'the exchange credit must be % (returned %, new sale %)', least(v_ret, (v_sale->>'total')::bigint), v_ret, v_sale->>'total' using errcode = 'ZT422'; end if;
  if v_ret > v_used then
    v_sid := nullif(p->'sale'->>'shift_id','')::uuid;
    select * into s from shifts where id = v_sid and closed_at is null;
    if not found then raise exception 'open a shift to pay the difference in cash' using errcode = 'ZT422'; end if;
    insert into cash_moves(tenant_id, branch_id, shift_id, kind, amount, counter, reason, sale_id, created_by)
    values (s.tenant_id, s.branch_id, s.id, 'out', v_ret - v_used, 'exchange', 'Exchange ' || (v_cn->>'number') || ' → ' || (v_sale->>'number'), (v_sale->>'id')::uuid, auth.uid());
    perform _post(s.tenant_id, s.branch_id, 'exchange_payout', (v_sale->>'id')::uuid, 'Exchange difference ' || (v_sale->>'number'), jsonb_build_array(
      jsonb_build_object('key','exchange_clearing','debit', v_ret - v_used), jsonb_build_object('key','cash','credit', v_ret - v_used)));
  end if;
  return jsonb_build_object('credit_note', v_cn, 'sale', v_sale, 'cash_back', greatest(v_ret - v_used, 0));
end $$;
grant execute on function public.exchange_sale(jsonb) to authenticated;

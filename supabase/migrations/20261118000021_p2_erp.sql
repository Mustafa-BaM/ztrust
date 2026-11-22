-- Z Trust · P2: price lists, quotations → sales orders → delivery notes → invoice, serial / IMEI numbers,
--   customer debit notes, cash flow statement, bank reconciliation, petty cash top-ups,
--   account hierarchy and cost centres. complete_sale / refund_sale / receive_po are re-issued at the end.

-- ================================================================ price lists
create table public.price_lists (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  name         text not null,
  name_ar      text,
  discount_pct numeric(5,2) not null default 0 check (discount_pct between 0 and 100),  -- for items without their own price
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);
create table public.price_list_items (
  list_id   uuid not null references public.price_lists(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  item_id   uuid not null references public.items(id) on delete cascade,
  price     bigint not null check (price >= 0),
  primary key (list_id, item_id)
);
alter table public.customers add column if not exists price_list_id uuid references public.price_lists(id) on delete set null;
alter table public.price_lists enable row level security;
alter table public.price_list_items enable row level security;
create policy pl_read on public.price_lists for select using (is_member(tenant_id));
create policy pli_read on public.price_list_items for select using (is_member(tenant_id));
grant select on public.price_lists, public.price_list_items to authenticated;

create or replace function public._list_price(p_tenant uuid, p_customer uuid, p_item uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(pli.price, case when pl.discount_pct > 0 then round(i.price * (100 - pl.discount_pct) / 100)::bigint end)
    from customers c join price_lists pl on pl.id = c.price_list_id and pl.is_active
    join items i on i.id = p_item and i.tenant_id = p_tenant
    left join price_list_items pli on pli.list_id = pl.id and pli.item_id = p_item
   where c.id = p_customer and c.tenant_id = p_tenant;
$$;

/** Create or update a price list and its item prices: p = {id?, tenant_id, name, name_ar, discount_pct, is_active, items: [{item_id, price}]} */
create or replace function public.save_price_list(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_id uuid := coalesce(nullif(p->>'id','')::uuid, gen_random_uuid());
begin
  perform _require(v_tenant, 'catalog.manage', null, null);
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'enter a name' using errcode = 'ZT422'; end if;
  insert into price_lists(id, tenant_id, name, name_ar, discount_pct, is_active)
  values (v_id, v_tenant, trim(p->>'name'), nullif(trim(p->>'name_ar'),''), coalesce((p->>'discount_pct')::numeric, 0), coalesce((p->>'is_active')::boolean, true))
  on conflict (id) do update set name = excluded.name, name_ar = excluded.name_ar, discount_pct = excluded.discount_pct, is_active = excluded.is_active
  where price_lists.tenant_id = v_tenant;
  if p ? 'items' then
    delete from price_list_items where list_id = v_id;
    insert into price_list_items(list_id, tenant_id, item_id, price)
    select v_id, v_tenant, (x->>'item_id')::uuid, (x->>'price')::bigint from jsonb_array_elements(p->'items') x
      join items i on i.id = (x->>'item_id')::uuid and i.tenant_id = v_tenant where (x->>'price') is not null;
  end if;
  return v_id;
end $$;
grant execute on function public.save_price_list(jsonb) to authenticated;

create or replace function public.set_customer_price_list(p_customer uuid, p_list uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c customers%rowtype;
begin
  select * into c from customers where id = p_customer;
  if not found then raise exception 'customer not found'; end if;
  perform _require(c.tenant_id, 'customers.manage', null, null);
  if p_list is not null and not exists (select 1 from price_lists where id = p_list and tenant_id = c.tenant_id) then raise exception 'unknown price list'; end if;
  update customers set price_list_id = p_list where id = c.id;
end $$;
grant execute on function public.set_customer_price_list(uuid, uuid) to authenticated;

-- ================================================================ quotations, sales orders, delivery notes
create table public.sales_docs (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  kind        text not null check (kind in ('quotation','order','delivery')),
  number      text not null,
  customer_id uuid references public.customers(id),
  status      text not null default 'draft' check (status in ('draft','sent','accepted','rejected','expired','open','delivered','invoiced','cancelled')),
  valid_until date,
  lines       jsonb not null,     -- [{item_id, name, name_ar, qty, unit_price, discount, tax_rate, net, tax, total}]
  subtotal    bigint not null default 0,
  discount    bigint not null default 0,
  tax         bigint not null default 0,
  total       bigint not null default 0,
  note        text,
  source_id   uuid references public.sales_docs(id),
  sale_id     uuid references public.sales(id),
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on public.sales_docs(tenant_id, kind, created_at desc);
alter table public.sales_docs enable row level security;
create policy sd_read on public.sales_docs for select using (can_see_branch(tenant_id, branch_id));
grant select on public.sales_docs to authenticated;

/** Quotation, sales order or delivery note (draft). Prices come from the customer's price list unless typed; totals are worked out here. */
create or replace function public.save_sales_doc(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tenants%rowtype; v_branch uuid := (p->>'branch_id')::uuid; v_id uuid := nullif(p->>'id','')::uuid; d sales_docs%rowtype;
        v_kind text := coalesce(p->>'kind','quotation'); v_cust uuid := nullif(p->>'customer_id','')::uuid;
        l jsonb; it items%rowtype; v_qty numeric; v_price bigint; v_disc bigint; v_rate numeric; v_gross bigint; v_tax bigint; v_net bigint; v_tot bigint;
        v_lines jsonb := '[]'; v_sub bigint := 0; v_dsum bigint := 0; v_tsum bigint := 0; v_total bigint := 0;
begin
  select * into t from tenants where id = (p->>'tenant_id')::uuid;
  if not found or not can_see_branch(t.id, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(t.id, 'sale.create', null, null);
  if v_kind not in ('quotation','order','delivery') then raise exception 'unknown document'; end if;
  if v_cust is not null and not exists (select 1 from customers where id = v_cust and tenant_id = t.id) then raise exception 'unknown customer'; end if;
  if v_kind <> 'quotation' and v_cust is null then raise exception 'choose the customer' using errcode = 'ZT422'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'add at least one item' using errcode = 'ZT422'; end if;
  for l in select * from jsonb_array_elements(p->'lines') loop
    select * into it from items where id = (l->>'item_id')::uuid and tenant_id = t.id;
    if not found then raise exception 'unknown item'; end if;
    v_qty := (l->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'quantity must be positive' using errcode = 'ZT422'; end if;
    v_price := coalesce((l->>'unit_price')::bigint, _list_price(t.id, v_cust, it.id), it.price);
    v_disc := greatest(coalesce((l->>'discount')::bigint, 0), 0);
    v_rate := coalesce(it.tax_rate, t.vat_rate);
    v_gross := round(v_qty * v_price)::bigint - v_disc;
    if v_gross < 0 then raise exception 'discount larger than line' using errcode = 'ZT422'; end if;
    if t.prices_include_tax then v_tax := round(v_gross * v_rate / (100 + v_rate))::bigint; v_net := v_gross - v_tax; v_tot := v_gross;
    else v_net := v_gross; v_tax := round(v_net * v_rate / 100)::bigint; v_tot := v_net + v_tax; end if;
    v_sub := v_sub + v_net; v_dsum := v_dsum + v_disc; v_tsum := v_tsum + v_tax; v_total := v_total + v_tot;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'name', it.name, 'name_ar', it.name_ar, 'qty', v_qty, 'unit_price', v_price,
                 'discount', v_disc, 'tax_rate', v_rate, 'net', v_net, 'tax', v_tax, 'total', v_tot, 'note', nullif(l->>'note',''));
  end loop;
  if v_id is not null then
    select * into d from sales_docs where id = v_id and tenant_id = t.id for update;
    if not found then raise exception 'document not found'; end if;
    if d.status not in ('draft','sent','open') then raise exception 'this document can no longer be changed' using errcode = 'ZT422'; end if;
    update sales_docs set customer_id = v_cust, lines = v_lines, subtotal = v_sub, discount = v_dsum, tax = v_tsum, total = v_total,
           valid_until = nullif(p->>'valid_until','')::date, note = nullif(p->>'note',''), updated_at = now() where id = v_id;
  else
    v_id := gen_random_uuid();
    insert into sales_docs(id, tenant_id, branch_id, kind, number, customer_id, status, valid_until, lines, subtotal, discount, tax, total, note, source_id, created_by)
    values (v_id, t.id, v_branch, v_kind, _doc_no(t.id, v_branch, case v_kind when 'quotation' then 'QT' when 'order' then 'SO' else 'DN' end),
            v_cust, case when v_kind = 'quotation' then 'draft' else 'open' end,
            coalesce(nullif(p->>'valid_until','')::date, case when v_kind = 'quotation' then current_date + coalesce((t.settings->>'quote_valid_days')::int, 14) end),
            v_lines, v_sub, v_dsum, v_tsum, v_total, nullif(p->>'note',''), nullif(p->>'source_id','')::uuid, auth.uid());
  end if;
  return (select to_jsonb(x) from sales_docs x where id = v_id);
end $$;
grant execute on function public.save_sales_doc(jsonb) to authenticated;

/** Move a document forward: quotation → order, order → delivery note; or set its status (sent, accepted, rejected, cancelled, delivered). */
create or replace function public.advance_sales_doc(p_id uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d sales_docs%rowtype; v_new jsonb;
begin
  select * into d from sales_docs where id = p_id for update;
  if not found or not can_see_branch(d.tenant_id, d.branch_id) then raise exception 'document not found'; end if;
  perform _require(d.tenant_id, 'sale.create', null, null);
  if d.status in ('invoiced','cancelled','rejected') then raise exception 'this document is closed' using errcode = 'ZT422'; end if;
  if p_action = 'to_order' then
    if d.kind <> 'quotation' then raise exception 'only a quotation becomes an order'; end if;
    if d.customer_id is null then raise exception 'choose the customer on the quotation first' using errcode = 'ZT422'; end if;
    v_new := save_sales_doc(jsonb_build_object('tenant_id', d.tenant_id, 'branch_id', d.branch_id, 'kind', 'order', 'customer_id', d.customer_id,
               'lines', d.lines, 'note', d.note, 'source_id', d.id));
    update sales_docs set status = 'accepted', updated_at = now() where id = d.id;
    return v_new;
  elsif p_action = 'to_delivery' then
    if d.kind <> 'order' then raise exception 'only an order gets a delivery note'; end if;
    v_new := save_sales_doc(jsonb_build_object('tenant_id', d.tenant_id, 'branch_id', d.branch_id, 'kind', 'delivery', 'customer_id', d.customer_id,
               'lines', d.lines, 'note', d.note, 'source_id', d.id));
    update sales_docs set status = 'delivered', updated_at = now() where id = d.id;
    return v_new;
  elsif p_action in ('sent','accepted','rejected','cancelled','delivered') then
    update sales_docs set status = p_action, updated_at = now() where id = d.id;
    return (select to_jsonb(x) from sales_docs x where id = d.id);
  end if;
  raise exception 'unknown action';
end $$;
grant execute on function public.advance_sales_doc(uuid, text) to authenticated;

-- ================================================================ serial / IMEI numbers
alter table public.items add column if not exists track_serial boolean not null default false;
alter table public.items add column if not exists warranty_months int;
create table public.item_serials (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  item_id        uuid not null references public.items(id) on delete cascade,
  serial         text not null,
  branch_id      uuid references public.branches(id),
  status         text not null default 'in_stock' check (status in ('in_stock','sold','returned')),
  source         text,              -- goods receipt number, "opening stock", credit note
  sale_id        uuid references public.sales(id),
  sale_line_id   uuid,
  sold_at        timestamptz,
  warranty_until date,
  created_at     timestamptz not null default now(),
  unique (tenant_id, item_id, serial)
);
create index on public.item_serials(tenant_id, serial);
alter table public.item_serials enable row level security;
create policy ser_read on public.item_serials for select using (is_member(tenant_id));
grant select on public.item_serials to authenticated;

/** Register serial numbers already on the shelf (opening stock). Receipts register theirs automatically. */
create or replace function public.register_serials(p_item uuid, p_branch uuid, p_serials text[]) returns int
language plpgsql security definer set search_path = public as $$
declare it items%rowtype; v_n int;
begin
  select * into it from items where id = p_item;
  if not found or not can_see_branch(it.tenant_id, p_branch) then raise exception 'item not found'; end if;
  perform _require(it.tenant_id, 'inventory.adjust', null, null);
  insert into item_serials(tenant_id, item_id, serial, branch_id, source)
  select it.tenant_id, it.id, s, p_branch, 'opening stock' from (select distinct nullif(trim(x), '') s from unnest(p_serials) x) q where s is not null
  on conflict (tenant_id, item_id, serial) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.register_serials(uuid, uuid, text[]) to authenticated;

-- ================================================================ customer debit notes
create table public.debit_notes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  branch_id   uuid not null references public.branches(id),
  customer_id uuid not null references public.customers(id),
  number      text not null,
  reason      text not null,
  amount      bigint not null check (amount > 0),
  vat         bigint not null default 0,
  total       bigint not null,
  sale_id     uuid references public.sales(id),
  created_by  uuid,
  created_at  timestamptz not null default now()
);
alter table public.debit_notes enable row level security;
create policy dn_read on public.debit_notes for select using (can_see_branch(tenant_id, branch_id));
grant select on public.debit_notes to authenticated;

/** An extra charge to a customer's account after the invoice (price correction, delivery, late fee). */
create or replace function public.customer_debit_note(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_cust uuid := (p->>'customer_id')::uuid;
        v_amt bigint := (p->>'amount')::bigint; v_vat bigint := greatest(coalesce((p->>'vat')::bigint, 0), 0); v_id uuid := gen_random_uuid(); v_no text;
        v_reason text := nullif(trim(coalesce(p->>'reason','')),'');
begin
  if not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'finance.journal', null, null);
  if not exists (select 1 from customers where id = v_cust and tenant_id = v_tenant) then raise exception 'unknown customer'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'amount must be positive' using errcode = 'ZT422'; end if;
  if v_reason is null then raise exception 'a reason is required' using errcode = 'ZT422'; end if;
  v_no := _doc_no(v_tenant, v_branch, 'DBN');
  insert into debit_notes(id, tenant_id, branch_id, customer_id, number, reason, amount, vat, total, sale_id, created_by)
  values (v_id, v_tenant, v_branch, v_cust, v_no, v_reason, v_amt, v_vat, v_amt + v_vat, nullif(p->>'sale_id','')::uuid, auth.uid());
  perform _post_ex(v_tenant, v_branch, 'debit_note', v_id, v_reason, jsonb_build_array(
    jsonb_build_object('key','ar','debit', v_amt + v_vat, 'customer_id', v_cust),
    jsonb_build_object('key', case when coalesce(p->>'kind','income') = 'sales' then 'sales' else 'other_income' end, 'credit', v_amt),
    jsonb_build_object('key','vat_payable','credit', v_vat)), current_date, v_no);
  perform _audit(v_tenant, v_branch, 'customer.debit_note', 'customer', v_cust, v_amt + v_vat, v_reason, null, jsonb_build_object('number', v_no));
  return jsonb_build_object('id', v_id, 'number', v_no, 'total', v_amt + v_vat);
end $$;
grant execute on function public.customer_debit_note(jsonb) to authenticated;

-- ================================================================ account hierarchy and cost centres
alter table public.accounts add column if not exists parent_id uuid references public.accounts(id);
create or replace function public.guard_account_parent() returns trigger
language plpgsql as $$
declare v uuid := new.parent_id; n int := 0;
begin
  if new.parent_id is null then return new; end if;
  if not exists (select 1 from accounts where id = new.parent_id and tenant_id = new.tenant_id and type = new.type) then
    raise exception 'the parent account must be of the same type' using errcode = 'ZT422'; end if;
  while v is not null and n < 20 loop
    if v = new.id then raise exception 'an account cannot be under itself' using errcode = 'ZT422'; end if;
    select parent_id into v from accounts where id = v; n := n + 1;
  end loop;
  return new;
end $$;
drop trigger if exists accounts_parent on public.accounts;
create trigger accounts_parent before insert or update of parent_id on public.accounts for each row execute function public.guard_account_parent();

create table public.cost_centers (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  code       text not null,
  name       text not null,
  name_ar    text,
  branch_id  uuid references public.branches(id),
  is_active  boolean not null default true,
  unique (tenant_id, code)
);
alter table public.cost_centers enable row level security;
create policy cc_read on public.cost_centers for select using (is_member(tenant_id));
create policy cc_write on public.cost_centers for all using (has_perm(tenant_id, 'finance.manage')) with check (has_perm(tenant_id, 'finance.manage'));
grant select, insert, update on public.cost_centers to authenticated;
alter table public.journal_lines add column if not exists cost_center_id uuid references public.cost_centers(id);

/** Same as before, plus an optional cost centre per line ("cost_center_id"); a line without one takes the branch's cost centre. */
create or replace function public._post_ex(p_tenant uuid, p_branch uuid, p_source text, p_source_id uuid, p_memo text, p_lines jsonb,
  p_date date default null, p_reference text default null, p_approved_by uuid default null, p_reversal_of bigint default null)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_dr bigint; v_cr bigint; v_prev text; v_no bigint; v_id bigint; l jsonb; v_acct uuid; v_cc uuid; v_branch uuid;
begin
  select coalesce(sum((x->>'debit')::bigint),0), coalesce(sum((x->>'credit')::bigint),0) into v_dr, v_cr
    from jsonb_array_elements(p_lines) x;
  if v_dr <> v_cr then raise exception 'unbalanced journal: debit % credit %', v_dr, v_cr; end if;
  if v_dr = 0 then return null; end if;

  perform pg_advisory_xact_lock(hashtext('je:' || p_tenant::text));
  select hash, entry_no into v_prev, v_no from journal_entries where tenant_id = p_tenant order by entry_no desc limit 1;
  insert into journal_entries(tenant_id, branch_id, entry_no, entry_date, source_type, source_id, memo, reference, approved_by,
                              reversal_of, prev_hash, hash, created_by)
  values (p_tenant, p_branch, coalesce(v_no, 0) + 1, coalesce(p_date, current_date), p_source, p_source_id, p_memo, p_reference,
          p_approved_by, p_reversal_of, v_prev, null, auth.uid())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'debit')::bigint,0) = 0 and coalesce((l->>'credit')::bigint,0) = 0 then continue; end if;
    if (l->>'debit')::bigint < 0 or (l->>'credit')::bigint < 0 then raise exception 'negative journal amount'; end if;
    if l ? 'account_id' then
      select id into v_acct from accounts where id = (l->>'account_id')::uuid and tenant_id = p_tenant;
      if v_acct is null then raise exception 'unknown account'; end if;
    else
      v_acct := _acct(p_tenant, l->>'key');
    end if;
    v_branch := coalesce(nullif(l->>'branch_id','')::uuid, p_branch);
    v_cc := nullif(l->>'cost_center_id','')::uuid;
    if v_cc is not null and not exists (select 1 from cost_centers where id = v_cc and tenant_id = p_tenant) then raise exception 'unknown cost centre'; end if;
    if v_cc is null and v_branch is not null then
      select id into v_cc from cost_centers where tenant_id = p_tenant and branch_id = v_branch and is_active order by code limit 1;
    end if;
    insert into journal_lines(tenant_id, entry_id, account_id, branch_id, debit, credit, customer_id, supplier_id, cost_center_id)
    values (p_tenant, v_id, v_acct, v_branch,
            coalesce((l->>'debit')::bigint,0), coalesce((l->>'credit')::bigint,0),
            nullif(l->>'customer_id','')::uuid, nullif(l->>'supplier_id','')::uuid, v_cc);
  end loop;
  update journal_entries set hash = _entry_digest(v_id) where id = v_id;
  return v_id;
end $$;

/** Profit and loss for one cost centre (income − expenses of the lines tagged with it). */
create or replace function public.fin_income_statement_cc(p_tenant uuid, p_from date, p_to date, p_cost_center uuid)
returns table(section text, code text, name_en text, name_ar text, amount bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_perm(p_tenant, 'finance.view') then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select a.section, a.code, a.name_en, a.name_ar,
         sum(case when a.section in ('revenue','other_income') then l.credit - l.debit else l.debit - l.credit end)::bigint
    from journal_lines l join journal_entries e on e.id = l.entry_id join accounts a on a.id = l.account_id
   where l.tenant_id = p_tenant and e.entry_date between p_from and p_to and l.cost_center_id = p_cost_center
     and a.section in ('revenue','other_income','cogs','operating_expense','other_expense')
   group by 1,2,3,4 having sum(l.debit - l.credit) <> 0 order by 2;
end $$;
grant execute on function public.fin_income_statement_cc(uuid, date, date, uuid) to authenticated;

-- record_expense: optional cost centre on the expense line
create or replace function public.record_expense(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; a accounts%rowtype;
        v_amt bigint := (p->>'amount')::bigint; v_vat bigint := coalesce((p->>'vat')::bigint, 0); v_from text := p->>'paid_from';
        v_sup uuid := nullif(p->>'supplier_id','')::uuid; v_id uuid := gen_random_uuid(); v_entry bigint;
begin
  if not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'expenses.create', null, null);
  select * into a from accounts where id = (p->>'account_id')::uuid and tenant_id = v_tenant and is_active;
  if not found or a.section not in ('operating_expense','other_expense','cogs','non_current_asset','current_asset') or a.system_key in ('cash','bank','ar','inventory','card_clearing','gateway_clearing','other_clearing','petty_cash','vat_input','cash_safe','exchange_clearing') then
    raise exception 'choose an expense or asset account' using errcode = 'ZT422'; end if;
  if coalesce(trim(p->>'description'),'') = '' then raise exception 'a description is required' using errcode = 'ZT422'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'amount must be positive' using errcode = 'ZT422'; end if;
  if v_from not in ('cash','petty_cash','bank','ap') then raise exception 'unknown payment source' using errcode = 'ZT422'; end if;
  if v_from = 'ap' and v_sup is null then raise exception 'choose the supplier for an unpaid bill' using errcode = 'ZT422'; end if;
  if v_sup is not null and not exists (select 1 from suppliers where id = v_sup and tenant_id = v_tenant) then raise exception 'unknown supplier'; end if;

  v_entry := _post_ex(v_tenant, v_branch, 'expense', v_id, p->>'description', jsonb_build_array(
      jsonb_build_object('account_id', a.id, 'debit', v_amt, 'cost_center_id', nullif(p->>'cost_center_id','')),
      jsonb_build_object('key', 'vat_input', 'debit', v_vat),
      jsonb_build_object('key', v_from, 'credit', v_amt + v_vat, 'supplier_id', case when v_from = 'ap' then v_sup end)),
    coalesce(nullif(p->>'entry_date','')::date, current_date), nullif(p->>'reference',''));
  insert into expenses(id, tenant_id, branch_id, entry_date, account_id, supplier_id, description, amount, vat, total, paid_from, reference, entry_id, created_by)
  values (v_id, v_tenant, v_branch, coalesce(nullif(p->>'entry_date','')::date, current_date), a.id, v_sup, p->>'description', v_amt, v_vat,
          v_amt + v_vat, v_from, nullif(p->>'reference',''), v_entry, auth.uid());
  perform _audit(v_tenant, v_branch, 'expense.record', 'expense', v_id, v_amt + v_vat, p->>'description', null);
  return v_id;
end $$;

-- ================================================================ petty cash
/** Top up the petty cash box from the bank or the safe; spending from it is recorded as an expense paid from petty cash. */
create or replace function public.petty_topup(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid := (p->>'tenant_id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_amt bigint := (p->>'amount')::bigint; v_from text := coalesce(p->>'from','bank');
begin
  if not can_see_branch(v_tenant, v_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(v_tenant, 'payables.pay', null, null);
  if v_amt is null or v_amt <= 0 then raise exception 'amount must be positive' using errcode = 'ZT422'; end if;
  if v_from not in ('bank','cash_safe') then raise exception 'top up from the bank or the safe' using errcode = 'ZT422'; end if;
  return _post_ex(v_tenant, v_branch, 'petty_topup', null, coalesce(nullif(p->>'note',''), 'Petty cash top-up'), jsonb_build_array(
    jsonb_build_object('key','petty_cash','debit', v_amt), jsonb_build_object('key', v_from, 'credit', v_amt)), current_date, nullif(p->>'reference',''));
end $$;
grant execute on function public.petty_topup(jsonb) to authenticated;

-- ================================================================ cash flow statement (direct method)
/**
 * Every movement of cash and bank, classified by what was on the other side of the entry:
 * operating (sales, expenses, customers, suppliers, VAT, stock, salaries), investing (non-current assets), financing (equity, loans).
 * When an entry has several non-cash lines, the cash is shared between them in proportion.
 */
create or replace function public.fin_cash_flow(p_tenant uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_cash text[] := array['cash','cash_safe','petty_cash','bank']; v_open bigint; v_close bigint; v_rows jsonb;
begin
  if not has_perm(p_tenant, 'finance.view') then raise exception 'not allowed' using errcode = '42501'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into v_open from journal_lines l join journal_entries e on e.id = l.entry_id join accounts a on a.id = l.account_id
   where l.tenant_id = p_tenant and a.system_key = any(v_cash) and e.entry_date < p_from and (p_branch is null or l.branch_id = p_branch);
  with ent as (
    select e.id, sum(case when a.system_key = any(v_cash) then l.debit - l.credit else 0 end) as cash
      from journal_entries e join journal_lines l on l.entry_id = e.id join accounts a on a.id = l.account_id
     where e.tenant_id = p_tenant and e.entry_date between p_from and p_to and (p_branch is null or l.branch_id = p_branch)
     group by e.id having sum(case when a.system_key = any(v_cash) then l.debit - l.credit else 0 end) <> 0
  ), other as (
    select ent.id, ent.cash, a.section, a.system_key, a.code, a.name_en, a.name_ar, (l.credit - l.debit) as amt,
           sum(abs(l.credit - l.debit)) over (partition by ent.id) as tot
      from ent join journal_lines l on l.entry_id = ent.id join accounts a on a.id = l.account_id
     where (a.system_key is null or not (a.system_key = any(v_cash))) and (l.credit - l.debit) * sign(ent.cash) > 0
  ), alloc as (
    select case when section in ('non_current_asset','contra_asset') then 'investing'
                when section in ('equity','non_current_liability') then 'financing' else 'operating' end as activity,
           code, name_en, name_ar,
           round(cash::numeric * abs(amt) / nullif(tot, 0))::bigint as flow
      from other where tot <> 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('activity', activity, 'code', code, 'name_en', name_en, 'name_ar', name_ar, 'amount', amount) order by activity, code), '[]')
    into v_rows from (select activity, code, name_en, name_ar, sum(flow)::bigint amount from alloc group by 1,2,3,4 having sum(flow) <> 0) x;
  select coalesce(sum(l.debit - l.credit), 0) into v_close from journal_lines l join journal_entries e on e.id = l.entry_id join accounts a on a.id = l.account_id
   where l.tenant_id = p_tenant and a.system_key = any(v_cash) and e.entry_date <= p_to and (p_branch is null or l.branch_id = p_branch);
  return jsonb_build_object('opening', v_open, 'closing', v_close, 'rows', v_rows);
end $$;
grant execute on function public.fin_cash_flow(uuid, date, date, uuid) to authenticated;

-- ================================================================ bank reconciliation
create table public.bank_statement_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  account_id      uuid not null references public.accounts(id),
  line_date       date not null,
  description     text,
  reference       text,
  amount          bigint not null,          -- + money in, − money out
  journal_line_id bigint unique references public.journal_lines(id),
  matched_by      uuid,
  matched_at      timestamptz,
  created_at      timestamptz not null default now()
);
create index on public.bank_statement_lines(tenant_id, account_id, line_date);
alter table public.bank_statement_lines enable row level security;
create policy bsl_read on public.bank_statement_lines for select using (has_perm(tenant_id, 'finance.view'));
grant select on public.bank_statement_lines to authenticated;

/** Import statement lines (from the bank's CSV) and match them to the ledger: same amount, within 3 days, one to one. */
create or replace function public.import_bank_lines(p_tenant uuid, p_account uuid, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_in int := 0; v_m int;
begin
  perform _require(p_tenant, 'finance.journal', null, null);
  if not exists (select 1 from accounts where id = p_account and tenant_id = p_tenant and section = 'current_asset') then raise exception 'choose a bank account'; end if;
  insert into bank_statement_lines(tenant_id, account_id, line_date, description, reference, amount)
  select p_tenant, p_account, (x->>'date')::date, nullif(x->>'description',''), nullif(x->>'reference',''), (x->>'amount')::bigint
    from jsonb_array_elements(p_lines) x where (x->>'amount')::bigint <> 0;
  get diagnostics v_in = row_count;
  v_m := bank_auto_match(p_tenant, p_account);
  return jsonb_build_object('imported', v_in, 'matched', v_m);
end $$;

create or replace function public.bank_auto_match(p_tenant uuid, p_account uuid) returns int
language plpgsql security definer set search_path = public as $$
declare s record; v_jl bigint; v_n int := 0;
begin
  perform _require(p_tenant, 'finance.journal', null, null);
  for s in select * from bank_statement_lines where tenant_id = p_tenant and account_id = p_account and journal_line_id is null order by line_date loop
    select l.id into v_jl from journal_lines l join journal_entries e on e.id = l.entry_id
     where l.tenant_id = p_tenant and l.account_id = p_account and (l.debit - l.credit) = s.amount
       and e.entry_date between s.line_date - 3 and s.line_date + 3
       and not exists (select 1 from bank_statement_lines b where b.journal_line_id = l.id)
     order by abs(e.entry_date - s.line_date), l.id limit 1;
    if v_jl is not null then
      update bank_statement_lines set journal_line_id = v_jl, matched_by = auth.uid(), matched_at = now() where id = s.id; v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

create or replace function public.bank_match(p_line uuid, p_journal_line bigint) returns void
language plpgsql security definer set search_path = public as $$
declare s bank_statement_lines%rowtype;
begin
  select * into s from bank_statement_lines where id = p_line for update;
  if not found then raise exception 'line not found'; end if;
  perform _require(s.tenant_id, 'finance.journal', null, null);
  if p_journal_line is not null and not exists (select 1 from journal_lines where id = p_journal_line and tenant_id = s.tenant_id and account_id = s.account_id and debit - credit = s.amount) then
    raise exception 'the ledger line must be on the same account with the same amount' using errcode = 'ZT422'; end if;
  update bank_statement_lines set journal_line_id = p_journal_line, matched_by = auth.uid(), matched_at = now() where id = s.id;
end $$;

/** Reconciliation as of a date: ledger balance, statement total, and what is still open on each side. */
create or replace function public.bank_reconciliation(p_tenant uuid, p_account uuid, p_as_of date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_perm(p_tenant, 'finance.view') then raise exception 'not allowed' using errcode = '42501'; end if;
  return jsonb_build_object(
    'book_balance', (select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join journal_entries e on e.id = l.entry_id
                      where l.tenant_id = p_tenant and l.account_id = p_account and e.entry_date <= p_as_of),
    'statement_total', (select coalesce(sum(amount), 0) from bank_statement_lines where tenant_id = p_tenant and account_id = p_account and line_date <= p_as_of),
    'unmatched_statement', (select coalesce(jsonb_agg(to_jsonb(b) order by b.line_date), '[]') from bank_statement_lines b
                             where b.tenant_id = p_tenant and b.account_id = p_account and b.journal_line_id is null and b.line_date <= p_as_of),
    'unmatched_book', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'date', e.entry_date, 'entry_no', e.entry_no, 'memo', e.memo, 'reference', e.reference, 'amount', l.debit - l.credit) order by e.entry_date), '[]')
                        from journal_lines l join journal_entries e on e.id = l.entry_id
                       where l.tenant_id = p_tenant and l.account_id = p_account and e.entry_date <= p_as_of
                         and not exists (select 1 from bank_statement_lines b where b.journal_line_id = l.id)),
    'matched', (select count(*) from bank_statement_lines where tenant_id = p_tenant and account_id = p_account and journal_line_id is not null));
end $$;
grant execute on function public.import_bank_lines(uuid, uuid, jsonb), public.bank_auto_match(uuid, uuid), public.bank_match(uuid, bigint),
                          public.bank_reconciliation(uuid, uuid, date) to authenticated;

-- serials / quotations modules are now built
update public.feature_modules set built = true where key in ('serials','quotations');

-- ================================================================ checkout, refunds and receipts re-issued
-- complete_sale: price lists, price change permission (sale.price), cash ceiling, serial numbers, invoicing a sales document
CREATE OR REPLACE FUNCTION public.complete_sale(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  t tenants%rowtype;
  v_branch uuid := (p->>'branch_id')::uuid;
  v_shift uuid := nullif(p->>'shift_id','')::uuid;
  v_client uuid := (p->>'client_id')::uuid;
  v_customer uuid := nullif(p->>'customer_id','')::uuid;
  v_at timestamptz := coalesce(nullif(p->>'device_created_at','')::timestamptz, now());
  v_existing uuid; v_sale uuid; v_number text; v_appr uuid;
  l jsonb; it items%rowtype; pay jsonb; cp customer_packages%rowtype; w work_orders%rowtype; oo open_orders%rowtype;
  v_qty numeric; v_price bigint; v_list_price bigint; v_disc bigint; v_promo bigint; v_pkg_disc bigint; v_rate numeric; v_gross bigint; v_tax bigint; v_net bigint; v_total_line bigint;
  v_list bigint := 0; v_manual bigint := 0; v_promo_total bigint := 0; v_pkg_total bigint := 0;
  v_sub bigint := 0; v_sub_deferred bigint := 0; v_taxsum bigint := 0; v_total bigint := 0; v_cogs bigint := 0;
  v_paysum bigint := 0; v_captured bigint := 0; v_credit_use bigint := 0; v_sc_use bigint := 0; v_loyalty bigint := 0; v_dep bigint := 0;
  v_lines jsonb := '[]'; v_je jsonb := '[]'; v_pid uuid; v_tender tender_type; v_amt bigint; v_ucost bigint; v_track boolean;
  v_pre jsonb := '[]'; v_allow jsonb; v_idx int := 0; v_mods jsonb; v_mod_add bigint; v_mod_cost bigint; v_mod_names text; v_mod_ar text;
  v_pkg_value bigint; v_tender_list jsonb := '[]'; v_point_value numeric; v_points int; v_earn_base bigint; g record; v_cnt int;
  v_sub_gift bigint := 0; gc gift_cards%rowtype; v_gift_use jsonb := '[]'; v_cod bigint := 0; v_code text; oq online_orders%rowtype;
  v_override boolean := false; v_cashsum bigint := 0; v_slid uuid; v_ser text[]; v_n int;
begin
  select * into t from tenants where id = (p->>'tenant_id')::uuid;
  if not found or not is_member(t.id) then raise exception 'not a member of this business' using errcode = '42501'; end if;
  if not can_see_branch(t.id, v_branch) or not exists (select 1 from branches where id = v_branch and tenant_id = t.id) then
    raise exception 'branch not allowed' using errcode = '42501'; end if;
  perform _require(t.id, 'sale.create', null, null);

  -- idempotency: replays from the offline outbox return the original sale
  select id into v_existing from sales where tenant_id = t.id and client_id = v_client;
  if v_existing is not null then return sale_json(v_existing); end if;

  if v_shift is not null and not exists (select 1 from shifts where id = v_shift and branch_id = v_branch and closed_at is null) then v_shift := null; end if;
  if v_customer is not null and not exists (select 1 from customers where id = v_customer and tenant_id = t.id) then raise exception 'unknown customer'; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'empty sale'; end if;

  -- ---- pass 1: list prices with add-ons, for the promotion engine
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_idx := v_idx + 1;
    select coalesce(sum(o.price), 0) into v_mod_add from modifier_options o
     where o.tenant_id = t.id and o.id in (select jsonb_array_elements_text((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end))::uuid);
    select * into it from items where id = nullif(l->>'item_id','')::uuid and tenant_id = t.id;
    v_pre := v_pre || jsonb_build_object('idx', v_idx, 'item_id', it.id, 'qty', (l->>'qty')::numeric,
              'gross', round((l->>'qty')::numeric * coalesce((l->>'unit_price')::bigint, coalesce(_list_price(t.id, v_customer, it.id), it.price, 0) + v_mod_add)));
  end loop;
  v_allow := case when has_feature(t.id, 'promotions') then promo_allowance(t.id, v_at, v_pre, p->>'coupon') else '[]' end;

  -- ---- pass 2: price every line
  v_idx := 0;
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_idx := v_idx + 1;
    it := null; cp := null;
    if nullif(l->>'item_id','') is not null then
      select * into it from items where id = (l->>'item_id')::uuid and tenant_id = t.id;
      if not found then raise exception 'unknown item %', l->>'item_id'; end if;
    end if;
    if it.item_type = 'ingredient' then raise exception 'ingredients are not sold directly: %', it.name using errcode = 'ZT422'; end if;
    if it.is_template then raise exception 'choose a size or colour for %', it.name using errcode = 'ZT422'; end if;
    if it.item_type = 'package' and v_customer is null then raise exception 'choose the customer who buys the package' using errcode = 'ZT422'; end if;
    if it.item_type = 'gift_card' then
      perform _require_feature(t.id, 'gift_cards');
      if coalesce((l->>'unit_price')::bigint, 0) <= 0 then raise exception 'enter the gift card amount' using errcode = 'ZT422'; end if;
    end if;
    v_qty := (l->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'quantity must be positive'; end if;

    -- add-ons: valid options of this item's groups; required groups must be answered
    select coalesce(jsonb_agg(jsonb_build_object('option_id', o.id, 'name', o.name, 'name_ar', o.name_ar, 'price', o.price) order by g2.sort, o.sort), '[]'),
           coalesce(sum(o.price), 0), coalesce(sum(round(o.qty * coalesce(oi.cost, 0))), 0),
           string_agg(o.name, ', ' order by g2.sort, o.sort), string_agg(coalesce(o.name_ar, o.name), '، ' order by g2.sort, o.sort)
      into v_mods, v_mod_add, v_mod_cost, v_mod_names, v_mod_ar
      from modifier_options o join modifier_groups g2 on g2.id = o.group_id
      join item_modifier_groups ig on ig.group_id = g2.id and ig.item_id = it.id
      left join items oi on oi.id = o.item_id
     where o.tenant_id = t.id and o.is_active and o.id in (select jsonb_array_elements_text((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end))::uuid);
    if jsonb_array_length(v_mods) < jsonb_array_length((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end)) then raise exception 'an add-on does not belong to %', it.name using errcode = 'ZT422'; end if;
    for g in select g3.name, g3.min_select, g3.max_select, (select count(*) from jsonb_array_elements(v_mods) m join modifier_options mo on mo.id = (m->>'option_id')::uuid where mo.group_id = g3.id) as n
               from item_modifier_groups ig2 join modifier_groups g3 on g3.id = ig2.group_id where ig2.item_id = it.id loop
      if g.n < g.min_select or g.n > g.max_select then raise exception 'choose % for %', g.name, it.name using errcode = 'ZT422'; end if;
    end loop;

    v_ucost := case when it.item_type = 'recipe' then recipe_cost(it.id) else coalesce(it.cost, 0) end + v_mod_cost;
    v_track := coalesce(it.track_stock, false) and coalesce(it.item_type, 'standard') = 'standard';
    v_list_price := coalesce(_list_price(t.id, v_customer, it.id), it.price, 0) + v_mod_add;
    v_price := coalesce((l->>'unit_price')::bigint, v_list_price);
    -- a typed price on a catalogue item is a price change (gift cards and open items are priced at the till)
    if it.id is not null and it.item_type <> 'gift_card' and v_price <> v_list_price then v_override := true; end if;
    -- serial / IMEI: one in-stock number per unit
    v_ser := null;
    if coalesce(it.track_serial, false) then
      v_ser := array(select upper(trim(x)) from jsonb_array_elements_text(case when jsonb_typeof(l->'serials') = 'array' then l->'serials' else '[]'::jsonb end) x where trim(x) <> '');
      if v_qty <> floor(v_qty) or coalesce(array_length(v_ser, 1), 0) <> v_qty or (select count(distinct x) from unnest(v_ser) x) <> v_qty then
        raise exception 'scan one serial number per unit of %', it.name using errcode = 'ZT422'; end if;
      if (select count(*) from item_serials where tenant_id = t.id and item_id = it.id and status = 'in_stock' and upper(serial) = any(v_ser)) <> v_qty then
        raise exception 'serial number not in stock for %', it.name using errcode = 'ZT422'; end if;
    end if;
    v_disc  := coalesce((l->>'discount')::bigint, 0);
    if v_price < 0 or v_disc < 0 then raise exception 'negative price or discount'; end if;
    -- promotion: what the POS claims, capped at what the rules allow for this line
    v_promo := least(greatest(coalesce((l->>'promo_discount')::bigint, 0), 0),
                     coalesce((select (x->>'discount')::bigint from jsonb_array_elements(v_allow) x where (x->>'idx')::int = v_idx), 0));
    v_rate  := coalesce(it.tax_rate, t.vat_rate);
    -- a gift card is a voucher for later purchases: no VAT now, the money is owed to the holder
    if it.item_type = 'gift_card' then v_rate := 0; v_promo := 0; end if;

    -- a session from a prepaid package: the line is valued at the package's price per session, VAT was charged when it was sold
    v_pkg_disc := 0; v_pkg_value := null;
    if nullif(l->>'customer_package_id','') is not null then
      select * into cp from customer_packages where id = (l->>'customer_package_id')::uuid and tenant_id = t.id for update;
      if not found or cp.customer_id is distinct from v_customer then raise exception 'this package belongs to another customer' using errcode = 'ZT422'; end if;
      if cp.status <> 'active' or cp.expires_on < v_at::date then raise exception 'the package has expired or is used up' using errcode = 'ZT422'; end if;
      if cp.covers is not null and not (it.id = any(cp.covers)) then raise exception 'the package does not cover %', it.name using errcode = 'ZT422'; end if;
      if cp.kind <> 'sessions' or v_qty <> floor(v_qty) or cp.sessions_used + v_qty > cp.sessions_total then
        raise exception 'not enough sessions left in the package' using errcode = 'ZT422'; end if;
      v_pkg_value := least(package_session_value(cp.id, v_qty::int), round(v_qty * v_price)::bigint);
      v_pkg_disc := round(v_qty * v_price)::bigint - v_pkg_value; v_promo := 0; v_disc := 0; v_rate := 0;
      update customer_packages set sessions_used = sessions_used + v_qty::int, released = released + v_pkg_value,
             status = case when sessions_used + v_qty::int >= sessions_total then 'used' else status end where id = cp.id;
      v_pkg_total := v_pkg_total + v_pkg_value;
    end if;

    v_gross := round(v_qty * v_price)::bigint - v_disc - v_promo - v_pkg_disc;
    if v_gross < 0 then raise exception 'discount larger than line'; end if;
    if t.prices_include_tax then
      v_tax := round(v_gross * v_rate / (100 + v_rate))::bigint; v_net := v_gross - v_tax; v_total_line := v_gross;
    else
      v_net := v_gross; v_tax := round(v_net * v_rate / 100)::bigint; v_total_line := v_net + v_tax;
    end if;
    v_list := v_list + round(v_qty * v_list_price)::bigint;
    v_manual := v_manual + v_disc + greatest(round(v_qty * (v_list_price - v_price))::bigint, 0);
    v_promo_total := v_promo_total + v_promo;
    v_sub := v_sub + v_net; v_taxsum := v_taxsum + v_tax; v_total := v_total + v_total_line;
    if it.item_type = 'package' then v_sub_deferred := v_sub_deferred + v_net; end if;
    if it.item_type = 'gift_card' then v_sub_gift := v_sub_gift + v_net; end if;
    if it.id is not null and (v_track or it.item_type = 'recipe' or v_mod_cost > 0) then v_cogs := v_cogs + round(v_qty * v_ucost)::bigint; end if;
    if nullif(l->>'staff_id','') is not null and not exists (select 1 from memberships where tenant_id = t.id and user_id = (l->>'staff_id')::uuid) then
      raise exception 'unknown staff member'; end if;
    v_lines := v_lines || jsonb_build_object('item_id', it.id, 'item_type', it.item_type,
      'name', coalesce(nullif(l->>'name',''), it.name, 'Item') || coalesce(' (' || v_mod_names || ')', ''),
      'qty', v_qty, 'unit_price', v_price, 'discount', v_disc + v_pkg_disc, 'tax_rate', v_rate, 'net', v_net, 'tax', v_tax,
      'total', v_total_line, 'unit_cost', v_ucost, 'track', v_track, 'note', nullif(l->>'note',''), 'modifiers', case when jsonb_array_length(v_mods) > 0 then v_mods end,
      'staff_id', nullif(l->>'staff_id',''), 'promo_id', case when v_promo > 0 then (select x->>'promo_id' from jsonb_array_elements(v_allow) x where (x->>'idx')::int = v_idx) end,
      'promo_discount', v_promo, 'customer_package_id', cp.id, 'pkg_value', v_pkg_value, 'gift_code', nullif(upper(trim(l->>'gift_code')),''), 'serials', to_jsonb(v_ser), 'warranty', it.warranty_months);
  end loop;

  -- ---- manual discount / price override approval (promotions and package sessions need none)
  if v_manual > 0 then
    v_appr := _require(t.id, 'sale.discount', round(v_manual * 100.0 / nullif(v_list,0), 2), p->>'approver_pin');
  end if;

  if v_override then
    v_appr := coalesce(_require(t.id, 'sale.price', null, p->>'approver_pin'), v_appr);
  end if;

  -- ---- server-side tenders: package sessions, then the deposit of the job / pre-order
  if v_pkg_total > 0 then v_tender_list := v_tender_list || jsonb_build_object('tender', 'package', 'amount', v_pkg_total); end if;
  if nullif(p->>'work_order_id','') is not null then
    select * into w from work_orders where id = (p->>'work_order_id')::uuid and tenant_id = t.id for update;
    if not found or w.status in ('collected','cancelled') then raise exception 'this order is closed' using errcode = 'ZT422'; end if;
    v_dep := least(w.deposit_paid - w.deposit_used, v_total - v_pkg_total);
    if v_dep > 0 then v_tender_list := v_tender_list || jsonb_build_object('tender', 'deposit', 'amount', v_dep); end if;
  end if;

  -- ---- tenders from the POS
  for pay in select * from jsonb_array_elements(coalesce(p->'payments','[]')) loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    if v_amt is null or v_amt <= 0 then raise exception 'payment amounts must be positive'; end if;
    if v_tender in ('package','deposit') then raise exception 'package and deposit amounts are applied automatically' using errcode = 'ZT422'; end if;
    v_paysum := v_paysum + v_amt;
    if v_tender = 'cash' then v_cashsum := v_cashsum + v_amt; end if;
    if v_tender in ('on_account','payment_link','store_credit','loyalty') and v_customer is null then
      raise exception 'choose a customer for % payments', v_tender; end if;
    if v_tender = 'on_account' then v_credit_use := v_credit_use + v_amt; end if;
    if v_tender = 'store_credit' then v_sc_use := v_sc_use + v_amt; end if;
    if v_tender = 'loyalty' then v_loyalty := v_loyalty + v_amt; end if;
    if v_tender = 'gift_card' then
      v_code := upper(trim(coalesce(pay->>'reference','')));
      select * into gc from gift_cards where tenant_id = t.id and code = v_code for update;
      if not found or gc.status <> 'active' or (gc.expires_on is not null and gc.expires_on < v_at::date) then raise exception 'gift card % is not valid', v_code using errcode = 'ZT422'; end if;
      if gc.balance - coalesce((select sum((x->>'amount')::bigint) from jsonb_array_elements(v_gift_use) x where x->>'id' = gc.id::text), 0) < v_amt then
        raise exception 'gift card % has only %', v_code, gc.balance using errcode = 'ZT422'; end if;
      v_gift_use := v_gift_use || jsonb_build_object('id', gc.id, 'amount', v_amt);
    end if;
    if v_tender = 'cod' then
      perform _require_feature(t.id, 'own_delivery');
      if jsonb_typeof(p->'delivery') <> 'object' then raise exception 'cash on delivery needs a delivery address' using errcode = 'ZT422'; end if;
      v_cod := v_cod + v_amt;
    end if;
    v_tender_list := v_tender_list || jsonb_build_object('tender', v_tender, 'amount', v_amt, 'reference', pay->>'reference', 'method', left(nullif(pay->>'method',''), 40));
  end loop;
  if v_paysum + v_pkg_total + v_dep <> v_total then
    raise exception 'payments (%) must equal the total (%)', v_paysum, v_total - v_pkg_total - v_dep using errcode = 'ZT422'; end if;
  -- cash ceiling per invoice (a setting: off / warn on the till / block here)
  if coalesce(t.settings->>'cash_limit_mode', 'off') = 'block' and coalesce((t.settings->>'cash_limit')::bigint, 0) > 0
     and v_cashsum > (t.settings->>'cash_limit')::bigint then
    raise exception 'CASH_LIMIT: cash above % is not accepted on one invoice; use card or K-Net for the rest', (t.settings->>'cash_limit') using errcode = 'ZT422'; end if;
  if v_credit_use > 0 and customer_balance(v_customer) + v_credit_use > (select credit_limit from customers where id = v_customer) then
    v_appr := coalesce(_require(t.id, 'sale.over_credit', null, p->>'approver_pin'), v_appr);
  end if;
  if v_sc_use > customer_store_credit(v_customer) then raise exception 'not enough store credit'; end if;
  if v_loyalty > 0 then
    perform _require_feature(t.id, 'loyalty');
    v_point_value := coalesce((t.settings->>'loyalty_point_value')::numeric, 0);
    if v_point_value <= 0 then raise exception 'set the value of a point in Settings first' using errcode = 'ZT422'; end if;
    v_points := ceil(v_loyalty / v_point_value);
    if v_points > customer_points(v_customer) then raise exception 'not enough points' using errcode = 'ZT422'; end if;
    if v_points < coalesce((t.settings->>'loyalty_min_points')::int, 0) then
      raise exception 'redeem at least % points', (t.settings->>'loyalty_min_points') using errcode = 'ZT422'; end if;
  end if;

  -- ---- write documents
  v_number := _next_number(t.id, v_branch, 'invoice');
  insert into sales(tenant_id, branch_id, shift_id, client_id, doc_type, number, customer_id, subtotal, discount_total,
                    tax_total, total, paid_total, approved_by, created_by, device_created_at, reason, channel_id, external_ref)
  values (t.id, v_branch, v_shift, v_client, 'invoice', v_number, v_customer, v_sub, v_manual + v_promo_total, v_taxsum, v_total, 0,
          v_appr, auth.uid(), nullif(p->>'device_created_at','')::timestamptz, nullif(p->>'note',''),
          (select id from delivery_channels where id = nullif(p->>'channel_id','')::uuid and tenant_id = t.id),
          case when nullif(p->>'channel_id','') is not null then nullif(p->>'external_ref','') end)
  returning id into v_sale;

  for l in select * from jsonb_array_elements(v_lines) loop
    insert into sale_lines(tenant_id, sale_id, item_id, name, qty, unit_price, discount, tax_rate, net_amount, tax_amount, line_total, unit_cost, note,
                           modifiers, staff_id, promo_id, promo_discount, customer_package_id)
    values (t.id, v_sale, nullif(l->>'item_id','')::uuid, l->>'name', (l->>'qty')::numeric, (l->>'unit_price')::bigint,
            (l->>'discount')::bigint, (l->>'tax_rate')::numeric, (l->>'net')::bigint, (l->>'tax')::bigint, (l->>'total')::bigint,
            (l->>'unit_cost')::bigint, nullif(l->>'note',''), nullif(l->'modifiers', 'null'::jsonb), nullif(l->>'staff_id','')::uuid,
            nullif(l->>'promo_id','')::uuid, (l->>'promo_discount')::bigint, nullif(l->>'customer_package_id','')::uuid)
    returning id into v_slid;
    if jsonb_typeof(l->'serials') = 'array' then
      update item_serials set status = 'sold', sale_id = v_sale, sale_line_id = v_slid, sold_at = now(), branch_id = v_branch,
             warranty_until = case when (l->>'warranty')::int > 0 then current_date + make_interval(months => (l->>'warranty')::int) end
       where tenant_id = t.id and item_id = (l->>'item_id')::uuid and status = 'in_stock'
         and upper(serial) in (select jsonb_array_elements_text(l->'serials'));
    end if;
    if (l->>'track')::boolean then
      insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, created_by)
      values (t.id, v_branch, (l->>'item_id')::uuid, -(l->>'qty')::numeric, 'sale', v_sale, (select cost from items where id = (l->>'item_id')::uuid), auth.uid());
    end if;
    -- add-ons that use stock (oat milk, extra cheese)
    insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
    select t.id, v_branch, o.item_id, -(o.qty * (l->>'qty')::numeric), 'sale', v_sale, oi.cost, 'add-on', auth.uid()
      from jsonb_array_elements((case when jsonb_typeof(l->'modifiers') = 'array' then l->'modifiers' else '[]'::jsonb end)) m join modifier_options o on o.id = (m->>'option_id')::uuid
      join items oi on oi.id = o.item_id and oi.track_stock
     where o.qty > 0;
    if nullif(l->>'customer_package_id','') is not null then
      insert into package_uses(tenant_id, package_id, sale_id, sessions, amount, used_by)
      values (t.id, (l->>'customer_package_id')::uuid, v_sale, (l->>'qty')::numeric::int, (l->>'pkg_value')::bigint, auth.uid());
    end if;
    -- a package sold: the customer gets it; its net value waits in deferred revenue
    if l->>'item_type' = 'package' then
      insert into customer_packages(tenant_id, customer_id, item_id, name, kind, sessions_total, price_paid, covers, sale_id, starts_on, expires_on)
      select t.id, v_customer, d.item_id, l->>'name', d.kind, case when d.kind = 'sessions' then d.sessions * (l->>'qty')::numeric::int end,
             (l->>'net')::bigint, d.covers, v_sale, v_at::date, v_at::date + d.validity_days
        from package_defs d where d.item_id = (l->>'item_id')::uuid;
      if not found then raise exception 'set up what the package % includes first', l->>'name' using errcode = 'ZT422'; end if;
    end if;
    -- a gift card sold: one card per unit, with the code on the pre-printed card or a new one
    if l->>'item_type' = 'gift_card' then
      for v_cnt in 1 .. greatest((l->>'qty')::numeric::int, 1) loop
        v_code := case when v_cnt = 1 and l->>'gift_code' is not null then l->>'gift_code' else 'GC' || upper(encode(gen_random_bytes(5), 'hex')) end;
        begin
          insert into gift_cards(tenant_id, code, initial, balance, customer_id, sale_id, expires_on)
          values (t.id, v_code, (l->>'total')::bigint / greatest((l->>'qty')::numeric::int, 1), (l->>'total')::bigint / greatest((l->>'qty')::numeric::int, 1), v_customer, v_sale,
                  case when coalesce((t.settings->>'gift_card_months')::int, 0) > 0 then v_at::date + make_interval(months => (t.settings->>'gift_card_months')::int) end)
          returning * into gc;
        exception when unique_violation then raise exception 'gift card code % is already used', v_code using errcode = 'ZT422'; end;
        insert into gift_card_moves(tenant_id, card_id, sale_id, amount, kind) values (t.id, gc.id, v_sale, gc.initial, 'issue');
      end loop;
    end if;
  end loop;

  for pay in select * from jsonb_array_elements(v_tender_list) loop
    v_tender := (pay->>'tender')::tender_type; v_amt := (pay->>'amount')::bigint;
    insert into payments(tenant_id, sale_id, tender, amount, reference, method, status, shift_id, created_by)
    values (t.id, v_sale, v_tender, v_amt, nullif(pay->>'reference',''), pay->>'method',
            case when v_tender in ('payment_link','cod') then 'pending' else 'captured' end, v_shift, auth.uid())
    returning id into v_pid;
    if v_tender = 'payment_link' then insert into payment_links(tenant_id, sale_id, payment_id, amount) values (t.id, v_sale, v_pid, v_amt); end if;
    if v_tender not in ('on_account','payment_link','cod') then v_captured := v_captured + v_amt; end if;
    v_je := v_je || jsonb_build_object('key', _tender_account(v_tender), 'debit', v_amt,
              'customer_id', case when v_tender in ('on_account','payment_link','store_credit','deposit') then v_customer end);
  end loop;
  update sales set paid_total = v_captured where id = v_sale;

  v_je := v_je || jsonb_build_array(
    jsonb_build_object('key','sales','credit', v_sub - v_sub_deferred - v_sub_gift),
    jsonb_build_object('key','gift_cards','credit', v_sub_gift),
    jsonb_build_object('key','deferred_revenue','credit', v_sub_deferred),
    jsonb_build_object('key','vat_payable','credit', v_taxsum),
    jsonb_build_object('key','cogs','debit', v_cogs),
    jsonb_build_object('key','inventory','credit', v_cogs));
  perform _post(t.id, v_branch, 'sale', v_sale, v_number, v_je);

  if v_manual > 0 then
    perform _audit(t.id, v_branch, 'sale.discount', 'sale', v_sale, v_manual, nullif(p->>'note',''), v_appr,
                   jsonb_build_object('percent', round(v_manual * 100.0 / nullif(v_list,0), 2)));
  end if;

  -- ---- gift card redemptions
  for pay in select * from jsonb_array_elements(v_gift_use) loop
    update gift_cards set balance = balance - (pay->>'amount')::bigint where id = (pay->>'id')::uuid;
    insert into gift_card_moves(tenant_id, card_id, sale_id, amount, kind) values (t.id, (pay->>'id')::uuid, v_sale, -(pay->>'amount')::bigint, 'redeem');
  end loop;

  -- ---- loyalty: redeem, then earn on what was paid with money
  if v_loyalty > 0 then
    insert into loyalty_ledger(tenant_id, customer_id, sale_id, points, kind, created_by) values (t.id, v_customer, v_sale, -v_points, 'redeem', auth.uid());
  end if;
  if v_customer is not null and has_feature(t.id, 'loyalty') and coalesce((t.settings->>'loyalty_earn')::numeric, 0) > 0 then
    v_earn_base := v_total - v_loyalty - v_pkg_total - v_dep - v_sc_use - v_sub_gift - coalesce((select sum((x->>'amount')::bigint) from jsonb_array_elements(v_gift_use) x), 0);
    v_points := floor(v_earn_base / (10 ^ t.currency_decimals) * (t.settings->>'loyalty_earn')::numeric);
    if v_points > 0 then
      insert into loyalty_ledger(tenant_id, customer_id, sale_id, points, kind, created_by) values (t.id, v_customer, v_sale, v_points, 'earn', auth.uid());
    end if;
  end if;

  -- ---- what this sale closes
  if w.id is not null then
    update work_orders set deposit_used = deposit_used + v_dep, status = 'collected', collected_at = now(), sale_id = v_sale where id = w.id;
  end if;
  if nullif(p->>'appointment_id','') is not null then
    update appointments set status = 'completed', sale_id = v_sale, updated_at = now()
     where id = (p->>'appointment_id')::uuid and tenant_id = t.id and status not in ('cancelled','completed');
  end if;
  if nullif(p->>'open_order_id','') is not null then
    select * into oo from open_orders where id = (p->>'open_order_id')::uuid and tenant_id = t.id and status = 'open' for update;
    if found then
      update open_orders set
        lines = case when p ? 'open_order_keys'
                     then coalesce((select jsonb_agg(x) from jsonb_array_elements(lines) x where not (x->>'key') in (select jsonb_array_elements_text(p->'open_order_keys'))), '[]')
                     else '[]' end,
        sale_ids = sale_ids || v_sale, updated_at = now()
       where id = oo.id;
      update open_orders set status = 'closed', closed_at = now() where id = oo.id and jsonb_array_length(lines) = 0;
    end if;
  end if;

  -- a quotation, sales order or delivery note invoiced from the till
  if nullif(p->>'sales_doc_id','') is not null then
    update sales_docs set status = 'invoiced', sale_id = v_sale, updated_at = now()
     where tenant_id = t.id and status not in ('invoiced','cancelled','rejected')
       and (id = (p->>'sales_doc_id')::uuid or id = (select source_id from sales_docs where id = (p->>'sales_doc_id')::uuid));
  end if;

  if nullif(p->>'online_order_id','') is not null then
    update online_orders set status = 'paid', sale_id = v_sale where id = (p->>'online_order_id')::uuid and tenant_id = t.id and status in ('pending','accepted');
  end if;
  -- own delivery: the order goes to a driver; cash on delivery is collected by the driver
  if jsonb_typeof(p->'delivery') = 'object' then
    perform _require_feature(t.id, 'own_delivery');
    insert into deliveries(tenant_id, branch_id, sale_id, customer_id, address, phone, note, driver_id, status, cash_to_collect, assigned_at)
    values (t.id, v_branch, v_sale, v_customer, coalesce(nullif(p->'delivery'->>'address',''), (select address from customers where id = v_customer)),
            coalesce(nullif(p->'delivery'->>'phone',''), (select phone from customers where id = v_customer)), nullif(p->'delivery'->>'note',''),
            nullif(p->'delivery'->>'driver_id','')::uuid, case when nullif(p->'delivery'->>'driver_id','') is not null then 'assigned' else 'pending' end, v_cod,
            case when nullif(p->'delivery'->>'driver_id','') is not null then now() end);
  end if;

  perform _consume_recipes(v_sale);
  if nullif(p->>'open_order_id','') is null then perform _kitchen_from_sale(v_sale, p); end if;
  return sale_json(v_sale);
end $function$;

-- refund_sale: refunded serial numbers return to stock
CREATE OR REPLACE FUNCTION public.refund_sale(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- serial numbers go back on the shelf
    update item_serials set status = 'in_stock', sale_id = null, sale_line_id = null, sold_at = null, warranty_until = null, source = v_number
     where id in (select id from item_serials where sale_line_id = (r->'line'->>'id')::uuid and status = 'sold' order by serial limit ceil((r->>'qty')::numeric)::int);
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
end $function$;

-- receive_po: serial numbers are scanned at receipt
CREATE OR REPLACE FUNCTION public.receive_po(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o purchase_orders%rowtype; ol purchase_order_lines%rowtype; it items%rowtype;
  e jsonb; v_qty numeric; v_onhand numeric; v_gr uuid; v_total bigint := 0; v_any boolean := false;
begin
  select * into o from purchase_orders where id = (p->>'po_id')::uuid for update;
  if not found or not can_see_branch(o.tenant_id, o.branch_id) then raise exception 'purchase order not found'; end if;
  perform _require(o.tenant_id, 'inventory.receive', null, null);
  if o.status not in ('approved','partially_received') then raise exception 'the order must be approved before receiving' using errcode = 'ZT422'; end if;

  insert into goods_receipts(tenant_id, po_id, branch_id, supplier_ref, note, total, received_by)
  values (o.tenant_id, o.id, o.branch_id, nullif(p->>'supplier_ref',''), nullif(p->>'note',''), 0, auth.uid())
  returning id into v_gr;

  for e in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    v_qty := (e->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then continue; end if;
    select * into ol from purchase_order_lines where id = (e->>'line_id')::uuid and po_id = o.id for update;
    if not found then raise exception 'line not on this order'; end if;
    if v_qty > ol.qty - ol.received_qty then raise exception 'cannot receive more than ordered' using errcode = 'ZT422'; end if;
    select * into it from items where id = ol.item_id for update;
    select coalesce(sum(qty),0) into v_onhand from stock_movements where item_id = it.id;
    update items set cost = case when greatest(v_onhand,0) + v_qty = 0 then ol.unit_cost
                     else round((greatest(v_onhand,0) * it.cost + v_qty * ol.unit_cost) / (greatest(v_onhand,0) + v_qty)) end
     where id = it.id;
    insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, ref_id, unit_cost, note, created_by)
    values (o.tenant_id, o.branch_id, it.id, v_qty, 'receipt', v_gr, ol.unit_cost, o.number, auth.uid());
    if coalesce(it.track_serial, false) then
      if jsonb_array_length(coalesce(e->'serials','[]')) <> v_qty then raise exception 'scan one serial number per unit of %', it.name using errcode = 'ZT422'; end if;
      begin
        insert into item_serials(tenant_id, item_id, serial, branch_id, source)
        select o.tenant_id, it.id, upper(trim(x)), o.branch_id, o.number from jsonb_array_elements_text(e->'serials') x;
      exception when unique_violation then raise exception 'a serial number of % is already registered', it.name using errcode = 'ZT422'; end;
    end if;
    update purchase_order_lines set received_qty = received_qty + v_qty where id = ol.id;
    v_total := v_total + round(v_qty * ol.unit_cost)::bigint; v_any := true;
  end loop;
  if not v_any then raise exception 'enter at least one received quantity' using errcode = 'ZT422'; end if;

  update goods_receipts set total = v_total where id = v_gr;
  update purchase_orders set status = case when exists (select 1 from purchase_order_lines where po_id = o.id and received_qty < qty)
                                           then 'partially_received' else 'received' end where id = o.id;
  perform _post(o.tenant_id, o.branch_id, 'goods_receipt', v_gr, o.number, jsonb_build_array(
    jsonb_build_object('key','inventory','debit', v_total),
    jsonb_build_object('key','ap','credit', v_total, 'supplier_id', o.supplier_id)));
  return v_gr;
end $function$;

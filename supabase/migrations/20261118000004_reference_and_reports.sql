-- Z Trust MVP · reference data (country packs v1, chart of accounts) and report views
-- Country data must be re-confirmed with each tax authority before go-live.

insert into public.countries(code, name_en, name_ar, currency, currency_decimals, vat_rate, prices_include_tax, einvoice_regime, default_language, timezone) values
  ('KW','Kuwait','الكويت','KWD',3, 0, true, null,           'ar','Asia/Kuwait'),
  ('SA','Saudi Arabia','السعودية','SAR',2,15, true, 'zatca',        'ar','Asia/Riyadh'),
  ('AE','United Arab Emirates','الإمارات','AED',2, 5, true, 'uae_asp',      'ar','Asia/Dubai'),
  ('QA','Qatar','قطر','QAR',2, 0, true, null,           'ar','Asia/Qatar'),
  ('BH','Bahrain','البحرين','BHD',3,10, true, null,           'ar','Asia/Bahrain'),
  ('OM','Oman','عُمان','OMR',3, 5, true, 'oman_fawtara', 'ar','Asia/Muscat'),
  ('EG','Egypt','مصر','EGP',2,14, true, 'eta',          'ar','Africa/Cairo'),
  ('JO','Jordan','الأردن','JOD',3,16, true, 'jofotara',     'ar','Asia/Amman'),
  ('GB','United Kingdom','المملكة المتحدة','GBP',2,20, true, null,      'en','Europe/London'),
  ('US','United States','الولايات المتحدة','USD',2, 0, false, null,     'en','America/New_York'),
  ('XX','Other country (generic)','دولة أخرى','USD',2, 0, true, null,  'en','UTC')
on conflict (code) do nothing;

insert into public.coa_template(system_key, code, name_en, name_ar, type) values
  ('cash',                  '1010','Cash on hand',               'النقدية في الصندوق',     'asset'),
  ('bank',                  '1020','Bank',                       'البنك',                  'asset'),
  ('card_clearing',         '1030','Card payments clearing',     'تسوية مدفوعات البطاقات', 'asset'),
  ('gateway_clearing',      '1040','Online payments clearing',   'تسوية المدفوعات الإلكترونية','asset'),
  ('other_clearing',        '1050','Other tenders clearing',     'تسوية وسائل دفع أخرى',   'asset'),
  ('ar',                    '1100','Accounts receivable',        'الذمم المدينة',          'asset'),
  ('inventory',             '1200','Inventory',                  'المخزون',                'asset'),
  ('ap',                    '2010','Accounts payable',           'الذمم الدائنة',          'liability'),
  ('vat_payable',           '2100','VAT payable',                'ضريبة القيمة المضافة المستحقة','liability'),
  ('store_credit',          '2200','Customer store credit',      'أرصدة العملاء الدائنة',   'liability'),
  ('equity',                '3000','Owner equity',               'حقوق الملكية',           'equity'),
  ('sales',                 '4000','Sales',                      'المبيعات',               'income'),
  ('cogs',                  '5000','Cost of goods sold',         'تكلفة البضاعة المباعة',   'expense'),
  ('inventory_adjustments', '5100','Inventory adjustments',      'تسويات المخزون',         'expense'),
  ('cash_over_short',       '5200','Cash over / short',          'فروقات النقدية',         'expense')
on conflict (system_key) do nothing;

-- ---------------------------------------------------------------- report views (RLS of the caller applies)
create or replace view public.v_daily_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id,
       (s.created_at at time zone b.timezone)::date as day,
       count(*) filter (where s.doc_type = 'invoice')                          as invoices,
       count(*) filter (where s.doc_type = 'credit_note')                      as credit_notes,
       coalesce(sum(s.total) filter (where s.doc_type = 'invoice'),0)          as gross_sales,
       coalesce(sum(s.total) filter (where s.doc_type = 'credit_note'),0)      as refunds,
       coalesce(sum(case when s.doc_type='invoice' then s.total else -s.total end),0)         as net_sales,
       coalesce(sum(case when s.doc_type='invoice' then s.tax_total else -s.tax_total end),0) as tax,
       coalesce(sum(s.discount_total) filter (where s.doc_type = 'invoice'),0) as discounts
  from public.sales s join public.branches b on b.id = s.branch_id
 group by 1,2,3;

create or replace view public.v_tender_daily with (security_invoker = true) as
select s.tenant_id, s.branch_id, (p.created_at at time zone b.timezone)::date as day, p.tender, p.status,
       sum(p.amount) as amount, count(*) as count
  from public.payments p join public.sales s on s.id = p.sale_id join public.branches b on b.id = s.branch_id
 group by 1,2,3,4,5;

create or replace view public.v_item_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day, l.item_id, l.name,
       sum(case when s.doc_type='invoice' then l.qty else -l.qty end)               as qty,
       sum(case when s.doc_type='invoice' then l.line_total else -l.line_total end) as total,
       sum(case when s.doc_type='invoice' then l.net_amount else -l.net_amount end) as net,
       sum(case when s.doc_type='invoice' then l.qty*l.unit_cost else -l.qty*l.unit_cost end)::bigint as cost
  from public.sale_lines l join public.sales s on s.id = l.sale_id join public.branches b on b.id = s.branch_id
 group by 1,2,3,4,5;

create or replace view public.v_hourly_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day,
       extract(hour from s.created_at at time zone b.timezone)::int as hour,
       sum(case when s.doc_type='invoice' then s.total else -s.total end) as net_sales, count(*) as docs
  from public.sales s join public.branches b on b.id = s.branch_id
 group by 1,2,3,4;

create or replace view public.v_stock_levels with (security_invoker = true) as
select m.tenant_id, m.branch_id, m.item_id, sum(m.qty) as qty
  from public.stock_movements m group by 1,2,3;

create or replace view public.v_cashier_sales with (security_invoker = true) as
select s.tenant_id, s.branch_id, (s.created_at at time zone b.timezone)::date as day, s.created_by,
       coalesce(mb.display_name,'') as cashier,
       count(*) filter (where s.doc_type='invoice') as invoices,
       coalesce(sum(s.total) filter (where s.doc_type='invoice'),0) as sales,
       coalesce(sum(s.discount_total) filter (where s.doc_type='invoice'),0) as discounts,
       coalesce(sum(s.total) filter (where s.doc_type='credit_note'),0) as refunds
  from public.sales s join public.branches b on b.id = s.branch_id
  left join public.memberships mb on mb.tenant_id = s.tenant_id and mb.user_id = s.created_by
 group by 1,2,3,4,5;

create or replace view public.v_exceptions with (security_invoker = true) as
select a.id, a.tenant_id, a.branch_id, a.created_at, a.action, a.amount, a.reason, a.meta,
       a.user_id, u.display_name as user_name, a.approved_by, ap.display_name as approver_name, a.entity_id
  from public.audit_log a
  left join public.memberships u  on u.tenant_id  = a.tenant_id and u.user_id  = a.user_id
  left join public.memberships ap on ap.tenant_id = a.tenant_id and ap.user_id = a.approved_by;

create or replace view public.v_trial_balance with (security_invoker = true) as
select a.tenant_id, a.code, a.name_en, a.name_ar, a.type, a.system_key,
       coalesce(sum(jl.debit),0)::bigint as debit, coalesce(sum(jl.credit),0)::bigint as credit,
       coalesce(sum(jl.debit - jl.credit),0)::bigint as balance
  from public.accounts a left join public.journal_lines jl on jl.account_id = a.id
 group by 1,2,3,4,5,6;

grant select on public.v_daily_sales, public.v_tender_daily, public.v_item_sales, public.v_hourly_sales,
  public.v_stock_levels, public.v_cashier_sales, public.v_exceptions, public.v_trial_balance to authenticated;

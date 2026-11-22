-- Cross-checks over every business in the database. Each row returned is a mismatch.
\pset footer off
\echo '--- 1. ledger not balanced'
select tenant_id, sum(debit) - sum(credit) as diff from journal_lines group by 1 having sum(debit) <> sum(credit);
\echo '--- 2. invoice total <> sum of its lines'
select s.number, s.total, sum(l.line_total) from sales s join sale_lines l on l.sale_id = s.id group by s.id having s.total <> sum(l.line_total) limit 10;
\echo '--- 3. invoice total <> its payments (refunds excluded)'
select s.number, s.total, coalesce(sum(p.amount) filter (where p.delivery_id is null), 0) as paid
  from sales s left join payments p on p.sale_id = s.id where s.doc_type = 'invoice' group by s.id
 having s.total <> coalesce(sum(p.amount) filter (where p.delivery_id is null), 0) limit 10;
\echo '--- 4. VAT in the ledger <> VAT on documents'
with doc as (select tenant_id, sum(case when doc_type = 'invoice' then tax_total else -tax_total end) v from sales group by 1),
     gl as (select jl.tenant_id, sum(jl.credit - jl.debit) v from journal_lines jl join accounts a on a.id = jl.account_id where a.system_key = 'vat_payable' group by 1)
select doc.tenant_id, doc.v as documents, gl.v as ledger from doc left join gl using (tenant_id) where doc.v <> coalesce(gl.v, 0) limit 10;
\echo '--- 5. revenue in the ledger <> net of sold lines (vouchers and prepaid packages are liabilities, released packages are revenue)'
with doc as (
  select s.tenant_id, sum(case when s.doc_type = 'invoice' then l.net_amount else -l.net_amount end) v
    from sale_lines l join sales s on s.id = l.sale_id left join items i on i.id = l.item_id
   where coalesce(i.item_type, 'standard') not in ('gift_card', 'package') group by 1),
  exp as (select jl.tenant_id, sum(jl.credit) v from journal_lines jl join journal_entries e on e.id = jl.entry_id join accounts a on a.id = jl.account_id
           where a.system_key = 'sales' and e.source_type = 'package_expiry' group by 1),
  gl as (select jl.tenant_id, sum(jl.credit - jl.debit) v from journal_lines jl join accounts a on a.id = jl.account_id where a.system_key = 'sales' group by 1)
select doc.tenant_id, doc.v as documents, gl.v - coalesce(exp.v, 0) as ledger from doc left join gl using (tenant_id) left join exp using (tenant_id)
 where doc.v <> coalesce(gl.v, 0) - coalesce(exp.v, 0) limit 10;
\echo '--- 6. expiry-tracked stock <> sum of its batches'
select m.item_id, m.branch_id, sum(m.qty) stock, (select coalesce(sum(bm.qty), 0) from batch_moves bm join stock_batches b on b.id = bm.batch_id where b.item_id = m.item_id and b.branch_id = m.branch_id) batches
  from stock_movements m join items i on i.id = m.item_id where i.track_expiry group by 1, 2
having sum(m.qty) <> (select coalesce(sum(bm.qty), 0) from batch_moves bm join stock_batches b on b.id = bm.batch_id where b.item_id = m.item_id and b.branch_id = m.branch_id) limit 10;
\echo '--- 7. gift card balances <> their movements'
select g.code, g.balance, sum(m.amount) from gift_cards g join gift_card_moves m on m.card_id = g.id group by g.id having g.balance <> sum(m.amount) limit 10;
\echo '--- 8. every captured payment (sales, deposits, deliveries) appears in the tender report'
select p.tenant_id, sum(p.amount) as payments, coalesce((select sum(v.amount) from v_tender_daily v where v.tenant_id = p.tenant_id and v.status = 'captured'), 0) as tender_report
from payments p where p.status = 'captured' group by p.tenant_id
having sum(p.amount) <> coalesce((select sum(v.amount) from v_tender_daily v where v.tenant_id = p.tenant_id and v.status = 'captured'), 0);
\echo '--- 9. sales report excludes gift card and package sales (they are prepaid, shown separately)'
select d.tenant_id, sum(d.gross_sales + d.prepaid_sold) as report_total,
  (select sum(s.total) from sales s where s.tenant_id = d.tenant_id and s.doc_type = 'invoice' and s.status <> 'voided') as invoices_total
from v_daily_sales d group by d.tenant_id
having sum(d.gross_sales + d.prepaid_sold) <> (select sum(s.total) from sales s where s.tenant_id = d.tenant_id and s.doc_type = 'invoice' and s.status <> 'voided');

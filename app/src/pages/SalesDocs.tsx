import { Plus, Printer, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { PrintDoc } from '../components/PrintDoc'
import { Empty, Modal, useApproval } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { fmt, num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { rpc, supabase, uuid } from '../lib/supabase'
import type { CartLine, Customer, Item } from '../lib/types'

type Kind = 'quotation' | 'order' | 'delivery'
interface DocLine { item_id: string; name: string; name_ar: string | null; qty: number; unit_price: number; discount: number; tax_rate: number; net: number; tax: number; total: number; note?: string | null }
interface Doc { id: string; kind: Kind; number: string; customer_id: string | null; status: string; valid_until: string | null; lines: DocLine[]
  subtotal: number; discount: number; tax: number; total: number; note: string | null; source_id: string | null; sale_id: string | null; created_at: string }
const KIND_LABEL: Record<Kind, string> = { quotation: 'Quotations', order: 'Sales orders', delivery: 'Delivery notes' }
const ONE: Record<Kind, string> = { quotation: 'Quotation', order: 'Sales order', delivery: 'Delivery note' }

/** B2B selling: quotation → sales order → delivery note → invoice (issued at the till, on account or paid). */
export default function SalesDocs() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [params, setParams] = useSearchParams()
  const [kind, setKind] = useState<Kind>((params.get('kind') as Kind) || 'quotation')
  const [rows, setRows] = useState<Doc[]>([])
  const [customers, setCustomers] = useState<Customer[]>([])
  const [edit, setEdit] = useState<Partial<Doc> | null>(params.get('new') ? { kind: 'quotation', lines: [] } : null)
  const [view, setView] = useState<Doc | null>(null)
  const load = useCallback(async () => {
    const [d, c] = await Promise.all([
      supabase.from('sales_docs').select('*').eq('tenant_id', tn.id).eq('kind', kind).order('created_at', { ascending: false }).limit(300),
      supabase.from('customers').select('*').eq('tenant_id', tn.id).order('name')])
    setRows((d.data ?? []) as Doc[]); setCustomers((c.data ?? []) as Customer[])
  }, [tn.id, kind])
  useEffect(() => { void load() }, [load])
  const cname = (id: string | null) => customers.find((c) => c.id === id)?.name ?? '—'
  return (
    <div className="page">
      <div className="row between wrap">
        <div className="tabs" role="tablist">{(['quotation', 'order', 'delivery'] as Kind[]).map((k) => (
          <button key={k} role="tab" aria-selected={kind === k} className={kind === k ? 'on' : ''} onClick={() => { setKind(k); setParams({ kind: k }) }}>{t(KIND_LABEL[k])}</button>))}</div>
        <button className="primary" onClick={() => setEdit({ kind, lines: [] })}><Plus size={16} />{t('New')} {t(ONE[kind])}</button>
      </div>
      {rows.length === 0 ? <Empty title={t('Nothing here yet')} hint={kind === 'quotation' ? t('A quotation becomes a sales order, then a delivery note, then an invoice.') : undefined} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Number')}</th><th>{t('Date')}</th><th>{t('Customer')}</th><th>{t('Status')}</th><th className="num">{t('Total')}</th></tr></thead>
          <tbody>{rows.map((r) => <tr key={r.id} className="clickable" onClick={() => setView(r)}><td>{r.number}</td><td>{r.created_at.slice(0, 10)}</td><td>{cname(r.customer_id)}</td>
            <td><span className={`pill ${r.status}`}>{t(r.status)}</span></td><td className="num">{fmt(r.total, tn, lang)}</td></tr>)}</tbody>
        </table></div>)}
      {edit && <DocEditor doc={edit} customers={customers} onClose={() => setEdit(null)} onSaved={(d) => { setEdit(null); setView(d); void load() }} />}
      {view && <DocView doc={view} customer={customers.find((c) => c.id === view.customer_id) ?? null} onClose={() => setView(null)}
        onEdit={() => { setEdit(view); setView(null) }} onChanged={(d) => { if (d) { setKind(d.kind); setView(d) } else setView(null); void load() }} />}
    </div>
  )
}

function DocEditor({ doc, customers, onClose, onSaved }: { doc: Partial<Doc>; customers: Customer[]; onClose: () => void; onSaved: (d: Doc) => void }) {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const approval = useApproval()
  const [items, setItems] = useState<Item[]>([])
  const [q, setQ] = useState('')
  const [f, setF] = useState({ customer_id: doc.customer_id ?? '', valid_until: doc.valid_until ?? '', note: doc.note ?? '' })
  const [lines, setLines] = useState<{ key: string; item_id: string; name: string; qty: string; price: string; discount: string }[]>(
    (doc.lines ?? []).map((l) => ({ key: uuid(), item_id: l.item_id, name: l.name, qty: String(l.qty), price: num(l.unit_price, d), discount: l.discount ? num(l.discount, d) : '' })))
  useEffect(() => { void supabase.from('items').select('*').eq('tenant_id', tn.id).eq('is_active', true).neq('item_type', 'ingredient').eq('is_template', false).order('name').limit(1000).then(({ data }) => setItems((data ?? []) as Item[])) }, [tn.id])
  const found = useMemo(() => (q.trim().length < 1 ? [] : items.filter((i) => [i.name, i.name_ar, i.barcode, i.sku].some((x) => x?.toLowerCase().includes(q.trim().toLowerCase()))).slice(0, 8)), [q, items])
  const add = (i: Item) => { setLines([...lines, { key: uuid(), item_id: i.id, name: nameOf(i), qty: '1', price: '', discount: '' }]); setQ('') }
  async function save() {
    const r = await approval.run(() => rpc<Doc>('save_sales_doc', { p: { id: doc.id ?? null, tenant_id: tn.id, branch_id: s.branch!.id, kind: doc.kind, customer_id: f.customer_id || null,
      valid_until: f.valid_until || null, note: f.note || null,
      lines: lines.map((l) => ({ item_id: l.item_id, qty: Number(l.qty), unit_price: l.price ? toMinor(l.price, d) : null, discount: l.discount ? toMinor(l.discount, d) : 0 })) } }))
    if (r) onSaved(r)
  }
  return (
    <Modal title={`${doc.id ? t('Edit') : t('New')} ${t(ONE[doc.kind ?? 'quotation'])}`} onClose={onClose} wide>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); void save() }}>
        <div className="grid2">
          <label className="field"><span>{t('Customer')}</span><select id="sd-customer" value={f.customer_id} onChange={(e) => setF({ ...f, customer_id: e.target.value })}>
            <option value="">{doc.kind === 'quotation' ? t('— not yet —') : '—'}</option>{customers.map((c) => <option key={c.id} value={c.id}>{c.name}{c.phone ? ` · ${c.phone}` : ''}</option>)}</select></label>
          {doc.kind === 'quotation' && <label className="field"><span>{t('Valid until')}</span><input id="sd-valid" type="date" value={f.valid_until} onChange={(e) => setF({ ...f, valid_until: e.target.value })} /></label>}
        </div>
        <label className="field"><span>{t('Add item')}</span><input id="sd-search" placeholder={t('Search name, barcode or SKU')} value={q} onChange={(e) => setQ(e.target.value)} /></label>
        {found.length > 0 && <div className="chips">{found.map((i) => <button type="button" key={i.id} className="chipbtn" onClick={() => add(i)}>{nameOf(i)} · {num(i.price, d)}</button>)}</div>}
        <div className="table-wrap"><table className="list compact">
          <thead><tr><th>{t('Item')}</th><th className="num">{t('Qty')}</th><th className="num">{t('Price')}</th><th className="num">{t('Discount')}</th><th /></tr></thead>
          <tbody>{lines.map((l, i) => <tr key={l.key}><td>{l.name}</td>
            <td className="num"><input className="qty-in" aria-label={t('Qty')} inputMode="decimal" value={l.qty} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} /></td>
            <td className="num"><input className="qty-in" aria-label={t('Price')} inputMode="decimal" placeholder={t('List')} value={l.price} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, price: e.target.value } : x)))} /></td>
            <td className="num"><input className="qty-in" aria-label={t('Discount')} inputMode="decimal" value={l.discount} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, discount: e.target.value } : x)))} /></td>
            <td><button type="button" className="icon" aria-label={t('Remove')} onClick={() => setLines(lines.filter((_, j) => j !== i))}><Trash2 size={15} /></button></td></tr>)}</tbody>
        </table></div>
        <p className="muted small">{t('Leave the price empty to use the customer\'s price list or the catalogue price. Totals and VAT are worked out when you save.')}</p>
        <label className="field"><span>{t('Note')}</span><input id="sd-note" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></label>
        {approval.error && <p className="error">{approval.error}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!lines.length}>{t('Save')}</button></div>
      </form>
      {approval.dialog}
    </Modal>
  )
}

function DocView({ doc, customer, onClose, onEdit, onChanged }: { doc: Doc; customer: Customer | null; onClose: () => void; onEdit: () => void; onChanged: (d: Doc | null) => void }) {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const go = useNavigate()
  const approval = useApproval()
  const [printing, setPrinting] = useState(false)
  const closed = ['invoiced', 'cancelled', 'rejected'].includes(doc.status)
  async function act(a: string) { const r = await approval.run(() => rpc<Doc>('advance_sales_doc', { p_id: doc.id, p_action: a })); if (r) onChanged(r) }
  function invoice() {
    const lines: CartLine[] = doc.lines.map((l) => ({ key: uuid(), item_id: l.item_id, name: l.name, name_ar: l.name_ar, qty: Number(l.qty), unit_price: l.unit_price, list_price: l.unit_price, discount: l.discount, tax_rate: l.tax_rate, note: l.note ?? undefined }))
    go('/pos', { state: { checkout: { lines, customer, label: `${t(ONE[doc.kind])} ${doc.number}`, sales_doc_id: doc.id } } })
  }
  const body = (
    <>
      <div className="table-wrap"><table className="list compact">
        <thead><tr><th>{t('Item')}</th><th className="num">{t('Qty')}</th>{doc.kind !== 'delivery' && <><th className="num">{t('Price')}</th><th className="num">{t('Discount')}</th><th className="num">{t('Total')}</th></>}</tr></thead>
        <tbody>{doc.lines.map((l, i) => <tr key={i}><td>{lang === 'ar' && l.name_ar ? l.name_ar : l.name}</td><td className="num">{Number(l.qty)}</td>
          {doc.kind !== 'delivery' && <><td className="num">{num(l.unit_price, d)}</td><td className="num">{l.discount ? num(l.discount, d) : ''}</td><td className="num">{num(l.total, d)}</td></>}</tr>)}</tbody>
      </table></div>
      {doc.kind !== 'delivery' && <dl className="dl">
        <dt>{t('Subtotal excl. VAT')}</dt><dd>{fmt(doc.subtotal, tn, lang)}</dd><dt>{t('VAT')}</dt><dd>{fmt(doc.tax, tn, lang)}</dd><dt>{t('Total')}</dt><dd><b>{fmt(doc.total, tn, lang)}</b></dd></dl>}
      {doc.note && <p className="muted">{doc.note}</p>}
    </>)
  return (
    <Modal title={`${t(ONE[doc.kind])} ${doc.number}`} onClose={onClose} wide>
      <div className="stack">
        <div className="row between wrap"><span className={`pill ${doc.status}`}>{t(doc.status)}</span>
          <span className="muted">{customer?.name ?? '—'} · {doc.created_at.slice(0, 10)}{doc.valid_until ? ` · ${t('valid until {d}', { d: doc.valid_until })}` : ''}</span></div>
        {body}
        {approval.error && <p className="error">{approval.error}</p>}
        <div className="row end wrap">
          <button className="ghost" onClick={() => setPrinting(true)}><Printer size={16} />{t('Print')}</button>
          {!closed && ['draft', 'sent', 'open'].includes(doc.status) && <button onClick={onEdit}>{t('Edit')}</button>}
          {doc.kind === 'quotation' && doc.status === 'draft' && <button onClick={() => void act('sent')}>{t('Mark as sent')}</button>}
          {doc.kind === 'quotation' && !closed && doc.status !== 'accepted' && <button onClick={() => void act('rejected')}>{t('Rejected by customer')}</button>}
          {doc.kind === 'quotation' && !closed && doc.status !== 'accepted' && <button className="primary" disabled={!doc.customer_id} onClick={() => void act('to_order')}>{t('Accepted → sales order')}</button>}
          {doc.kind === 'order' && doc.status === 'open' && <button onClick={() => void act('to_delivery')}>{t('Create delivery note')}</button>}
          {doc.kind === 'delivery' && doc.status === 'open' && <button onClick={() => void act('delivered')}>{t('Mark as delivered')}</button>}
          {!closed && doc.status !== 'accepted' && s.can('sale.create') && <button className="primary" onClick={invoice}>{t('Invoice at the till')}</button>}
          {!closed && doc.status !== 'accepted' && <button className="danger" onClick={() => void act('cancelled')}>{t('Cancel')}</button>}
        </div>
      </div>
      {approval.dialog}
      {printing && (
        <PrintDoc paper="a4" onDone={() => setPrinting(false)}>
          <div className="a4-doc">
            <header className="a4-head"><div><h1>{lang === 'ar' && tn.name_ar ? tn.name_ar : tn.name}</h1>{tn.tax_number && <div>{t('Tax number')}: {tn.tax_number}</div>}<div>{s.branch?.name}</div></div>
              <div><h2>{t(ONE[doc.kind])}</h2><div>{doc.number}</div><div>{doc.created_at.slice(0, 10)}</div>{doc.valid_until && <div>{t('valid until {d}', { d: doc.valid_until })}</div>}</div></header>
            <section className="a4-to"><b>{t('Customer')}</b><div>{customer?.name ?? '—'}</div>{customer?.phone && <div>{customer.phone}</div>}{customer?.address && <div>{customer.address}</div>}</section>
            {body}
            {doc.kind === 'delivery' && <div className="a4-sign"><span>{t('Received by')}: ____________</span><span>{t('Signature')}: ____________</span><span>{t('Date')}: ________</span></div>}
          </div>
        </PrintDoc>)}
    </Modal>
  )
}

import { Banknote, Plus, Printer, ShoppingBag } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { CustomerPicker } from '../components/CustomerPicker'
import { fontStack } from '../components/Receipt'
import { Empty, Modal, useApproval } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { fmt, num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { getShift, norm } from '../lib/shift'
import { parseError, rpc, supabase } from '../lib/supabase'
import type { CartLine, Customer, Item, Tender, WorkOrder } from '../lib/types'
import type { CheckoutContext } from './Pos'

const COLS: WorkOrder['status'][] = ['received', 'in_progress', 'ready']
const STATUS: Record<string, string> = { received: 'Received', in_progress: 'In progress', ready: 'Ready', collected: 'Collected', cancelled: 'Cancelled' }

/** Job cards (laundry, repairs, car wash) and pre-orders (cakes, flowers): intake, deposit, ready, collect and pay. */
export default function Orders() {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const nav = useNavigate()
  const tn = s.tenant!
  const kinds = [...(s.has('job_cards') ? ['job' as const] : []), ...(s.has('preorders') ? ['preorder' as const] : [])]
  const [kind, setKind] = useState<'job' | 'preorder'>(kinds[0] ?? 'job')
  const [list, setList] = useState<WorkOrder[]>([])
  const [customers, setCustomers] = useState<Customer[]>([])
  const [items, setItems] = useState<Item[]>([])
  const [params, setParams] = useSearchParams()
  const [q, setQ] = useState(() => params.get('q') ?? '')
  const [edit, setEdit] = useState<Partial<WorkOrder> | null>(null)
  const [open, setOpen] = useState<WorkOrder | null>(null)
  const [printing, setPrinting] = useState<WorkOrder | null>(null)
  const load = useCallback(async () => {
    if (!s.branch) return
    const [w, c, i] = await Promise.all([
      supabase.from('work_orders').select('*').eq('branch_id', s.branch.id).eq('kind', kind).in('status', ['received', 'in_progress', 'ready']).order('due_at', { nullsFirst: false }).order('created_at'),
      supabase.from('customers').select('*').eq('tenant_id', tn.id).order('name').limit(2000),
      supabase.from('items').select('*').eq('tenant_id', tn.id).eq('is_active', true).not('item_type', 'in', '(ingredient,package)').eq('is_template', false).order('name'),
    ])
    setList((w.data ?? []) as WorkOrder[]); setCustomers((c.data ?? []) as Customer[]); setItems((i.data ?? []) as Item[])
  }, [s.branch, kind, tn.id])
  useEffect(() => { void load() }, [load])
  useEffect(() => { if (params.get('new')) { setEdit({ kind, lines: [] }); setParams({}, { replace: true }) } }, [params, setParams, kind])
  const cust = (id: string | null) => customers.find((c) => c.id === id)
  const shown = useMemo(() => { const n = norm(q); return list.filter((w) => !n || norm(w.number).includes(n) || norm(cust(w.customer_id)?.name ?? '').includes(n) || (cust(w.customer_id)?.phone ?? '').includes(q) || norm(w.reference ?? '').includes(n) || norm(w.tags ?? '').includes(n)) }, [list, q, customers])
  const balance = (w: WorkOrder) => Math.max(w.total - (w.deposit_paid - w.deposit_used), 0)
  const late = (w: WorkOrder) => w.due_at && new Date(w.due_at) < new Date() && w.status !== 'ready'

  function checkout(w: WorkOrder) {
    const lines: CartLine[] = w.lines.map((l, i) => {
      const it = items.find((x) => x.id === l.item_id)
      return { key: `${w.id}-${i}`, item_id: l.item_id, name: l.name, name_ar: l.name_ar, qty: Number(l.qty), unit_price: it?.price ?? l.unit_price, list_price: it?.price ?? l.unit_price,
               discount: 0, tax_rate: it?.tax_rate ?? tn.vat_rate, note: l.note ?? undefined }
    })
    const ctx: CheckoutContext = { lines, customer: cust(w.customer_id) ?? null, work_order_id: w.id, deposit: w.deposit_paid - w.deposit_used, label: w.number }
    nav('/pos', { state: { checkout: ctx } })
  }

  return (
    <div className="page">
      <div className="row between wrap">
        {kinds.length > 1 ? <div className="seg">{kinds.map((k) => <button key={k} className={kind === k ? 'on' : ''} onClick={() => setKind(k)}>{t(k === 'job' ? 'Job cards' : 'Pre-orders')}</button>)}</div> : <h1 className="keep">{t(kind === 'job' ? 'Job cards' : 'Pre-orders')}</h1>}
        <div className="row"><input id="orders-q" className="search" placeholder={t('Number, name, phone, plate or tag')} value={q} onChange={(e) => setQ(e.target.value)} />
          <button className="primary" onClick={() => setEdit({ kind, lines: [] })}><Plus size={16} />{t(kind === 'job' ? 'New job card' : 'New pre-order')}</button></div>
      </div>
      <div className="kpi-row">
        {COLS.map((c) => <div key={c} className="kpi2"><span className="kpi2-label">{t(STATUS[c])}</span><b className="kpi2-value">{list.filter((w) => w.status === c).length}</b></div>)}
        <div className="kpi2"><span className="kpi2-label">{t('Late')}</span><b className={`kpi2-value ${list.some(late) ? 'bad' : ''}`}>{list.filter(late).length}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('Deposits held')}</span><b className="kpi2-value">{fmt(list.reduce((a, w) => a + w.deposit_paid - w.deposit_used, 0), tn, lang)}</b></div>
      </div>
      {list.length === 0 ? <Empty title={t('Nothing open')} hint={t(kind === 'job' ? 'Create a job card when a customer drops something off.' : 'Create a pre-order for a date in the future.')} /> : (
        <div className="board">{COLS.map((c) => (
          <div key={c} className="board-col"><h3>{t(STATUS[c])} <em>{shown.filter((w) => w.status === c).length}</em></h3>
            {shown.filter((w) => w.status === c).map((w) => (
              <button key={w.id} className={`job ${late(w) ? 'late' : ''}`} onClick={() => setOpen(w)}>
                <span className="row between"><b className="mono">{w.number}</b>{w.due_at && <small>{new Date(w.due_at).toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' })}</small>}</span>
                <span>{cust(w.customer_id)?.name ?? t('Walk-in')}{w.reference ? ` · ${w.reference}` : ''}</span>
                <small className="muted">{w.lines.map((l) => `${Number(l.qty)}× ${nameOf(l)}`).join(', ')}</small>
                <span className="row between"><small>{w.tags ? `#${w.tags}` : ''}</small><b>{fmt(balance(w), tn, lang)}</b></span>
              </button>))}
          </div>))}
        </div>)}
      {edit && <OrderForm init={edit} items={items} customers={customers} onClose={() => setEdit(null)} onCustomer={(c) => setCustomers([...customers, c])}
        onSaved={async (w) => { setEdit(null); await load(); setOpen(w) }} />}
      {open && <OrderDetail w={open} customer={cust(open.customer_id) ?? null} onClose={() => setOpen(null)} onChanged={async (w) => { await load(); setOpen(w) }}
        onEdit={() => { setEdit(open); setOpen(null) }} onCheckout={() => checkout(open)} onPrint={() => setPrinting(open)} />}
      {printing && <TicketPrint w={printing} customer={cust(printing.customer_id) ?? null} onDone={() => setPrinting(null)} />}
    </div>
  )
}

function OrderForm({ init, items, customers, onClose, onSaved, onCustomer }: {
  init: Partial<WorkOrder>; items: Item[]; customers: Customer[]; onClose: () => void; onSaved: (w: WorkOrder) => void; onCustomer: (c: Customer) => void
}) {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const [customer, setCustomer] = useState<Customer | null>(customers.find((c) => c.id === init.customer_id) ?? null)
  const [picking, setPicking] = useState(false)
  const [lines, setLines] = useState<{ item_id: string; qty: number; note: string }[]>((init.lines ?? []).map((l) => ({ item_id: l.item_id, qty: Number(l.qty), note: l.note ?? '' })))
  const [f, setF] = useState({ due_at: init.due_at ? new Date(init.due_at).toISOString().slice(0, 16) : '', reference: init.reference ?? '', tags: init.tags ?? '', note: init.note ?? '' })
  const [q, setQ] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const isJob = init.kind === 'job'
  const total = lines.reduce((a, l) => a + Math.round(l.qty * (items.find((i) => i.id === l.item_id)?.price ?? 0)), 0)
  const found = q ? items.filter((i) => norm(i.name).includes(norm(q)) || norm(i.name_ar ?? '').includes(norm(q)) || i.barcode === q).slice(0, 8) : []
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try {
      const w = await rpc<WorkOrder>('save_work_order', { p: { id: init.id ?? null, branch_id: s.branch!.id, kind: init.kind, customer_id: customer?.id ?? null, due_at: f.due_at ? new Date(f.due_at).toISOString() : null,
        reference: f.reference, tags: f.tags, note: f.note, lines: lines.map((l) => ({ item_id: l.item_id, qty: l.qty, note: l.note || null })) } })
      onSaved(w)
    } catch (x) { const p = parseError(x); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) }
  }
  return (
    <Modal title={init.id ? `${init.number}` : t(isJob ? 'New job card' : 'New pre-order')} onClose={onClose} wide>
      <form className="grid2" onSubmit={save}>
        <div className="span2 row"><button type="button" className="ghost" onClick={() => setPicking(true)}>{customer ? customer.name : t('Choose customer')}</button>{customer?.phone && <span className="muted">{customer.phone}</span>}</div>
        <label className="field"><span>{t(isJob ? 'Ready by' : 'For (date and time)')}</span><input id="wo-due" type="datetime-local" required={!isJob} value={f.due_at} onChange={(e) => setF({ ...f, due_at: e.target.value })} /></label>
        <label className="field"><span>{t(isJob ? 'Reference (plate, device, IMEI)' : 'Message / details (e.g. text on the cake)')}</span><input id="wo-ref" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></label>
        {isJob && <label className="field"><span>{t('Tag numbers')}</span><input id="wo-tags" placeholder="101-106" value={f.tags} onChange={(e) => setF({ ...f, tags: e.target.value })} /></label>}
        <label className="field"><span>{t('Note')}</span><input id="wo-note" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></label>
        <div className="span2 stack">
          <input id="wo-item-q" placeholder={t('Add item or service…')} value={q} onChange={(e) => setQ(e.target.value)} />
          {found.length > 0 && <div className="chip-pick wrap">{found.map((i) => <button type="button" key={i.id} onClick={() => { setLines([...lines, { item_id: i.id, qty: 1, note: '' }]); setQ('') }}>{nameOf(i)} · {num(i.price, s.tenant!.currency_decimals)}</button>)}</div>}
          <table className="list compact"><tbody>{lines.map((l, i) => (
            <tr key={i}><td>{nameOf(items.find((x) => x.id === l.item_id))}</td>
              <td><input className="qty-in" aria-label={t('Qty')} inputMode="decimal" value={l.qty} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, qty: Number(e.target.value) || 0 } : x)))} /></td>
              <td><input aria-label={t('Note')} placeholder={t('Note')} value={l.note} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, note: e.target.value } : x)))} /></td>
              <td className="num">{fmt(Math.round(l.qty * (items.find((x) => x.id === l.item_id)?.price ?? 0)), s.tenant!, lang)}</td>
              <td><button type="button" className="ghost small danger" aria-label={t('Remove')} onClick={() => setLines(lines.filter((_, j) => j !== i))}>✕</button></td></tr>))}</tbody></table>
          <p className="row between"><span className="muted">{t('Estimated total')}</span><b>{fmt(total, s.tenant!, lang)}</b></p>
        </div>
        {err && <p className="error span2">{err}</p>}
        <div className="row end span2"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!lines.length}>{t('Save')}</button></div>
      </form>
      {picking && <CustomerPicker tenantId={s.tenant!.id} customers={customers} online onClose={() => setPicking(false)} onPick={(c) => { setCustomer(c); setPicking(false) }} onCreated={onCustomer} />}
    </Modal>
  )
}

function OrderDetail({ w, customer, onClose, onChanged, onEdit, onCheckout, onPrint }: {
  w: WorkOrder; customer: Customer | null; onClose: () => void; onChanged: (w: WorkOrder) => void; onEdit: () => void; onCheckout: () => void; onPrint: () => void
}) {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const approval = useApproval()
  const [dep, setDep] = useState('')
  const [tender, setTender] = useState<Tender>('cash')
  const [msg, setMsg] = useState<string | null>(null)
  const shift = getShift(s.branch?.id, s.session?.user.id)
  const held = w.deposit_paid - w.deposit_used
  const refresh = async () => { const { data } = await supabase.from('work_orders').select('*').eq('id', w.id).single(); onChanged(data as WorkOrder) }
  const run = async (f: () => Promise<unknown>) => { setMsg(null); try { await f(); await refresh() } catch (e) { const p = parseError(e); setMsg(p.kind === 'message' ? t(p.message) : t('Not allowed')) } }
  const wa = customer?.phone ? `https://wa.me/${customer.phone.replace(/\D/g, '')}?text=${encodeURIComponent(t('{biz}: your order {no} is ready. Amount due {due}.', { biz: tn.name, no: w.number, due: fmt(Math.max(w.total - held, 0), tn, lang) }))}` : null
  return (
    <Modal title={`${w.number} · ${customer?.name ?? t('Walk-in')}`} onClose={onClose} wide>
      <div className="stack">
        <p><span className={`pill wo-${w.status}`}>{t(STATUS[w.status])}</span>{w.due_at && <span className="muted"> · {t('Due')} {new Date(w.due_at).toLocaleString()}</span>}{w.reference && <span className="muted"> · {w.reference}</span>}{w.tags && <span className="muted"> · #{w.tags}</span>}</p>
        <ul className="mod-list">{w.lines.map((l, i) => <li key={i}><span>{Number(l.qty)}× {nameOf(l)}{l.note ? ` · ${l.note}` : ''}</span><b>{fmt(Math.round(Number(l.qty) * l.unit_price), tn, lang)}</b></li>)}</ul>
        <div className="kpi-row">
          <div className="kpi2"><span className="kpi2-label">{t('Total')}</span><b className="kpi2-value">{fmt(w.total, tn, lang)}</b></div>
          <div className="kpi2"><span className="kpi2-label">{t('Deposit paid')}</span><b className="kpi2-value">{fmt(held, tn, lang)}</b></div>
          <div className="kpi2"><span className="kpi2-label">{t('Balance due')}</span><b className="kpi2-value">{fmt(Math.max(w.total - held, 0), tn, lang)}</b></div>
        </div>
        {s.can('payments.receive') && (
          <form className="row wrap deposit-row" onSubmit={(e) => { e.preventDefault(); void run(() => rpc('take_deposit', { p_order: w.id, p_tender: tender, p_amount: toMinor(dep, tn.currency_decimals), p_shift: shift })).then(() => setDep('')) }}>
            <input id="wo-dep" className="qty-in" inputMode="decimal" placeholder="0.000" value={dep} onChange={(e) => setDep(e.target.value)} />
            <select id="wo-dep-tender" value={tender} onChange={(e) => setTender(e.target.value as Tender)}><option value="cash">{t('Cash')}</option><option value="card">{t('Card')}</option><option value="bank_transfer">{t('Bank transfer')}</option></select>
            <button className="ghost" disabled={!dep}><Banknote size={15} />{t('Take deposit')}</button>
            {held > 0 && <button type="button" className="ghost danger" onClick={() => void run(() => approval.run((pin) => rpc('refund_deposit', { p_order: w.id, p_tender: 'cash', p_reason: t('Order cancelled'), p_shift: shift, p_approver_pin: pin ?? null })))}>{t('Refund deposit')}</button>}
          </form>)}
        {msg && <p className="error">{msg}</p>}
        {approval.error && <p className="error">{approval.error}</p>}
        <div className="row wrap">
          {w.status === 'received' && <button onClick={() => void run(() => rpc('set_work_order_status', { p_id: w.id, p_status: 'in_progress' }))}>{t('Start work')}</button>}
          {w.status !== 'ready' && <button onClick={() => void run(() => rpc('set_work_order_status', { p_id: w.id, p_status: 'ready' }))}>{t('Mark ready')}</button>}
          {w.status === 'ready' && wa && <a className="button" href={wa} target="_blank" rel="noreferrer">{t('Tell the customer on WhatsApp')}</a>}
          <button className="ghost" onClick={onPrint}><Printer size={15} />{t('Print ticket')}</button>
          <button className="ghost" onClick={onEdit}>{t('Edit')}</button>
          {held === 0 && <button className="ghost danger" onClick={() => void run(() => rpc('set_work_order_status', { p_id: w.id, p_status: 'cancelled' }))}>{t('Cancel order')}</button>}
          {s.can('sale.create') && <button className="primary" onClick={onCheckout}><ShoppingBag size={16} />{t('Collect and pay')}</button>}
        </div>
      </div>
      {approval.dialog}
    </Modal>
  )
}

/** Drop-off ticket for the customer (and a copy for the bag): number, tags, items, due time, deposit. */
function TicketPrint({ w, customer, onDone }: { w: WorkOrder; customer: Customer | null; onDone: () => void }) {
  const s = useSession()
  const tn = s.tenant!
  const st = tn.settings ?? {}
  useEffect(() => {
    document.documentElement.dataset.paper = '80'
    const after = () => onDone()
    window.addEventListener('afterprint', after)
    const id = window.setTimeout(() => window.print(), 250)
    return () => { clearTimeout(id); window.removeEventListener('afterprint', after) }
  }, [onDone])
  return createPortal(
    <div id="print-root"><div className="receipt" style={{ fontFamily: fontStack(st.receipt_font) }}>
      <div className="r-center">{st.logo_show !== false && (st.logo_mono_url || tn.logo_url) && <img className="r-logo r-logo-s" src={st.logo_mono_url || tn.logo_url!} alt="" />}
        <strong className="r-big">{tn.name_ar || tn.name}</strong>{st.receipt_phones && <div>☎ {st.receipt_phones}</div>}
        <div className="r-big">{w.number}</div>{w.tags && <div className="r-big">TAG # {w.tags}</div>}</div>
      <hr />
      {customer && <div className="r-row"><span>{customer.name}</span><span>{customer.phone}</span></div>}
      {w.due_at && <div className="r-row"><span>Ready / جاهز</span><span>{new Date(w.due_at).toLocaleString('en-GB')}</span></div>}
      {w.reference && <div className="r-pre">{w.reference}</div>}
      <hr />
      {w.lines.map((l, i) => <div key={i} className="r-line"><span>{l.name}</span><span>{Number(l.qty)} ×</span><span>{num(Math.round(Number(l.qty) * l.unit_price), tn.currency_decimals)}</span></div>)}
      <hr />
      <div className="r-row"><span>Total / الإجمالي</span><span>{num(w.total, tn.currency_decimals)}</span></div>
      <div className="r-row"><span>Deposit / العربون</span><span>{num(w.deposit_paid - w.deposit_used, tn.currency_decimals)}</span></div>
      <div className="r-row r-big"><span>Due / المتبقي</span><span>{num(Math.max(w.total - (w.deposit_paid - w.deposit_used), 0), tn.currency_decimals)}</span></div>
      {st.receipt_terms && <><hr /><div className="r-pre r-terms">{st.receipt_terms}</div></>}
    </div></div>, document.body)
}


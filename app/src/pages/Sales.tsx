import { useSearchParams } from 'react-router-dom'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { PrintReceipt, tenderLabel, type ReceiptData } from '../components/Receipt'
import { Empty, Modal, useApproval } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt, num, toMinor } from '../lib/money'
import { dropOutboxEntry, flushOutbox, listOutbox, useOutboxCount, type OutboxEntry } from '../lib/offline'
import { useSession } from '../lib/session'
import { getShift } from '../lib/shift'
import { publicAppUrl, rpc, supabase, uuid } from '../lib/supabase'
import type { Sale, Tender } from '../lib/types'

const today = () => new Date().toISOString().slice(0, 10)

export default function Sales() {
  const { t, lang } = useT()
  const s = useSession()
  const tenant = s.tenant!
  const [from, setFrom] = useState(today())
  const [to, setTo] = useState(today())
  const [params] = useSearchParams()
  const [q, setQ] = useState(() => params.get('q') ?? '')
  const [rows, setRows] = useState<Sale[]>([])
  const [open, setOpen] = useState<Sale | null>(null)
  const [outbox, setOutbox] = useState<OutboxEntry[]>([])
  const queued = useOutboxCount()

  const load = useCallback(async () => {
    let query = supabase.from('sales').select('*').eq('tenant_id', tenant.id)
      .gte('created_at', `${from}T00:00:00`).lte('created_at', `${to}T23:59:59.999`).order('created_at', { ascending: false }).limit(500)
    if (s.branch && !s.can('reports.all')) query = query.eq('branch_id', s.branch.id)
    const { data } = await query
    setRows((data ?? []) as Sale[])
  }, [tenant.id, from, to, s])
  useEffect(() => { void load() }, [load])
  useEffect(() => { void listOutbox().then(setOutbox) }, [queued])

  const shown = useMemo(() => rows.filter((r) => !q || r.number.toLowerCase().includes(q.toLowerCase())), [rows, q])

  async function openSale(id: string) {
    const sale = await rpc<Sale>('sale_json', { p_sale: id })
    setOpen(sale)
  }

  return (
    <div className="page">
      <h1>{t('Sales')}</h1>
      {outbox.length > 0 && (
        <section className="card warn">
          <h2>{t('Waiting to sync')} ({outbox.length})</h2>
          <ul className="plain">{outbox.map((e) => (
            <li key={e.client_id} className="row between">
              <span>{new Date(e.created_at).toLocaleString()} · OFF-{e.client_id.slice(0, 8).toUpperCase()}{e.error && <em className="error"> · {e.error}</em>}</span>
              {e.error && s.can('sale.cancel') && <button className="ghost small" onClick={() => void dropOutboxEntry(e.client_id)}>{t('Discard')}</button>}
            </li>))}
          </ul>
          <button onClick={() => void flushOutbox().then(load)}>{t('Sync now')}</button>
        </section>
      )}
      <div className="filters">
        <label className="field"><span>{t('From')}</span><input id="sales-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="field"><span>{t('To')}</span><input id="sales-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label>
        <label className="field grow"><span>{t('Search number')}</span><input id="sales-q" value={q} onChange={(e) => setQ(e.target.value)} /></label>
      </div>
      {shown.length === 0 ? <Empty title={t('No sales in this period')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Number')}</th><th>{t('Time')}</th><th>{t('Type')}</th><th>{t('Status')}</th><th className="num">{t('Total')}</th><th className="num">{t('Balance due')}</th></tr></thead>
          <tbody>{shown.map((r) => {
            const due = r.doc_type === 'invoice' ? r.total - r.paid_total - r.refunded_total : 0
            return (
              <tr key={r.id} tabIndex={0} onClick={() => void openSale(r.id)} onKeyDown={(e) => { if (e.key === 'Enter') void openSale(r.id) }}>
                <td className="mono">{r.number}</td><td>{new Date(r.created_at).toLocaleString()}</td>
                <td>{r.doc_type === 'invoice' ? t('Invoice') : t('Credit note')}</td>
                <td><span className={`pill ${r.status}`}>{t(r.status)}</span></td>
                <td className="num">{fmt(r.total, tenant, lang)}</td>
                <td className="num">{due > 0 ? fmt(due, tenant, lang) : '—'}</td>
              </tr>)
          })}</tbody>
        </table></div>
      )}
      {open && <SaleDetail sale={open} onClose={() => setOpen(null)} onChanged={async (id) => { await load(); await openSale(id) }} />}
    </div>
  )
}

function SaleDetail({ sale, onClose, onChanged }: { sale: Sale; onClose: () => void; onChanged: (id: string) => Promise<void> }) {
  const { t, lang } = useT()
  const s = useSession()
  const tenant = s.tenant!
  const d = tenant.currency_decimals
  const approval = useApproval()
  const [mode, setMode] = useState<null | 'refund' | 'cancel' | 'collect' | 'link'>(null)
  const [qty, setQty] = useState<Record<string, string>>({})
  const [tender, setTender] = useState<Tender>('cash')
  const [reason, setReason] = useState('')
  const [amount, setAmount] = useState('')
  const [printing, setPrinting] = useState<ReceiptData | null>(null)
  const due = sale.doc_type === 'invoice' ? sale.total - sale.paid_total - sale.refunded_total : 0
  const shift = getShift(s.branch?.id, s.session?.user.id)

  async function refund(cancel: boolean) {
    const lines = cancel ? undefined : Object.entries(qty).filter(([, v]) => parseFloat(v) > 0).map(([line_id, v]) => ({ line_id, qty: parseFloat(v) }))
    if (!cancel && !lines?.length) { approval.setError(t('Choose at least one line to refund')); return }
    const client_id = uuid()
    const r = await approval.run((pin) => rpc<Sale>('refund_sale', { p: { sale_id: sale.id, client_id, tender, reason, cancel, lines, shift_id: shift, approver_pin: pin ?? null } }))
    if (r) { setMode(null); await onChanged(sale.id) }
  }
  async function collect() {
    const v = toMinor(amount, d)
    const r = await approval.run(() => rpc<Sale>('receive_payment', { p_sale: sale.id, p_tender: tender, p_amount: v, p_reference: null, p_shift: shift }))
    if (r) { setMode(null); await onChanged(sale.id) }
  }
  async function link() {
    const v = toMinor(amount, d)
    const r = await approval.run(() => rpc('create_payment_link', { p_sale: sale.id, p_amount: v }))
    if (r) { setMode(null); await onChanged(sale.id) }
  }

  const receipt: ReceiptData = {
    number: sale.number, doc_type: sale.doc_type, created_at: sale.created_at, copy: true,
    lines: (sale.lines ?? []).map((l) => ({ name: l.name, qty: l.qty, line_total: l.line_total })),
    subtotal: sale.subtotal, tax_total: sale.tax_total, total: sale.total, discount_total: sale.discount_total,
    payments: (sale.payments ?? []).map((p) => ({ tender: p.tender, amount: p.amount, status: p.status })),
    customer: sale.customer ?? null, reason: sale.reason,
  }

  return (
    <Modal title={`${sale.doc_type === 'invoice' ? t('Invoice') : t('Credit note')} ${sale.number}`} onClose={onClose} wide>
      <div className="stack">
        <div className="row between wrap">
          <span className={`pill ${sale.status}`}>{t(sale.status)}</span>
          <span className="muted">{new Date(sale.created_at).toLocaleString()}{sale.customer ? ` · ${sale.customer.name}` : ''}</span>
        </div>
        {sale.reason && <p className="muted">{t('Reason')}: {sale.reason}</p>}
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Item')}</th><th className="num">{t('Qty')}</th><th className="num">{t('Price')}</th><th className="num">{t('VAT')}</th><th className="num">{t('Total')}</th>{mode === 'refund' && <th>{t('Refund qty')}</th>}</tr></thead>
          <tbody>{(sale.lines ?? []).map((l) => (
            <tr key={l.id}><td>{l.name}</td><td className="num">{Number(l.qty)}</td><td className="num">{num(l.unit_price, d)}</td>
              <td className="num">{num(l.tax_amount, d)}</td><td className="num">{num(l.line_total, d)}</td>
              {mode === 'refund' && <td><input id={`rq-${l.id}`} className="qty-in" inputMode="decimal" value={qty[l.id] ?? ''} onChange={(e) => setQty({ ...qty, [l.id]: e.target.value })} /></td>}
            </tr>))}</tbody>
        </table></div>
        <dl className="dl">
          <dt>{t('Subtotal excl. VAT')}</dt><dd>{fmt(sale.subtotal, tenant, lang)}</dd>
          <dt>{t('VAT')}</dt><dd>{fmt(sale.tax_total, tenant, lang)}</dd>
          <dt>{t('Total')}</dt><dd><b>{fmt(sale.total, tenant, lang)}</b></dd>
          {sale.refunded_total > 0 && <><dt>{t('Refunded')}</dt><dd>{fmt(sale.refunded_total, tenant, lang)}</dd></>}
          {due > 0 && <><dt>{t('Balance due')}</dt><dd className="bad">{fmt(due, tenant, lang)}</dd></>}
        </dl>
        <ul className="plain">{(sale.payments ?? []).map((p) => (
          <li key={p.id}>{tenderLabel(p.tender, lang)} · {fmt(p.amount, tenant, lang)} · {t(p.status)}{p.reference ? ` · ${p.reference}` : ''}</li>))}</ul>
        {(sale.links ?? []).filter((k) => k.status === 'pending').map((k) => (
          <div key={k.token} className="linkbox"><code>{publicAppUrl}/pay/{k.token}</code>
            <button onClick={() => navigator.clipboard?.writeText(`${publicAppUrl}/pay/${k.token}`).catch(() => undefined)}>{t('Copy link')}</button></div>))}

        {mode && mode !== 'link' && mode !== 'collect' && (
          <div className="card stack">
            <label className="field"><span>{t('Refund to')}</span>
              <select id="refund-tender" value={tender} onChange={(e) => setTender(e.target.value as Tender)}>
                {(['cash', 'card', 'store_credit', 'on_account', 'bank_transfer'] as Tender[]).map((x) => <option key={x} value={x}>{tenderLabel(x, lang)}</option>)}
              </select></label>
            <label className="field"><span>{t('Reason (required)')}</span><input id="refund-reason" value={reason} onChange={(e) => setReason(e.target.value)} /></label>
            <p className="muted small">{t('A credit note is issued. The original invoice is never edited or deleted.')}</p>
            <button className="primary" disabled={!reason.trim()} onClick={() => void refund(mode === 'cancel')}>{mode === 'cancel' ? t('Cancel invoice') : t('Issue refund')}</button>
          </div>
        )}
        {(mode === 'collect' || mode === 'link') && (
          <div className="card stack">
            {mode === 'collect' && <label className="field"><span>{t('Payment method')}</span>
              <select id="collect-tender" value={tender} onChange={(e) => setTender(e.target.value as Tender)}>
                {(['cash', 'card', 'bank_transfer', 'other'] as Tender[]).map((x) => <option key={x} value={x}>{tenderLabel(x, lang)}</option>)}
              </select></label>}
            <label className="field"><span>{t('Amount')}</span><input id="collect-amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
            <button className="primary" onClick={() => void (mode === 'collect' ? collect() : link())}>{mode === 'collect' ? t('Record payment') : t('Create payment link')}</button>
          </div>
        )}
        {approval.error && <p className="error">{approval.error}</p>}
        <div className="row end wrap">
          <button onClick={() => setPrinting(receipt)}>{t('Reprint (COPY)')}</button>
          {sale.doc_type === 'invoice' && sale.status !== 'cancelled' && sale.status !== 'refunded' && <>
            {due > 0 && <button onClick={() => { setMode('collect'); setAmount(num(due, d)) }}>{t('Receive payment')}</button>}
            {due > 0 && sale.customer_id && <button onClick={() => { setMode('link'); setAmount(num(due, d)) }}>{t('Send payment link')}</button>}
            <button onClick={() => { setMode('refund'); setTender(due > 0 ? 'on_account' : 'cash') }}>{t('Refund items')}</button>
            <button className="danger" onClick={() => { setMode('cancel'); setTender(due > 0 ? 'on_account' : 'cash') }}>{t('Cancel invoice')}</button>
          </>}
        </div>
      </div>
      {approval.dialog}
      {printing && <PrintReceipt data={printing} tenant={tenant} branch={s.branch} onDone={() => setPrinting(null)} />}
    </Modal>
  )
}

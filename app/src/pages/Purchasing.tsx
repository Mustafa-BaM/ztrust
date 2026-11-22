import { useCallback, useEffect, useMemo, useState } from 'react'
import { Statement } from '../components/Statement'
import { Empty, Modal, useApproval } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { fmt, num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { rpc, supabase } from '../lib/supabase'
import type { Item, PurchaseOrder, Supplier } from '../lib/types'

const STATUS: Record<string, string> = { draft: 'Draft', approved: 'Approved', partially_received: 'Partially received', received: 'Received', cancelled: 'Cancelled' }

/** Purchasing officer creates → manager approves (never the creator) → storekeeper receives. */
export default function Purchasing() {
  const { t } = useT()
  const s = useSession()
  const [tab, setTab] = useState<'orders' | 'requests' | 'returns' | 'suppliers'>('orders')
  return (
    <div className="page">
      <h1>{t('Purchasing')}</h1>
      <div className="tabs">
        <button className={tab === 'requests' ? 'on' : ''} onClick={() => setTab('requests')}>{t('Purchase requests')}</button>
        <button className={tab === 'orders' ? 'on' : ''} onClick={() => setTab('orders')}>{t('Purchase orders')}</button>
        {s.can('inventory.adjust') && <button className={tab === 'returns' ? 'on' : ''} onClick={() => setTab('returns')}>{t('Returns to suppliers')}</button>}
        {(s.can('suppliers.manage') || s.can('purchase.create')) && <button className={tab === 'suppliers' ? 'on' : ''} onClick={() => setTab('suppliers')}>{t('Suppliers')}</button>}
      </div>
      {tab === 'orders' ? <Orders /> : tab === 'requests' ? <Requests /> : tab === 'returns' ? <Returns /> : <Suppliers />}
    </div>
  )
}

function Orders() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [rows, setRows] = useState<PurchaseOrder[]>([])
  const [status, setStatus] = useState<string>('open')
  const [open, setOpen] = useState<PurchaseOrder | null>(null)
  const [editing, setEditing] = useState<PurchaseOrder | 'new' | null>(null)
  const load = useCallback(async () => {
    let q = supabase.from('purchase_orders').select('*, suppliers(name), purchase_order_lines(*)').eq('tenant_id', tn.id).order('created_at', { ascending: false }).limit(300)
    if (status === 'open') q = q.in('status', ['draft', 'approved', 'partially_received'])
    else if (status) q = q.eq('status', status)
    const { data } = await q
    setRows((data ?? []) as PurchaseOrder[])
  }, [tn.id, status])
  useEffect(() => { void load() }, [load])

  return (
    <section className="stack">
      <div className="row between wrap">
        <div className="seg">{[['open', 'Open'], ['draft', 'Draft'], ['approved', 'Approved'], ['received', 'Received'], ['', 'All']].map(([k, l]) => (
          <button key={k} className={status === k ? 'on' : ''} onClick={() => setStatus(k)}>{t(l)}</button>))}</div>
        {s.can('purchase.create') && <button className="primary" onClick={() => setEditing('new')}>{t('New purchase order')}</button>}
      </div>
      {rows.length === 0 ? <Empty title={t('No purchase orders')} hint={s.can('purchase.create') ? t('Create one to order stock from a supplier.') : undefined} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Number')}</th><th>{t('Supplier')}</th><th>{t('Date')}</th><th>{t('Status')}</th><th className="num">{t('Total')}</th><th className="num">{t('Received')}</th></tr></thead>
          <tbody>{rows.map((r) => {
            const ordered = (r.purchase_order_lines ?? []).reduce((a, l) => a + Number(l.qty), 0)
            const got = (r.purchase_order_lines ?? []).reduce((a, l) => a + Number(l.received_qty), 0)
            return (
              <tr key={r.id} tabIndex={0} onClick={() => setOpen(r)} onKeyDown={(e) => { if (e.key === 'Enter') setOpen(r) }}>
                <td className="mono">{r.number}</td><td>{r.suppliers?.name}</td><td>{new Date(r.created_at).toLocaleDateString()}</td>
                <td><span className={`pill po-${r.status}`}>{t(STATUS[r.status])}</span></td>
                <td className="num">{fmt(r.total, tn, lang)}</td><td className="num">{ordered ? `${Math.round((got / ordered) * 100)}%` : '—'}</td>
              </tr>)
          })}</tbody>
        </table></div>
      )}
      {editing && <PoForm po={editing === 'new' ? null : editing} onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load() }} />}
      {open && <PoDetail po={open} onClose={() => setOpen(null)} onEdit={() => { setEditing(open); setOpen(null) }}
        onChanged={async () => { await load(); const { data } = await supabase.from('purchase_orders').select('*, suppliers(name), purchase_order_lines(*)').eq('id', open.id).single(); setOpen(data as PurchaseOrder) }} />}
    </section>
  )
}

function useCatalog() {
  const s = useSession()
  const [items, setItems] = useState<Item[]>([])
  const [suppliers, setSuppliers] = useState<Supplier[]>([])
  useEffect(() => {
    void supabase.from('items').select('*').eq('tenant_id', s.tenant!.id).eq('track_stock', true).order('name').then(({ data }) => setItems((data ?? []) as Item[]))
    void supabase.from('suppliers').select('*').eq('tenant_id', s.tenant!.id).eq('is_active', true).order('name').then(({ data }) => setSuppliers((data ?? []) as Supplier[]))
  }, [s.tenant])
  return { items, suppliers }
}

function PoForm({ po, onClose, onSaved }: { po: PurchaseOrder | null; onClose: () => void; onSaved: () => void }) {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const { items, suppliers } = useCatalog()
  const [supplier, setSupplier] = useState(po?.supplier_id ?? '')
  const [note, setNote] = useState(po?.note ?? '')
  const [lines, setLines] = useState<{ item_id: string; qty: string; cost: string }[]>(
    po?.purchase_order_lines?.map((l) => ({ item_id: l.item_id, qty: String(Number(l.qty)), cost: num(l.unit_cost, d) })) ?? [{ item_id: '', qty: '', cost: '' }])
  const [err, setErr] = useState<string | null>(null)
  const total = lines.reduce((a, l) => a + Math.round((parseFloat(l.qty) || 0) * (toMinor(l.cost || '0', d) || 0)), 0)
  useEffect(() => { if (!supplier && suppliers[0]) setSupplier(suppliers[0].id) }, [suppliers, supplier])

  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try {
      await rpc('save_po', { p: { id: po?.id ?? null, tenant_id: tn.id, branch_id: s.branch!.id, supplier_id: supplier, note,
        lines: lines.filter((l) => l.item_id && parseFloat(l.qty) > 0).map((l) => ({ item_id: l.item_id, qty: parseFloat(l.qty), unit_cost: toMinor(l.cost || '0', d) })) } })
      onSaved()
    } catch (x) { setErr((x as Error).message) }
  }
  const set = (i: number, patch: Partial<(typeof lines)[number]>) => setLines(lines.map((l, j) => (j === i ? { ...l, ...patch } : l)))
  return (
    <Modal title={po ? `${t('Edit')} ${po.number}` : t('New purchase order')} onClose={onClose} wide>
      <form className="stack" onSubmit={save}>
        {suppliers.length === 0 && <p className="amber-note">{t('Add a supplier first (Suppliers tab).')}</p>}
        <div className="grid2">
          <label className="field"><span>{t('Supplier')}</span>
            <select id="po-supplier" required value={supplier} onChange={(e) => setSupplier(e.target.value)}>{suppliers.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
          <label className="field"><span>{t('Note')}</span><input id="po-note" value={note} onChange={(e) => setNote(e.target.value)} /></label>
        </div>
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Item')}</th><th className="num">{t('Qty')}</th><th className="num">{t('Unit cost')}</th><th className="num">{t('Total')}</th><th /></tr></thead>
          <tbody>{lines.map((l, i) => (
            <tr key={i}>
              <td><select id={`po-item-${i}`} value={l.item_id} onChange={(e) => { const it = items.find((x) => x.id === e.target.value); set(i, { item_id: e.target.value, cost: l.cost || (it ? num(it.cost, d) : '') }) }}>
                <option value="">—</option>{items.map((x) => <option key={x.id} value={x.id}>{nameOf(x)}</option>)}</select></td>
              <td><input id={`po-qty-${i}`} className="qty-in" inputMode="decimal" value={l.qty} onChange={(e) => set(i, { qty: e.target.value })} /></td>
              <td><input id={`po-cost-${i}`} className="qty-in" inputMode="decimal" value={l.cost} onChange={(e) => set(i, { cost: e.target.value })} /></td>
              <td className="num">{num(Math.round((parseFloat(l.qty) || 0) * (toMinor(l.cost || '0', d) || 0)), d)}</td>
              <td><button type="button" className="icon" aria-label={t('Remove')} onClick={() => setLines(lines.filter((_, j) => j !== i))}>✕</button></td>
            </tr>))}</tbody>
        </table></div>
        <div className="row between"><button type="button" onClick={() => setLines([...lines, { item_id: '', qty: '', cost: '' }])}>{t('Add line')}</button>
          <b>{t('Total')}: {fmt(total, tn, lang)}</b></div>
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!supplier}>{t('Save draft')}</button></div>
      </form>
    </Modal>
  )
}

function PoDetail({ po, onClose, onEdit, onChanged }: { po: PurchaseOrder; onClose: () => void; onEdit: () => void; onChanged: () => Promise<void> }) {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const { items } = useCatalog()
  const approval = useApproval()
  const [mode, setMode] = useState<null | 'receive' | 'cancel' | 'bill'>(null)
  const [serials, setSerials] = useState<Record<string, string>>({})
  const [bill, setBill] = useState<{ no: string; date: string; vat: string; lines: Record<string, { qty: string; cost: string }> }>({ no: '', date: new Date().toISOString().slice(0, 10), vat: '', lines: {} })
  const [billMsg, setBillMsg] = useState<string | null>(null)
  const [qty, setQty] = useState<Record<string, string>>({})
  const [batch, setBatch] = useState<Record<string, { batch_no: string; expiry: string }>>({})
  const [ref, setRef] = useState('')
  const [reason, setReason] = useState('')
  const [people, setPeople] = useState<Record<string, string>>({})
  useEffect(() => {
    void supabase.from('memberships').select('user_id, display_name').eq('tenant_id', tn.id).then(({ data }) => {
      const m: Record<string, string> = {}; for (const x of data ?? []) m[x.user_id] = x.display_name; setPeople(m)
    })
  }, [tn.id])
  const itemName = useMemo(() => { const m = new Map(items.map((i) => [i.id, i])); return (id: string) => nameOf(m.get(id)) || '…' }, [items, nameOf])

  async function approve() { const r = await approval.run((pin) => rpc('approve_po', { p_po: po.id, p_pin: pin ?? null })); if (r) await onChanged() }
  async function cancel() { const r = await approval.run(() => rpc('cancel_po', { p_po: po.id, p_reason: reason }).then(() => true)); if (r) { setMode(null); await onChanged() } }
  async function receive() {
    const lines = Object.entries(qty).filter(([, v]) => parseFloat(v) > 0).map(([line_id, v]) => ({ line_id, qty: parseFloat(v),
      serials: serials[line_id] ? serials[line_id].split(/[\s,;]+/).map((x) => x.trim()).filter(Boolean) : undefined }))
    // items with expiry tracking: batch number and expiry date per received line (keyed by item)
    const batches = Object.fromEntries((po.purchase_order_lines ?? []).filter((l) => batch[l.id]?.batch_no && parseFloat(qty[l.id] ?? '') > 0).map((l) => [l.item_id, { batch_no: batch[l.id].batch_no, expiry: batch[l.id].expiry || null }]))
    const r = await approval.run(() => rpc(s.has('batches') ? 'receive_po_batches' : 'receive_po', { p: { po_id: po.id, supplier_ref: ref, lines, ...(s.has('batches') ? { batches } : {}) } }))
    if (r) { setMode(null); setQty({}); await onChanged() }
  }
  function startBill() {
    setBill({ no: '', date: new Date().toISOString().slice(0, 10), vat: '', lines: Object.fromEntries((po.purchase_order_lines ?? [])
      .map((l) => [l.id, { qty: String(Math.max(Number(l.received_qty) - Number(l.billed_qty ?? 0), 0)), cost: num(l.unit_cost, tn.currency_decimals) }])) })
    setBillMsg(null); setMode('bill')
  }
  async function saveBill() {
    const d = tn.currency_decimals
    const r = await approval.run((pin) => rpc<{ number: string; match_status: string; variance: number }>('record_supplier_invoice', { p: { po_id: po.id, supplier_no: bill.no, invoice_date: bill.date,
      vat: bill.vat ? toMinor(bill.vat, d) : 0, approver_pin: pin ?? null,
      lines: Object.entries(bill.lines).filter(([, v]) => parseFloat(v.qty) > 0).map(([po_line_id, v]) => ({ po_line_id, qty: parseFloat(v.qty), unit_cost: toMinor(v.cost, d) })) } }))
    if (r) { setMode(null); setBillMsg(r.match_status === 'matched' ? t('Bill {n} matches the order and the receipt.', { n: r.number }) : t('Bill {n} recorded with a price difference of {v} (approved).', { n: r.number, v: fmt(r.variance, tn, lang) })); await onChanged() }
  }
  const remainingAll = () => setQty(Object.fromEntries((po.purchase_order_lines ?? []).map((l) => [l.id, String(Number(l.qty) - Number(l.received_qty))])))

  return (
    <Modal title={`${t('Purchase order')} ${po.number}`} onClose={onClose} wide>
      <div className="stack">
        <div className="row between wrap">
          <span className={`pill po-${po.status}`}>{t(STATUS[po.status])}</span>
          <span className="muted small">{po.suppliers?.name} · {t('Created by')} {people[po.created_by] ?? '…'}{po.approved_by ? ` · ${t('Approved by')} ${people[po.approved_by] ?? '…'}` : ''}</span>
        </div>
        {po.note && <p className="muted">{po.note}</p>}
        {po.cancelled_reason && <p className="error">{t('Cancelled')}: {po.cancelled_reason}</p>}
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Item')}</th><th className="num">{t('Ordered')}</th><th className="num">{t('Received')}</th><th className="num">{t('Billed')}</th><th className="num">{t('Unit cost')}</th><th className="num">{t('Total')}</th>{mode === 'receive' && <th>{t('Receive now')}</th>}{mode === 'receive' && items.some((i) => i.track_serial) && <th>{t('Serial numbers')}</th>}{mode === 'bill' && <><th>{t('Billed qty')}</th><th>{t('Billed price')}</th></>}{mode === 'receive' && s.has('batches') && <th>{t('Batch / expiry')}</th>}</tr></thead>
          <tbody>{(po.purchase_order_lines ?? []).map((l) => (
            <tr key={l.id}><td>{itemName(l.item_id)}</td><td className="num">{Number(l.qty)}</td><td className="num">{Number(l.received_qty)}</td><td className="num">{Number(l.billed_qty ?? 0)}</td>
              <td className="num">{num(l.unit_cost, tn.currency_decimals)}</td><td className="num">{num(Math.round(Number(l.qty) * l.unit_cost), tn.currency_decimals)}</td>
              {mode === 'receive' && <td><input id={`rcv-${l.id}`} className="qty-in" inputMode="decimal" value={qty[l.id] ?? ''} placeholder={String(Number(l.qty) - Number(l.received_qty))} onChange={(e) => setQty({ ...qty, [l.id]: e.target.value })} /></td>}
              {mode === 'receive' && items.some((i) => i.track_serial) && <td>{items.find((i) => i.id === l.item_id)?.track_serial
                ? <textarea id={`rcv-serials-${l.id}`} rows={2} placeholder={t('Scan one per line')} value={serials[l.id] ?? ''} onChange={(e) => setSerials({ ...serials, [l.id]: e.target.value })} /> : '—'}</td>}
              {mode === 'bill' && <><td><input id={`bill-qty-${l.id}`} className="qty-in" inputMode="decimal" value={bill.lines[l.id]?.qty ?? ''} onChange={(e) => setBill({ ...bill, lines: { ...bill.lines, [l.id]: { ...bill.lines[l.id], qty: e.target.value } } })} /></td>
                <td><input id={`bill-cost-${l.id}`} className="qty-in" inputMode="decimal" value={bill.lines[l.id]?.cost ?? ''} onChange={(e) => setBill({ ...bill, lines: { ...bill.lines, [l.id]: { ...bill.lines[l.id], cost: e.target.value } } })} /></td></>}
              {mode === 'receive' && s.has('batches') && <td>{items.find((i) => i.id === l.item_id)?.track_expiry ? <div className="row">
                <input id={`rcv-batch-${l.id}`} className="batch-in" placeholder={t('Batch')} value={batch[l.id]?.batch_no ?? ''} onChange={(e) => setBatch({ ...batch, [l.id]: { batch_no: e.target.value, expiry: batch[l.id]?.expiry ?? '' } })} />
                <input id={`rcv-exp-${l.id}`} type="date" aria-label={t('Expiry date')} value={batch[l.id]?.expiry ?? ''} onChange={(e) => setBatch({ ...batch, [l.id]: { batch_no: batch[l.id]?.batch_no ?? '', expiry: e.target.value } })} /></div> : '—'}</td>}
            </tr>))}</tbody>
        </table></div>
        <div className="row end"><b>{t('Total')}: {fmt(po.total, tn, lang)}</b></div>

        {mode === 'receive' && (
          <div className="card stack">
            <div className="row between"><h2>{t('Receive goods')}</h2><button className="ghost small" onClick={remainingAll}>{t('Receive everything outstanding')}</button></div>
            <label className="field"><span>{t('Supplier delivery / invoice number')}</span><input id="rcv-ref" value={ref} onChange={(e) => setRef(e.target.value)} /></label>
            <p className="muted small">{t('Stock and average cost update immediately; the amount owed to the supplier is posted to accounts payable.')}</p>
            <button className="primary" onClick={() => void receive()}>{t('Confirm receipt')}</button>
          </div>
        )}
        {mode === 'bill' && (
          <div className="card stack">
            <h2>{t('Supplier invoice')}</h2>
            <div className="grid2">
              <label className="field"><span>{t('Supplier invoice number')}</span><input id="bill-no" value={bill.no} onChange={(e) => setBill({ ...bill, no: e.target.value })} /></label>
              <label className="field"><span>{t('Invoice date')}</span><input id="bill-date" type="date" value={bill.date} onChange={(e) => setBill({ ...bill, date: e.target.value })} /></label>
              <label className="field"><span>{t('VAT on the bill')}</span><input id="bill-vat" inputMode="decimal" value={bill.vat} onChange={(e) => setBill({ ...bill, vat: e.target.value })} placeholder="0" /></label>
            </div>
            <p className="muted small">{t("Three-way match: each line is checked against the order price and the quantity received. A difference needs a manager's approval and goes to purchase price variance.")}</p>
            <button className="primary" disabled={!bill.no.trim()} onClick={() => void saveBill()}>{t('Record supplier invoice')}</button>
          </div>
        )}
        {billMsg && <p className="success" role="status">{billMsg}</p>}
        {mode === 'cancel' && (
          <div className="card stack">
            <label className="field"><span>{t('Reason (required)')}</span><input id="po-cancel-reason" value={reason} onChange={(e) => setReason(e.target.value)} /></label>
            <button className="danger" disabled={!reason.trim()} onClick={() => void cancel()}>{t('Cancel order')}</button>
          </div>
        )}
        {approval.error && <p className="error">{approval.error}</p>}
        <div className="row end wrap">
          {po.status === 'draft' && s.can('purchase.create') && <button onClick={onEdit}>{t('Edit')}</button>}
          {(po.status === 'draft' || po.status === 'approved') && (s.can('purchase.create') || s.can('purchase.approve')) && <button className="danger" onClick={() => setMode('cancel')}>{t('Cancel order')}</button>}
          {po.status === 'draft' && <button className="primary" onClick={() => void approve()}>{t('Approve')}</button>}
          {(po.status === 'approved' || po.status === 'partially_received') && s.can('inventory.receive') && <button className="primary" onClick={() => setMode('receive')}>{t('Receive goods')}</button>}
          {(po.status === 'partially_received' || po.status === 'received') && (s.can('payables.pay') || s.can('purchase.create')) && (po.purchase_order_lines ?? []).some((l) => Number(l.received_qty) > Number(l.billed_qty ?? 0)) &&
            <button onClick={startBill}>{t('Record supplier invoice')}</button>}
        </div>
        {po.status === 'draft' && <p className="muted small">{t('The person who created an order cannot approve it. Another manager approves with their PIN.')}</p>}
      </div>
      {approval.dialog}
    </Modal>
  )
}

function Suppliers() {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [rows, setRows] = useState<Supplier[]>([])
  const [edit, setEdit] = useState<Partial<Supplier> | null>(null)
  const [stmt, setStmt] = useState<Supplier | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => {
    const { data } = await supabase.from('suppliers').select('*').eq('tenant_id', tn.id).order('name'); setRows((data ?? []) as Supplier[])
  }, [tn.id])
  useEffect(() => { void load() }, [load])
  async function save(e: React.FormEvent) {
    e.preventDefault(); if (!edit) return
    const row = { tenant_id: tn.id, name: edit.name?.trim(), name_ar: edit.name_ar || null, phone: edit.phone || null, email: edit.email || null,
      tax_number: edit.tax_number || null, payment_terms_days: Number(edit.payment_terms_days ?? 30), is_active: edit.is_active ?? true }
    const r = edit.id ? await supabase.from('suppliers').update(row).eq('id', edit.id) : await supabase.from('suppliers').insert(row)
    if (r.error) setErr(r.error.message); else { setEdit(null); await load() }
  }
  return (
    <section className="stack">
      {s.can('suppliers.manage') && <div className="row end"><button className="primary" onClick={() => setEdit({ payment_terms_days: 30, is_active: true })}>{t('Add supplier')}</button></div>}
      {rows.length === 0 ? <Empty title={t('No suppliers yet.')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>{t('Phone')}</th><th>{t('VAT / tax number (optional)')}</th><th className="num">{t('Payment terms (days)')}</th><th /></tr></thead>
          <tbody>{rows.map((r) => (
            <tr key={r.id} className={r.is_active ? '' : 'dim'}><td>{r.name}</td><td className="mono">{r.phone}</td><td>{r.tax_number}</td><td className="num">{r.payment_terms_days}</td>
              <td className="row">{(s.can('payables.pay') || s.can('suppliers.manage') || s.can('finance.view')) && <button className="ghost small" onClick={() => setStmt(r)}>{t('Statement')}</button>}
                {s.can('suppliers.manage') && <button className="ghost small" onClick={() => setEdit(r)}>{t('Edit')}</button>}</td></tr>))}</tbody>
        </table></div>)}
      {stmt && <Modal title={`${t('Statement')} · ${stmt.name}`} onClose={() => setStmt(null)} wide><Statement kind="ap" partyId={stmt.id} partyName={stmt.name} /></Modal>}
      {edit && (
        <Modal title={edit.id ? t('Edit supplier') : t('Add supplier')} onClose={() => setEdit(null)}>
          <form className="stack" onSubmit={save}>
            <label className="field"><span>{t('Name')}</span><input id="sup-name" required value={edit.name ?? ''} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
            <label className="field"><span>{t('Name (Arabic)')}</span><input id="sup-name-ar" dir="rtl" value={edit.name_ar ?? ''} onChange={(e) => setEdit({ ...edit, name_ar: e.target.value })} /></label>
            <label className="field"><span>{t('Phone')}</span><input id="sup-phone" value={edit.phone ?? ''} onChange={(e) => setEdit({ ...edit, phone: e.target.value })} /></label>
            <label className="field"><span>{t('VAT / tax number (optional)')}</span><input id="sup-tax" value={edit.tax_number ?? ''} onChange={(e) => setEdit({ ...edit, tax_number: e.target.value })} /></label>
            <label className="field"><span>{t('Payment terms (days)')}</span><input id="sup-terms" inputMode="numeric" value={String(edit.payment_terms_days ?? 30)} onChange={(e) => setEdit({ ...edit, payment_terms_days: Number(e.target.value) || 0 })} /></label>
            <label className="check"><input id="sup-active" type="checkbox" checked={edit.is_active ?? true} onChange={(e) => setEdit({ ...edit, is_active: e.target.checked })} />{t('Active')}</label>
            {err && <p className="error">{err}</p>}
            <div className="row end"><button type="button" className="ghost" onClick={() => setEdit(null)}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
          </form>
        </Modal>)}
    </section>
  )
}

/** Staff ask for stock; a buyer approves it and marks it ordered once the purchase order is out. */
function Requests() {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const { items } = useCatalog()
  const approval = useApproval()
  const [rows, setRows] = useState<{ id: string; number: string; lines: { item_id: string; qty: number }[]; note: string | null; status: string; created_at: string }[]>([])
  const [lines, setLines] = useState<{ item_id: string; qty: string }[]>([{ item_id: '', qty: '' }])
  const [note, setNote] = useState('')
  const load = useCallback(async () => { const { data } = await supabase.from('purchase_requests').select('*').eq('tenant_id', tn.id).order('created_at', { ascending: false }).limit(200); setRows(data ?? []) }, [tn.id])
  useEffect(() => { void load() }, [load])
  async function save() {
    const r = await approval.run(() => rpc('save_purchase_request', { p: { tenant_id: tn.id, branch_id: s.branch!.id, note, lines: lines.filter((l) => l.item_id && parseFloat(l.qty) > 0).map((l) => ({ item_id: l.item_id, qty: parseFloat(l.qty) })) } }))
    if (r) { setLines([{ item_id: '', qty: '' }]); setNote(''); await load() }
  }
  async function decide(id: string, status: string) { const r = await approval.run(() => rpc('decide_purchase_request', { p_id: id, p_status: status, p_po: null }).then(() => true)); if (r) await load() }
  const name = (id: string) => nameOf(items.find((i) => i.id === id)) || '…'
  return (
    <section className="stack">
      {(s.can('purchase.request') || s.can('purchase.create')) && <form className="card stack" onSubmit={(e) => { e.preventDefault(); void save() }}>
        <h2>{t('New purchase request')}</h2>
        {lines.map((l, i) => <div key={i} className="row">
          <select id={`pr-item-${i}`} aria-label={t('Item')} value={l.item_id} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, item_id: e.target.value } : x)))}><option value="">—</option>{items.map((it) => <option key={it.id} value={it.id}>{nameOf(it)}</option>)}</select>
          <input id={`pr-qty-${i}`} className="qty-in" aria-label={t('Qty')} inputMode="decimal" value={l.qty} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} /></div>)}
        <div className="row wrap"><button type="button" className="ghost" onClick={() => setLines([...lines, { item_id: '', qty: '' }])}>{t('Add line')}</button>
          <input id="pr-note" aria-label={t('Note')} placeholder={t('Note')} value={note} onChange={(e) => setNote(e.target.value)} /><button className="primary">{t('Send request')}</button></div>
      </form>}
      {approval.error && <p className="error">{approval.error}</p>}
      {rows.length === 0 ? <Empty title={t('No purchase requests')} /> : <div className="table-wrap"><table className="list">
        <thead><tr><th>{t('Number')}</th><th>{t('Date')}</th><th>{t('Items')}</th><th>{t('Status')}</th><th /></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.id}><td>{r.number}</td><td>{r.created_at.slice(0, 10)}</td><td>{r.lines.map((l) => `${name(l.item_id)} × ${l.qty}`).join(' · ')}{r.note ? ` — ${r.note}` : ''}</td>
          <td><span className={`pill ${r.status}`}>{t(r.status)}</span></td>
          <td className="row">{s.can('purchase.create') && r.status === 'pending' && <><button className="ghost small" onClick={() => void decide(r.id, 'approved')}>{t('Approve')}</button><button className="ghost small" onClick={() => void decide(r.id, 'rejected')}>{t('Reject')}</button></>}
            {s.can('purchase.create') && r.status === 'approved' && <button className="ghost small" onClick={() => void decide(r.id, 'ordered')}>{t('Mark as ordered')}</button>}</td></tr>)}</tbody></table></div>}
      {approval.dialog}
    </section>
  )
}

/** Goods sent back to a supplier: stock goes out at average cost, the supplier's balance goes down by the credit price. */
function Returns() {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const { items, suppliers } = useCatalog()
  const approval = useApproval()
  const [rows, setRows] = useState<{ id: string; number: string; supplier_id: string; reason: string; total: number; created_at: string; lines: { name: string; qty: number }[] }[]>([])
  const [f, setF] = useState({ supplier_id: '', reason: '', vat: '' })
  const empty = { item_id: '', qty: '', cost: '', serials: '' }
  const [lines, setLines] = useState([empty])
  const load = useCallback(async () => { const { data } = await supabase.from('purchase_returns').select('*').eq('tenant_id', tn.id).order('created_at', { ascending: false }).limit(200); setRows(data ?? []) }, [tn.id])
  useEffect(() => { void load() }, [load])
  const upd = (i: number, k: keyof typeof empty, v: string) => setLines(lines.map((x, j) => (j === i ? { ...x, [k]: v } : x)))
  async function save() {
    const r = await approval.run(() => rpc('return_to_supplier', { p: { tenant_id: tn.id, branch_id: s.branch!.id, supplier_id: f.supplier_id, reason: f.reason, vat: f.vat ? toMinor(f.vat, d) : 0,
      lines: lines.filter((l) => l.item_id && parseFloat(l.qty) > 0).map((l) => ({ item_id: l.item_id, qty: parseFloat(l.qty), unit_cost: l.cost ? toMinor(l.cost, d) : undefined,
        serials: l.serials ? l.serials.split(/[\s,;]+/).filter(Boolean) : undefined })) } }))
    if (r) { setLines([empty]); setF({ supplier_id: '', reason: '', vat: '' }); await load() }
  }
  return (
    <section className="stack">
      <form className="card stack" onSubmit={(e) => { e.preventDefault(); void save() }}>
        <div className="grid2">
          <label className="field"><span>{t('Supplier')}</span><select id="rtv-sup" value={f.supplier_id} onChange={(e) => setF({ ...f, supplier_id: e.target.value })}><option value="">—</option>{suppliers.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
          <label className="field"><span>{t('Reason')}</span><input id="rtv-reason" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} placeholder={t('e.g. Damaged on arrival')} /></label>
        </div>
        {lines.map((l, i) => { const it = items.find((x) => x.id === l.item_id)
          return <div key={i} className="row wrap">
            <select id={`rtv-item-${i}`} aria-label={t('Item')} value={l.item_id} onChange={(e) => upd(i, 'item_id', e.target.value)}><option value="">—</option>{items.map((x) => <option key={x.id} value={x.id}>{nameOf(x)}</option>)}</select>
            <input id={`rtv-qty-${i}`} className="qty-in" aria-label={t('Qty')} placeholder={t('Qty')} inputMode="decimal" value={l.qty} onChange={(e) => upd(i, 'qty', e.target.value)} />
            <input id={`rtv-cost-${i}`} className="qty-in" aria-label={t('Credit price')} placeholder={it ? num(it.cost, d) : t('Price')} inputMode="decimal" value={l.cost} onChange={(e) => upd(i, 'cost', e.target.value)} />
            {it?.track_serial && <input id={`rtv-ser-${i}`} aria-label={t('Serial numbers')} placeholder={t('Serial numbers')} value={l.serials} onChange={(e) => upd(i, 'serials', e.target.value)} />}</div> })}
        <div className="row wrap"><button type="button" className="ghost" onClick={() => setLines([...lines, empty])}>{t('Add line')}</button>
          <input id="rtv-vat" className="qty-in" aria-label={t('VAT')} placeholder={t('VAT')} inputMode="decimal" value={f.vat} onChange={(e) => setF({ ...f, vat: e.target.value })} />
          <button className="primary" disabled={!f.supplier_id || !f.reason.trim()}>{t('Return to supplier')}</button></div>
        <p className="muted small">{t("Stock leaves at its average cost; the supplier's balance goes down by the credit price. Any difference goes to purchase price variance.")}</p>
      </form>
      {approval.error && <p className="error">{approval.error}</p>}
      {rows.length > 0 && <div className="table-wrap"><table className="list">
        <thead><tr><th>{t('Number')}</th><th>{t('Date')}</th><th>{t('Supplier')}</th><th>{t('Items')}</th><th>{t('Reason')}</th><th className="num">{t('Total')}</th></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.id}><td>{r.number}</td><td>{r.created_at.slice(0, 10)}</td><td>{suppliers.find((x) => x.id === r.supplier_id)?.name}</td>
          <td>{r.lines.map((l) => `${l.name} × ${l.qty}`).join(' · ')}</td><td>{r.reason}</td><td className="num">{fmt(r.total, tn, lang)}</td></tr>)}</tbody></table></div>}
      {approval.dialog}
    </section>
  )
}

import { useCallback, useEffect, useMemo, useState } from 'react'
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
  const [tab, setTab] = useState<'orders' | 'suppliers'>('orders')
  return (
    <div className="page">
      <h1>{t('Purchasing')}</h1>
      <div className="tabs">
        <button className={tab === 'orders' ? 'on' : ''} onClick={() => setTab('orders')}>{t('Purchase orders')}</button>
        {(s.can('suppliers.manage') || s.can('purchase.create')) && <button className={tab === 'suppliers' ? 'on' : ''} onClick={() => setTab('suppliers')}>{t('Suppliers')}</button>}
      </div>
      {tab === 'orders' ? <Orders /> : <Suppliers />}
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
  const [mode, setMode] = useState<null | 'receive' | 'cancel'>(null)
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
    const lines = Object.entries(qty).filter(([, v]) => parseFloat(v) > 0).map(([line_id, v]) => ({ line_id, qty: parseFloat(v) }))
    // items with expiry tracking: batch number and expiry date per received line (keyed by item)
    const batches = Object.fromEntries((po.purchase_order_lines ?? []).filter((l) => batch[l.id]?.batch_no && parseFloat(qty[l.id] ?? '') > 0).map((l) => [l.item_id, { batch_no: batch[l.id].batch_no, expiry: batch[l.id].expiry || null }]))
    const r = await approval.run(() => rpc(s.has('batches') ? 'receive_po_batches' : 'receive_po', { p: { po_id: po.id, supplier_ref: ref, lines, ...(s.has('batches') ? { batches } : {}) } }))
    if (r) { setMode(null); setQty({}); await onChanged() }
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
          <thead><tr><th>{t('Item')}</th><th className="num">{t('Ordered')}</th><th className="num">{t('Received')}</th><th className="num">{t('Unit cost')}</th><th className="num">{t('Total')}</th>{mode === 'receive' && <th>{t('Receive now')}</th>}{mode === 'receive' && s.has('batches') && <th>{t('Batch / expiry')}</th>}</tr></thead>
          <tbody>{(po.purchase_order_lines ?? []).map((l) => (
            <tr key={l.id}><td>{itemName(l.item_id)}</td><td className="num">{Number(l.qty)}</td><td className="num">{Number(l.received_qty)}</td>
              <td className="num">{num(l.unit_cost, tn.currency_decimals)}</td><td className="num">{num(Math.round(Number(l.qty) * l.unit_cost), tn.currency_decimals)}</td>
              {mode === 'receive' && <td><input id={`rcv-${l.id}`} className="qty-in" inputMode="decimal" value={qty[l.id] ?? ''} placeholder={String(Number(l.qty) - Number(l.received_qty))} onChange={(e) => setQty({ ...qty, [l.id]: e.target.value })} /></td>}
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
              <td>{s.can('suppliers.manage') && <button className="ghost small" onClick={() => setEdit(r)}>{t('Edit')}</button>}</td></tr>))}</tbody>
        </table></div>)}
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

import { Check, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { useName, useT } from '../../lib/i18n'
import { fmt, num, toMinor } from '../../lib/money'
import { parseError, rpc, supabase } from '../../lib/supabase'
import type { Customer, Item, OnlineOrder, Tenant } from '../../lib/types'
import { Modal } from '../ui'

/** Sell a gift card: the amount, and the code if a pre-printed card is used (otherwise a code is made). */
export function GiftCardDialog({ item, decimals, onAdd, onClose }: { item: Item; decimals: number; onAdd: (amount: number, code: string) => void; onClose: () => void }) {
  const { t } = useT()
  const [amount, setAmount] = useState(item.price ? num(item.price, decimals) : '')
  const [code, setCode] = useState('')
  const v = toMinor(amount, decimals)
  return (
    <Modal title={t('Gift card')} onClose={onClose}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); if (v > 0) onAdd(v, code.trim().toUpperCase()) }}>
        <label className="field"><span>{t('Amount')}</span><input id="gc-amount" autoFocus inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
        <label className="field"><span>{t('Card code (scan a pre-printed card, or leave empty for a new code)')}</span><input id="gc-code" value={code} onChange={(e) => setCode(e.target.value)} /></label>
        <p className="muted small">{t('No VAT is charged on a gift card; VAT applies when it is spent.')}</p>
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!(v > 0)}>{t('Add to sale')}</button></div>
      </form>
    </Modal>
  )
}

export interface DeliveryInfo { address: string; phone: string; note: string; driver_id: string | null }

/** Delivery by our own driver: where to, which driver (or later), and the payment can be cash on delivery. */
export function DeliveryDialog({ customer, drivers, initial, onSave, onClose, onPickCustomer }: {
  customer: Customer | null; drivers: { user_id: string; display_name: string }[]; initial: DeliveryInfo | null
  onSave: (d: DeliveryInfo | null) => void; onClose: () => void; onPickCustomer: () => void
}) {
  const { t } = useT()
  const [f, setF] = useState<DeliveryInfo>(initial ?? { address: customer?.address ?? '', phone: customer?.phone ?? '', note: '', driver_id: null })
  return (
    <Modal title={t('Own delivery')} onClose={onClose}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); if (f.address.trim()) onSave(f) }}>
        <div className="row"><button type="button" className="ghost" onClick={onPickCustomer}>{customer ? customer.name : t('Choose customer')}</button></div>
        <label className="field"><span>{t('Address')}</span><textarea id="dl-address" rows={2} required value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} placeholder={t('Area, block, street, house, floor')} /></label>
        <label className="field"><span>{t('Phone')}</span><input id="dl-phone" inputMode="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></label>
        <label className="field"><span>{t('Driver')}</span><select id="dl-driver" value={f.driver_id ?? ''} onChange={(e) => setF({ ...f, driver_id: e.target.value || null })}>
          <option value="">{t('Assign later')}</option>{drivers.map((m) => <option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label>
        <label className="field"><span>{t('Note for the driver')}</span><input id="dl-note" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></label>
        <p className="muted small">{t('To let the customer pay the driver, choose “Cash on delivery” when paying.')}</p>
        <div className="row end">{initial && <button type="button" className="ghost danger" onClick={() => onSave(null)}>{t('Not a delivery')}</button>}
          <button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!f.address.trim()}>{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

/** Orders customers placed from the table QR or the kiosk: accept (to the kitchen / table), reject, or take payment. */
export function IncomingOrders({ orders, tenant, onClose, onChanged, onPay }: {
  orders: OnlineOrder[]; tenant: Tenant; onClose: () => void; onChanged: () => void; onPay: (o: OnlineOrder) => void
}) {
  const { t, lang } = useT()
  const nameOf = useName()
  const [err, setErr] = useState<string | null>(null)
  const [tables, setTables] = useState<Record<string, string>>({})
  useEffect(() => { void supabase.from('dining_tables').select('id, name').then(({ data }) => setTables(Object.fromEntries((data ?? []).map((x) => [x.id, x.name])))) }, [])
  async function handle(o: OnlineOrder, accept: boolean) {
    setErr(null)
    try { await rpc('handle_online_order', { p_id: o.id, p_accept: accept }); onChanged() } catch (e) { const p = parseError(e); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) }
  }
  return (
    <Modal title={t('Online orders')} onClose={onClose} wide>
      <div className="stack">
        {orders.length === 0 && <p className="muted">{t('No orders waiting.')}</p>}
        {orders.map((o) => (
          <div key={o.id} className="card incoming">
            <div className="row between"><b>#{o.number} · {o.source === 'qr' ? `${t('Table')} ${o.table_id ? tables[o.table_id] ?? '' : ''}` : t('Kiosk')}</b>
              <span className="muted small">{new Date(o.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}{o.name ? ` · ${o.name}` : ''}</span></div>
            <ul className="plain-list">{o.lines.map((l, i) => <li key={i}>{Number(l.qty)}× {nameOf(l)}{l.note ? ` · ${l.note}` : ''}</li>)}</ul>
            {o.note && <p className="muted small">» {o.note}</p>}
            <div className="row between"><b>{fmt(o.total, tenant, lang)}</b>
              <div className="row">
                {o.status === 'pending' && <button className="ghost danger" onClick={() => void handle(o, false)}><X size={15} />{t('Reject')}</button>}
                {o.status === 'pending' && o.source === 'qr' && <button className="primary" onClick={() => void handle(o, true)}><Check size={15} />{t('Accept and send to kitchen')}</button>}
                {o.source === 'kiosk' && <button className="primary" onClick={() => { if (o.status === 'pending') void rpc('handle_online_order', { p_id: o.id, p_accept: true }).catch(() => undefined); onPay(o) }}>{t('Take payment')}</button>}
              </div></div>
          </div>))}
        {err && <p className="error">{err}</p>}
      </div>
    </Modal>
  )
}

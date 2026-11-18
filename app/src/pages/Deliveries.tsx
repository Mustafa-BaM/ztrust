import { Banknote, MapPin, Phone } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Empty } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt } from '../lib/money'
import { useSession } from '../lib/session'
import { getShift } from '../lib/shift'
import { parseError, rpc, supabase } from '../lib/supabase'
import type { DeliveryRow } from '../lib/types'

const STATUS: Record<string, string> = { pending: 'Waiting for a driver', assigned: 'Assigned', picked_up: 'On the way', delivered: 'Delivered', failed: 'Failed' }

/** Own delivery: the branch assigns drivers and takes in their cash; a driver sees only their own deliveries. */
export default function Deliveries() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const me = s.session?.user.id
  const manager = s.can('sale.create')
  const [rows, setRows] = useState<DeliveryRow[]>([])
  const [drivers, setDrivers] = useState<{ user_id: string; display_name: string }[]>([])
  const [mine, setMine] = useState(!manager)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const load = useCallback(async () => {
    let q = supabase.from('deliveries').select('*, sales(number, total)').order('created_at', { ascending: false }).limit(200)
    q = mine ? q.eq('driver_id', me!) : q.eq('branch_id', s.branch!.id)
    const [d, dr] = await Promise.all([q, supabase.from('memberships').select('user_id, display_name').eq('tenant_id', tn.id).eq('is_driver', true).eq('is_active', true)])
    setRows((d.data ?? []) as DeliveryRow[]); setDrivers(dr.data ?? [])
  }, [mine, me, s.branch, tn.id])
  useEffect(() => { void load(); const id = window.setInterval(() => void load(), 15_000); return () => clearInterval(id) }, [load])
  const run = async (f: () => Promise<unknown>, ok?: string) => { setMsg(null); try { await f(); if (ok) setMsg({ ok: true, text: ok }); await load() } catch (e) { const p = parseError(e); setMsg({ ok: false, text: p.kind === 'message' ? t(p.message) : t('Not allowed') }) } }
  const open = rows.filter((r) => !['delivered', 'failed'].includes(r.status))
  const cashByDriver = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of rows) if (r.status === 'delivered' && r.cash_to_collect > 0 && !r.cash_settled && r.driver_id) m.set(r.driver_id, (m.get(r.driver_id) ?? 0) + r.cash_to_collect)
    return m
  }, [rows])
  const name = (id: string | null) => drivers.find((d) => d.user_id === id)?.display_name ?? '—'
  return (
    <div className="page">
      <div className="row between wrap">
        {manager && <div className="seg"><button className={!mine ? 'on' : ''} onClick={() => setMine(false)}>{t('All deliveries')}</button><button className={mine ? 'on' : ''} onClick={() => setMine(true)}>{t('My deliveries')}</button></div>}
      </div>
      <div className="kpi-row">
        <div className="kpi2"><span className="kpi2-label">{t('Waiting for a driver')}</span><b className={`kpi2-value ${rows.some((r) => r.status === 'pending') ? 'warn' : ''}`}>{rows.filter((r) => r.status === 'pending').length}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('On the way')}</span><b className="kpi2-value">{rows.filter((r) => ['assigned', 'picked_up'].includes(r.status)).length}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('Cash with drivers')}</span><b className="kpi2-value">{fmt([...cashByDriver.values()].reduce((a, v) => a + v, 0), tn, lang)}</b></div>
      </div>
      {msg && <p className={msg.ok ? 'success' : 'error'}>{msg.text}</p>}
      {!mine && cashByDriver.size > 0 && s.can('payments.receive') && (
        <div className="card"><h2>{t('Hand in driver cash')}</h2>
          <ul className="mod-list">{[...cashByDriver.entries()].map(([d, v]) => (
            <li key={d}><span><b>{name(d)}</b> · {fmt(v, tn, lang)}</span>
              <button className="primary small" onClick={() => void run(() => rpc('settle_driver_cash', { p_branch: s.branch!.id, p_driver: d, p_shift: getShift(s.branch?.id, me) }), t('Cash received into the drawer'))}><Banknote size={15} />{t('Receive cash')}</button></li>))}</ul>
        </div>)}
      {open.length === 0 && rows.length === 0 ? <Empty title={t('No deliveries yet')} hint={t('At the till, press “Own delivery” before paying.')} /> : (
        <div className="cards-col">{rows.map((r) => (
          <div key={r.id} className={`card delivery st-${r.status}`}>
            <div className="row between"><b>{r.sales?.number}</b><span className={`pill dl-${r.status}`}>{t(STATUS[r.status])}</span></div>
            <p><MapPin size={14} aria-hidden="true" /> {r.address}</p>
            {r.phone && <p><Phone size={14} aria-hidden="true" /> <a href={`tel:${r.phone}`}>{r.phone}</a></p>}
            {r.note && <p className="muted small">» {r.note}</p>}
            <p className="row between"><span className="muted">{t('Driver')}: {name(r.driver_id)}</span>{r.cash_to_collect > 0 && <b>{t('Collect {v}', { v: fmt(r.cash_to_collect, tn, lang) })}</b>}</p>
            <div className="row wrap">
              {!mine && ['pending', 'assigned'].includes(r.status) && (
                <select aria-label={t('Driver')} value={r.driver_id ?? ''} onChange={(e) => e.target.value && void run(() => rpc('delivery_status', { p_id: r.id, p_status: 'assigned', p_driver: e.target.value }))}>
                  <option value="">{t('Assign driver…')}</option>{drivers.map((d) => <option key={d.user_id} value={d.user_id}>{d.display_name}</option>)}</select>)}
              {r.address && <a className="button ghost small" href={`https://maps.google.com/?q=${encodeURIComponent(r.address)}`} target="_blank" rel="noreferrer">{t('Map')}</a>}
              {r.driver_id === me && r.status === 'assigned' && <button className="small" onClick={() => void run(() => rpc('delivery_status', { p_id: r.id, p_status: 'picked_up' }))}>{t('Picked up')}</button>}
              {r.driver_id === me && r.status === 'picked_up' && <button className="primary small" onClick={() => void run(() => rpc('delivery_status', { p_id: r.id, p_status: 'delivered' }))}>{t('Delivered')}</button>}
              {r.driver_id === me && r.status === 'picked_up' && <button className="ghost small danger" onClick={() => void run(() => rpc('delivery_status', { p_id: r.id, p_status: 'failed' }))}>{t('Could not deliver')}</button>}
            </div>
          </div>))}</div>)}
    </div>
  )
}

import { Copy, Plus, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../../components/ui'
import { useT } from '../../lib/i18n'
import { num, toMinor } from '../../lib/money'
import { useSession } from '../../lib/session'
import { parseError, publicAppUrl, rpc, supabase } from '../../lib/supabase'
import type { DiningTable, Membership } from '../../lib/types'

const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

/** Scale labels, loyalty points and the online booking page — shown only when their module is on. */
export function ModuleSettings() {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const st = tn.settings ?? {}
  const d = tn.currency_decimals
  const [f, setF] = useState({
    scale_prefix: st.scale_prefix ?? '20', scale_plu_len: String(st.scale_plu_len ?? 5), scale_mode: st.scale_mode ?? 'weight',
    loyalty_earn: String(st.loyalty_earn ?? 1), loyalty_point_value: num(Math.round(Number(st.loyalty_point_value ?? 0)), d), loyalty_min_points: String(st.loyalty_min_points ?? 0),
    booking_online: Boolean(st.booking_online), booking_slug: (tn as { booking_slug?: string | null }).booking_slug ?? '',
  })
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  if (!s.has('weighed') && !s.has('loyalty') && !s.has('appointments')) return null
  async function save() {
    setMsg(null)
    const settings = { ...st,
      ...(s.has('weighed') ? { scale_prefix: f.scale_prefix, scale_plu_len: Number(f.scale_plu_len) || 5, scale_mode: f.scale_mode } : {}),
      ...(s.has('loyalty') ? { loyalty_earn: Number(f.loyalty_earn) || 0, loyalty_point_value: toMinor(f.loyalty_point_value || '0', d), loyalty_min_points: Number(f.loyalty_min_points) || 0 } : {}),
      ...(s.has('appointments') ? { booking_online: f.booking_online } : {}) }
    const { error } = await supabase.from('tenants').update({ settings, ...(s.has('appointments') ? { booking_slug: f.booking_slug.trim().toLowerCase() || null } : {}) }).eq('id', tn.id)
    setMsg(error ? { ok: false, text: /booking_slug/.test(error.message) ? t('This booking address is taken or invalid. Use 3–40 letters, digits or hyphens.') : error.message } : { ok: true, text: t('Saved') })
    if (!error) await s.reload()
  }
  const link = f.booking_slug ? `${publicAppUrl}/book/${f.booking_slug.trim().toLowerCase()}` : ''
  return (
    <div className="card grid2">
      <h2 className="span2">{t('Selling rules')}</h2>
      {s.has('weighed') && <>
        <h3 className="span2 sub-h">{t('Scale labels')}</h3>
        <label className="field"><span>{t('Label starts with')}</span><input id="scale-prefix" value={f.scale_prefix} onChange={(e) => setF({ ...f, scale_prefix: e.target.value.replace(/\D/g, '') })} /></label>
        <label className="field"><span>{t('Digits in the item code (PLU)')}</span><input id="scale-plu" type="number" min={4} max={6} value={f.scale_plu_len} onChange={(e) => setF({ ...f, scale_plu_len: e.target.value })} /></label>
        <label className="field"><span>{t('The label carries')}</span><select id="scale-mode" value={f.scale_mode} onChange={(e) => setF({ ...f, scale_mode: e.target.value as 'weight' | 'price' })}>
          <option value="weight">{t('The weight in grams')}</option><option value="price">{t('The price')}</option></select></label>
        <p className="muted small">{t('Example: 20 00042 01250 7 = item 00042, 1.250 kg (13 digits: prefix, item code, value, check digit). Check the format printed by your scale.')}</p>
      </>}
      {s.has('loyalty') && <>
        <h3 className="span2 sub-h">{t('Loyalty points')}</h3>
        <label className="field"><span>{t('Points earned per 1 {c}', { c: tn.currency })}</span><input id="loy-earn" inputMode="decimal" value={f.loyalty_earn} onChange={(e) => setF({ ...f, loyalty_earn: e.target.value })} /></label>
        <label className="field"><span>{t('Value of one point ({c})', { c: tn.currency })}</span><input id="loy-value" inputMode="decimal" value={f.loyalty_point_value} onChange={(e) => setF({ ...f, loyalty_point_value: e.target.value })} /></label>
        <label className="field"><span>{t('Minimum points to redeem')}</span><input id="loy-min" type="number" min={0} value={f.loyalty_min_points} onChange={(e) => setF({ ...f, loyalty_min_points: e.target.value })} /></label>
        <p className="muted small">{t('Points are earned on what the customer pays with money, and taken back on refunds. Redeemed points are booked as a loyalty expense.')}</p>
      </>}
      {s.has('appointments') && <>
        <h3 className="span2 sub-h">{t('Online booking')}</h3>
        <label className="field"><span>{t('Booking page address')}</span><input id="book-slug" placeholder="my-salon" value={f.booking_slug} onChange={(e) => setF({ ...f, booking_slug: e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '') })} /></label>
        <label className="check"><input id="book-online" type="checkbox" checked={f.booking_online} onChange={(e) => setF({ ...f, booking_online: e.target.checked })} />{t('Customers can book online')}</label>
        {link && <div className="linkbox span2"><code>{link}</code><button type="button" onClick={() => void navigator.clipboard?.writeText(link).catch(() => undefined)}><Copy size={14} />{t('Copy')}</button></div>}
        <p className="muted small span2">{t('Put this link on Instagram, Google Maps or your website. Customers see your services and free times; staff who take bookings and their hours are set in Staff.')}</p>
      </>}
      <div className="row end span2">{msg && <span className={msg.ok ? 'success' : 'error'}>{msg.text}</span>}<button className="primary" onClick={() => void save()}>{t('Save')}</button></div>
    </div>
  )
}

/** Booking and commission details per staff member, and weekly working hours. */
export function StaffExtras({ m, onSaved }: { m: Membership & { bookable?: boolean; commission_pct?: number | null }; onSaved: () => void }) {
  const { t } = useT()
  const s = useSession()
  const [hours, setHours] = useState(false)
  const [bookable, setBookable] = useState(Boolean(m.bookable))
  const set = async (p: Record<string, unknown>) => { await rpc('set_staff_profile', { p_tenant: s.tenant!.id, p_user: m.user_id, p }).catch(() => undefined); onSaved() }
  return (
    <>
      {s.has('appointments') && <td><input aria-label={t('Takes bookings')} type="checkbox" checked={bookable} onChange={(e) => { setBookable(e.target.checked); void set({ bookable: e.target.checked }) }} />
        {bookable && <button className="ghost small" onClick={() => setHours(true)}>{t('Hours')}</button>}</td>}
      {s.has('commissions') && <td><input aria-label={t('Commission %')} className="qty-in" inputMode="decimal" defaultValue={m.commission_pct ?? ''} placeholder="0" onBlur={(e) => void set({ commission_pct: e.target.value })} /></td>}
      {hours && <HoursDialog userId={m.user_id} name={m.display_name} onClose={() => setHours(false)} />}
    </>
  )
}

function HoursDialog({ userId, name, onClose }: { userId: string; name: string; onClose: () => void }) {
  const { t } = useT()
  const s = useSession()
  const [rows, setRows] = useState<{ weekday: number; start_time: string; end_time: string; on: boolean }[]>(
    DAYS.map((_, i) => ({ weekday: i + 1, start_time: '09:00', end_time: '21:00', on: false })))
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => {
    void supabase.from('staff_hours').select('weekday, start_time, end_time').eq('branch_id', s.branch!.id).eq('user_id', userId).then(({ data }) => {
      if (!data?.length) return
      setRows(DAYS.map((_, i) => { const h = data.find((x) => x.weekday === i + 1); return { weekday: i + 1, start_time: (h?.start_time ?? '09:00').slice(0, 5), end_time: (h?.end_time ?? '21:00').slice(0, 5), on: Boolean(h) } }))
    })
  }, [userId, s.branch])
  async function save() {
    setErr(null)
    await supabase.from('staff_hours').delete().eq('branch_id', s.branch!.id).eq('user_id', userId)
    const { error } = await supabase.from('staff_hours').insert(rows.filter((r) => r.on).map((r) => ({ tenant_id: s.tenant!.id, branch_id: s.branch!.id, user_id: userId, weekday: r.weekday, start_time: r.start_time, end_time: r.end_time })))
    if (error) setErr(error.message); else onClose()
  }
  return (
    <Modal title={t('Working hours · {name}', { name })} onClose={onClose}>
      <div className="stack">
        {rows.map((r, i) => (
          <div key={r.weekday} className="row hours-row">
            <label className="check"><input type="checkbox" checked={r.on} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, on: e.target.checked } : x)))} />{t(DAYS[i])}</label>
            <input type="time" aria-label={t('From')} disabled={!r.on} value={r.start_time} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, start_time: e.target.value } : x)))} />
            <input type="time" aria-label={t('To')} disabled={!r.on} value={r.end_time} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, end_time: e.target.value } : x)))} />
          </div>))}
        {err && <p className="error">{err}</p>}
        <div className="row end"><button className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" onClick={() => void save()}>{t('Save')}</button></div>
      </div>
    </Modal>
  )
}

/** Tables per area for the floor plan in the POS. */
export function TablesSetup() {
  const { t } = useT()
  const s = useSession()
  const [list, setList] = useState<DiningTable[]>([])
  const [f, setF] = useState({ area: t('Main'), name: '', seats: '4', shape: 'square' })
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => {
    const { data } = await supabase.from('dining_tables').select('*').eq('branch_id', s.branch!.id).order('area').order('name')
    setList((data ?? []) as DiningTable[])
  }, [s.branch])
  useEffect(() => { void load() }, [load])
  async function add(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    // "T1-T10" adds ten tables at once
    const m = f.name.trim().match(/^(.*?)(\d+)\s*-\s*\D*(\d+)$/)
    const names = m ? Array.from({ length: Math.min(Number(m[3]) - Number(m[2]) + 1, 100) }, (_, i) => `${m[1]}${Number(m[2]) + i}`) : [f.name.trim()]
    const { error } = await supabase.from('dining_tables').insert(names.filter(Boolean).map((name) => ({ tenant_id: s.tenant!.id, branch_id: s.branch!.id, area: f.area.trim() || 'Main', name, seats: Number(f.seats) || 4, shape: f.shape })))
    if (error) { const p = parseError(error); setErr(p.kind === 'message' ? (/duplicate/.test(p.message) ? t('A table with this name already exists') : t(p.message)) : '') } else { setF({ ...f, name: '' }); await load() }
  }
  return (
    <section className="stack">
      <form className="card row wrap" onSubmit={add}>
        <label className="field"><span>{t('Area')}</span><input id="tb-area" value={f.area} onChange={(e) => setF({ ...f, area: e.target.value })} /></label>
        <label className="field"><span>{t('Table name or range')}</span><input id="tb-name" placeholder="T1-T10" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>{t('Seats')}</span><input id="tb-seats" className="qty-in" type="number" min={1} value={f.seats} onChange={(e) => setF({ ...f, seats: e.target.value })} /></label>
        <label className="field"><span>{t('Shape')}</span><select id="tb-shape" value={f.shape} onChange={(e) => setF({ ...f, shape: e.target.value })}>
          <option value="square">{t('Square')}</option><option value="round">{t('Round')}</option><option value="long">{t('Long')}</option></select></label>
        <button className="primary" disabled={!f.name.trim()}><Plus size={16} />{t('Add')}</button>
      </form>
      {err && <p className="error">{err}</p>}
      <div className="card table-wrap"><table className="list">
        <thead><tr><th>{t('Area')}</th><th>{t('Table')}</th><th className="num">{t('Seats')}</th><th>{t('Shape')}</th><th /></tr></thead>
        <tbody>{list.map((x) => (
          <tr key={x.id}><td>{x.area}</td><td><b>{x.name}</b></td><td className="num">{x.seats}</td><td>{t(x.shape === 'square' ? 'Square' : x.shape === 'round' ? 'Round' : 'Long')}</td>
            <td><button className="ghost small danger" aria-label={t('Delete')} onClick={() => void supabase.from('dining_tables').update({ is_active: !x.is_active }).eq('id', x.id).then(load)}>{x.is_active ? <Trash2 size={14} /> : t('Restore')}</button></td></tr>))}</tbody>
      </table></div>
    </section>
  )
}

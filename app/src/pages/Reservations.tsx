import { useSearchParams } from 'react-router-dom'
import { CalendarPlus, ChevronLeft, ChevronRight, UserPlus } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Empty, Modal } from '../components/ui'
import { useT } from '../lib/i18n'
import { useSession } from '../lib/session'
import { parseError, rpc, supabase } from '../lib/supabase'
import { partsIn, todayIn, zoned } from '../lib/tz'
import type { DiningTable } from '../lib/types'

interface Res { id: string; table_id: string | null; name: string; phone: string | null; party: number; starts_at: string; duration_min: number; status: string; note: string | null }
interface Wait { id: string; name: string; phone: string | null; party: number; status: string; note: string | null; created_at: string }
const STATUS: Record<string, string> = { booked: 'Booked', confirmed: 'Confirmed', seated: 'Seated', finished: 'Finished', no_show: 'No-show', cancelled: 'Cancelled' }

/** Table reservations for the day, and the walk-in waitlist with a WhatsApp “your table is ready”. */
export default function Reservations() {
  const { t } = useT()
  const s = useSession()
  const tz = s.branch?.timezone ?? 'Asia/Kuwait'
  const [day, setDay] = useState(() => todayIn(tz))
  const [list, setList] = useState<Res[]>([])
  const [wait, setWait] = useState<Wait[]>([])
  const [tables, setTables] = useState<DiningTable[]>([])
  const [edit, setEdit] = useState<Partial<Res> | null>(null)
  const [w, setW] = useState({ name: '', phone: '', party: '2' })
  const [err, setErr] = useState<string | null>(null)
  const [params, setParams] = useSearchParams()
  useEffect(() => { if (params.get('new')) { setEdit({ party: 2, duration_min: 90, starts_at: zoned(todayIn(tz), '20:00', tz).toISOString() }); setParams({}, { replace: true }) } }, [params, setParams, tz])
  const load = useCallback(async () => {
    if (!s.branch) return
    const from = zoned(day, '00:00', tz), to = new Date(from.getTime() + 86_400_000)
    const [r, q, tb] = await Promise.all([
      supabase.from('reservations').select('*').eq('branch_id', s.branch.id).gte('starts_at', from.toISOString()).lt('starts_at', to.toISOString()).order('starts_at'),
      supabase.from('waitlist').select('*').eq('branch_id', s.branch.id).in('status', ['waiting', 'notified']).order('created_at'),
      supabase.from('dining_tables').select('*').eq('branch_id', s.branch.id).eq('is_active', true).order('name'),
    ])
    setList((r.data ?? []) as Res[]); setWait((q.data ?? []) as Wait[]); setTables((tb.data ?? []) as DiningTable[])
  }, [s.branch, day, tz])
  useEffect(() => { void load(); const id = window.setInterval(() => void load(), 30_000); return () => clearInterval(id) }, [load])
  const run = async (f: () => Promise<unknown>) => { setErr(null); try { await f(); await load() } catch (e) { const p = parseError(e); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) } }
  const shift = (n: number) => { const d = new Date(`${day}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); setDay(d.toISOString().slice(0, 10)) }
  const waitMin = (x: Wait) => Math.floor((Date.now() - new Date(x.created_at).getTime()) / 60000)
  const wa = (phone: string | null, text: string) => (phone ? `https://wa.me/${phone.replace(/\D/g, '')}?text=${encodeURIComponent(text)}` : null)
  const live = list.filter((r) => !['cancelled', 'no_show'].includes(r.status))
  return (
    <div className="page">
      <div className="row between wrap">
        <div className="row"><button className="icon" aria-label={t('Previous day')} onClick={() => shift(-1)}><ChevronLeft size={18} className="flip-rtl" /></button>
          <input id="res-day" type="date" value={day} onChange={(e) => setDay(e.target.value)} />
          <button className="icon" aria-label={t('Next day')} onClick={() => shift(1)}><ChevronRight size={18} className="flip-rtl" /></button>
          <button className="ghost" onClick={() => setDay(todayIn(tz))}>{t('Today')}</button></div>
        <button className="primary" onClick={() => setEdit({ party: 2, duration_min: 90, starts_at: zoned(day, '20:00', tz).toISOString() })}><CalendarPlus size={16} />{t('New reservation')}</button>
      </div>
      <div className="kpi-row">
        <div className="kpi2"><span className="kpi2-label">{t('Reservations')}</span><b className="kpi2-value">{live.length}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('Guests expected')}</span><b className="kpi2-value">{live.reduce((a, r) => a + r.party, 0)}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('Waiting now')}</span><b className={`kpi2-value ${wait.length ? 'warn' : ''}`}>{wait.length}</b></div>
      </div>
      {err && <p className="error">{err}</p>}
      <div className="split">
        <section className="card">
          <h2>{t('Reservations')}</h2>
          {list.length === 0 ? <Empty title={t('No reservations this day')} /> : (
            <table className="list"><tbody>{list.map((r) => (
              <tr key={r.id} className={['cancelled', 'no_show'].includes(r.status) ? 'dim' : ''}>
                <td><b>{partsIn(new Date(r.starts_at), tz).hhmm}</b></td><td>{r.name}<div className="muted small">{r.phone}{r.note ? ` · ${r.note}` : ''}</div></td>
                <td>{t('{n} guests', { n: r.party })}</td><td>{tables.find((x) => x.id === r.table_id)?.name ?? '—'}</td>
                <td><span className={`pill st-${r.status}`}>{t(STATUS[r.status])}</span></td>
                <td><div className="row end wrap">
                  {r.status === 'booked' && <button className="ghost small" onClick={() => void run(() => rpc('set_reservation_status', { p_id: r.id, p_status: 'confirmed' }))}>{t('Confirm')}</button>}
                  {['booked', 'confirmed'].includes(r.status) && <button className="small" onClick={() => void run(() => rpc('set_reservation_status', { p_id: r.id, p_status: 'seated' }))}>{t('Seat')}</button>}
                  {r.status === 'seated' && <button className="ghost small" onClick={() => void run(() => rpc('set_reservation_status', { p_id: r.id, p_status: 'finished' }))}>{t('Finished')}</button>}
                  {['booked', 'confirmed'].includes(r.status) && <button className="ghost small" onClick={() => setEdit(r)}>{t('Edit')}</button>}
                  {['booked', 'confirmed'].includes(r.status) && <button className="ghost small" onClick={() => void run(() => rpc('set_reservation_status', { p_id: r.id, p_status: 'no_show' }))}>{t('No-show')}</button>}
                </div></td></tr>))}</tbody></table>)}
        </section>
        <section className="card">
          <h2>{t('Waitlist')}</h2>
          <form className="row wrap" onSubmit={(e) => { e.preventDefault(); if (w.name.trim()) void run(() => rpc('waitlist_add', { p_branch: s.branch!.id, p_name: w.name, p_phone: w.phone, p_party: Number(w.party) || 1 })).then(() => setW({ name: '', phone: '', party: '2' })) }}>
            <input id="wl-name" placeholder={t('Name')} value={w.name} onChange={(e) => setW({ ...w, name: e.target.value })} />
            <input id="wl-phone" placeholder={t('Mobile')} inputMode="tel" value={w.phone} onChange={(e) => setW({ ...w, phone: e.target.value })} />
            <input id="wl-party" className="qty-in" type="number" min={1} value={w.party} onChange={(e) => setW({ ...w, party: e.target.value })} aria-label={t('Guests')} />
            <button className="primary"><UserPlus size={15} />{t('Add')}</button>
          </form>
          {wait.length === 0 ? <p className="muted">{t('Nobody is waiting.')}</p> : (
            <ul className="mod-list">{wait.map((x, i) => {
              const link = wa(x.phone, t('{biz}: your table is ready. Please come to the host stand.', { biz: s.tenant!.name }))
              return (
                <li key={x.id}><div><b>{i + 1}. {x.name}</b> · {t('{n} guests', { n: x.party })}<p className="muted small">{t('{n} min', { n: waitMin(x) })}{x.status === 'notified' ? ` · ${t('Notified')}` : ''}</p></div>
                  <div className="row">
                    {link && <a className="button small" href={link} target="_blank" rel="noreferrer" onClick={() => void rpc('waitlist_status', { p_id: x.id, p_status: 'notified' }).then(load)}>{t('Table ready')}</a>}
                    <button className="small" onClick={() => void run(() => rpc('waitlist_status', { p_id: x.id, p_status: 'seated' }))}>{t('Seat')}</button>
                    <button className="ghost small" onClick={() => void run(() => rpc('waitlist_status', { p_id: x.id, p_status: 'left' }))}>{t('Left')}</button>
                  </div></li>)
            })}</ul>)}
        </section>
      </div>
      {edit && <ResForm r={edit} tables={tables} tz={tz} onClose={() => setEdit(null)} onSaved={async () => { setEdit(null); await load() }} />}
    </div>
  )
}

function ResForm({ r, tables, tz, onClose, onSaved }: { r: Partial<Res>; tables: DiningTable[]; tz: string; onClose: () => void; onSaved: () => void }) {
  const { t } = useT()
  const s = useSession()
  const p0 = partsIn(new Date(r.starts_at ?? Date.now()), tz)
  const [f, setF] = useState({ name: r.name ?? '', phone: r.phone ?? '', party: String(r.party ?? 2), date: p0.date, time: p0.hhmm, duration_min: String(r.duration_min ?? 90), table_id: r.table_id ?? '', note: r.note ?? '' })
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try {
      await rpc('save_reservation', { p: { id: r.id ?? null, branch_id: s.branch!.id, name: f.name, phone: f.phone, party: Number(f.party), starts_at: zoned(f.date, f.time, tz).toISOString(),
        duration_min: Number(f.duration_min), table_id: f.table_id || null, note: f.note } })
      onSaved()
    } catch (x) { const p = parseError(x); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) }
  }
  const fits = tables.filter((x) => x.seats >= Number(f.party || 1))
  return (
    <Modal title={r.id ? t('Edit reservation') : t('New reservation')} onClose={onClose}>
      <form className="grid2" onSubmit={save}>
        <label className="field"><span>{t('Name')}</span><input id="rs-name" required value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>{t('Mobile')}</span><input id="rs-phone" inputMode="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></label>
        <label className="field"><span>{t('Guests')}</span><input id="rs-party" type="number" min={1} value={f.party} onChange={(e) => setF({ ...f, party: e.target.value })} /></label>
        <label className="field"><span>{t('Table')}</span><select id="rs-table" value={f.table_id} onChange={(e) => setF({ ...f, table_id: e.target.value })}>
          <option value="">{t('Any table')}</option>{fits.map((x) => <option key={x.id} value={x.id}>{x.name} · {t('{n} seats', { n: x.seats })}</option>)}</select></label>
        <label className="field"><span>{t('Date')}</span><input id="rs-date" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
        <label className="field"><span>{t('Time')}</span><input id="rs-time" type="time" step={900} value={f.time} onChange={(e) => setF({ ...f, time: e.target.value })} /></label>
        <label className="field"><span>{t('Duration (minutes)')}</span><input id="rs-dur" type="number" min={15} step={15} value={f.duration_min} onChange={(e) => setF({ ...f, duration_min: e.target.value })} /></label>
        <label className="field"><span>{t('Note')}</span><input id="rs-note" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} placeholder={t('e.g. birthday, high chair')} /></label>
        {err && <p className="error span2">{err}</p>}
        <div className="row end span2"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

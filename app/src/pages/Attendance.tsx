import { Clock, Download } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { useT } from '../lib/i18n'
import { downloadCsv } from '../lib/reports'
import { useSession } from '../lib/session'
import { parseError, rpc, supabase } from '../lib/supabase'

interface Row { id: string; user_id: string; display_name: string; day: string; clock_in: string; clock_out: string | null; hours: number; in_distance: number | null }

/** Clock in and out from the phone at the branch (location checked against the branch circle); timesheet for managers. */
export default function Attendance() {
  const { t } = useT()
  const s = useSession()
  const me = s.session?.user.id
  const manager = s.can('staff.manage') || s.can('reports.all')
  const [rows, setRows] = useState<Row[]>([])
  const [from, setFrom] = useState(() => { const d = new Date(); d.setDate(d.getDate() - 7); return d.toISOString().slice(0, 10) })
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const load = useCallback(async () => {
    let q = supabase.from('v_attendance').select('*').gte('day', from).order('clock_in', { ascending: false }).limit(500)
    if (!manager) q = q.eq('user_id', me!)
    else if (s.branch) q = q.eq('branch_id', s.branch.id)
    const { data } = await q
    setRows((data ?? []) as Row[])
  }, [from, manager, me, s.branch])
  useEffect(() => { void load() }, [load])
  const openRow = rows.find((r) => r.user_id === me && !r.clock_out)
  async function clock() {
    setBusy(true); setMsg(null)
    const pos = await new Promise<GeolocationPosition | null>((res) => {
      if (!navigator.geolocation) return res(null)
      navigator.geolocation.getCurrentPosition(res, () => res(null), { enableHighAccuracy: true, timeout: 15000 })
    })
    try {
      const r = await rpc<{ action: string; hours?: number }>('clock', { p_branch: s.branch!.id, p_lat: pos?.coords.latitude ?? null, p_lng: pos?.coords.longitude ?? null, p_accuracy: pos?.coords.accuracy ?? null })
      setMsg({ ok: true, text: r.action === 'in' ? t('Clocked in. Have a good shift.') : t('Clocked out after {h} hours.', { h: r.hours ?? 0 }) })
      await load()
    } catch (e) { const p = parseError(e); setMsg({ ok: false, text: p.kind === 'message' ? t(p.message) : t('Not allowed') }) } finally { setBusy(false) }
  }
  const totals = new Map<string, { name: string; hours: number; days: Set<string> }>()
  for (const r of rows) { const x = totals.get(r.user_id) ?? { name: r.display_name, hours: 0, days: new Set<string>() }; x.hours += Number(r.hours); x.days.add(r.day); totals.set(r.user_id, x) }
  return (
    <div className="page">
      <div className="card clock-card">
        <button className={`clock-btn ${openRow ? 'out' : 'in'}`} disabled={busy} onClick={() => void clock()}>
          <Clock size={28} aria-hidden="true" /><b>{busy ? t('Checking your location…') : openRow ? t('Clock out') : t('Clock in')}</b>
          {openRow && <span>{t('Since {time}', { time: new Date(openRow.clock_in).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) })}</span>}
        </button>
        <p className="muted small">{t('Your phone’s location is checked against the branch when you clock in or out. Nothing is tracked in between.')}</p>
        {msg && <p className={msg.ok ? 'success' : 'error'} role="status">{msg.text}</p>}
      </div>
      <div className="row between wrap"><label className="field"><span>{t('From')}</span><input id="att-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <button onClick={() => downloadCsv(`attendance-${from}.csv`, rows.map((r) => ({ staff: r.display_name, day: r.day, in: r.clock_in, out: r.clock_out ?? '', hours: r.hours })))}><Download size={16} />{t('Export CSV')}</button></div>
      {manager && totals.size > 0 && (
        <div className="kpi-row">{[...totals.values()].map((x) => <div key={x.name} className="kpi2"><span className="kpi2-label">{x.name}</span><b className="kpi2-value">{x.hours.toFixed(1)} {t('h')}</b><span className="kpi2-sub">{t('{n} days', { n: x.days.size })}</span></div>)}</div>)}
      <div className="table-wrap"><table className="list">
        <thead><tr><th>{t('Staff')}</th><th>{t('Day')}</th><th>{t('In')}</th><th>{t('Out')}</th><th className="num">{t('Hours')}</th><th className="num">{t('Distance (m)')}</th></tr></thead>
        <tbody>{rows.map((r) => (
          <tr key={r.id}><td>{r.display_name}</td><td>{r.day}</td><td>{new Date(r.clock_in).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</td>
            <td>{r.clock_out ? new Date(r.clock_out).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : <span className="pill">{t('On shift')}</span>}</td>
            <td className="num">{Number(r.hours).toFixed(2)}</td><td className="num">{r.in_distance ?? '—'}</td></tr>))}</tbody>
      </table></div>
    </div>
  )
}

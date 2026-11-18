import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Empty, useApproval } from '../components/ui'
import { hubSend, useHub } from '../lib/hub'
import { useT } from '../lib/i18n'
import { useSession } from '../lib/session'
import { rpc, supabase } from '../lib/supabase'
import type { KitchenTicket, Station } from '../lib/types'

const NEXT: Record<string, { to: KitchenTicket['status']; label: string }> = {
  new: { to: 'preparing', label: 'Start' },
  preparing: { to: 'ready', label: 'Ready' },
  ready: { to: 'served', label: 'Served' },
}
const TYPE_LABEL: Record<string, string> = { dine_in: 'Dine-in', takeaway: 'Takeaway', delivery: 'Delivery', pickup: 'Pickup' }
const ls = { get: (k: string) => { try { return localStorage.getItem(k) } catch { return null } }, set: (k: string, v: string) => { try { localStorage.setItem(k, v) } catch { /* ignore */ } } }

/**
 * Kitchen display: New → Preparing → Ready → Served, per station or all stations.
 * Updates arrive through Supabase Realtime, with a 10-second refresh as a fallback.
 */
export default function Kds() {
  const { t, lang } = useT()
  const s = useSession()
  const branch = s.branch!
  const canBump = s.can('kds.bump')
  const [stations, setStations] = useState<Station[]>([])
  const [station, setStation] = useState<string>(() => ls.get('zt.kds.station') ?? '')
  const [tickets, setTickets] = useState<KitchenTicket[]>([])
  const [now, setNow] = useState(Date.now())
  const [sound, setSound] = useState(false)
  const [autoPrint, setAutoPrint] = useState(() => ls.get('zt.kds.autoprint') === '1')
  const [printing, setPrinting] = useState<KitchenTicket | null>(null)
  const seen = useRef<Set<string> | null>(null)
  const queue = useRef<KitchenTicket[]>([])
  const audio = useRef<AudioContext | null>(null)
  const approval = useApproval()
  const hub = useHub()
  const hubMode = hub.status === 'connected' || (hub.status === 'connecting' && Object.keys(hub.tickets).length > 0)

  useEffect(() => { void supabase.from('kitchen_stations').select('*').eq('branch_id', branch.id).eq('is_active', true).order('sort').then(({ data, error }) => { if (!error) setStations((data ?? []) as Station[]) }) }, [branch.id])
  useEffect(() => { if (!stations.length && hub.stations?.length) setStations(hub.stations) }, [hub.stations, stations.length])

  // hub mode: tickets come from the branch hub over the shop network (works with no internet)
  useEffect(() => {
    if (!hubMode) return
    const list = Object.values(hub.tickets)
      .filter((x) => ['new', 'preparing', 'ready'].includes(x.status) && (!station || x.station_id === station))
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
      .map((x) => ({ ...x, kitchen_ticket_items: x.items }) as unknown as KitchenTicket)
    if (seen.current) {
      const fresh = list.filter((x) => x.status === 'new' && !seen.current!.has(x.id))
      if (fresh.length && sound && audio.current) beep(audio.current)
      if (fresh.length && autoPrint && !stations.some((st) => st.id === fresh[0].station_id && st.printer_ip)) queue.current.push(...fresh)
    }
    seen.current = new Set(list.map((x) => x.id))
    setTickets(list)
  }, [hubMode, hub.tickets, station, sound, autoPrint, stations])
  useEffect(() => ls.set('zt.kds.station', station), [station])
  useEffect(() => ls.set('zt.kds.autoprint', autoPrint ? '1' : '0'), [autoPrint])

  const load = useCallback(async () => {
    if (hubMode) return
    const since = new Date(Date.now() - 24 * 3600_000).toISOString()
    let q = supabase.from('kitchen_tickets').select('*, kitchen_ticket_items(*)').eq('branch_id', branch.id)
      .in('status', ['new', 'preparing', 'ready']).gte('created_at', since).order('created_at')
    if (station) q = q.eq('station_id', station)
    const { data } = await q
    const list = (data ?? []) as KitchenTicket[]
    // new-ticket alerts: sound and optional auto-print
    if (seen.current) {
      const fresh = list.filter((x) => x.status === 'new' && !seen.current!.has(x.id))
      if (fresh.length && sound && audio.current) beep(audio.current)
      if (fresh.length && autoPrint) queue.current.push(...fresh)
    }
    seen.current = new Set(list.map((x) => x.id))
    setTickets(list)
  }, [branch.id, station, sound, autoPrint, hubMode])

  useEffect(() => {
    void load()
    const poll = window.setInterval(() => void load(), 10_000)
    const tick = window.setInterval(() => setNow(Date.now()), 1_000)
    const ch = supabase.channel(`kds-${branch.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'kitchen_tickets', filter: `branch_id=eq.${branch.id}` }, () => void load())
      .subscribe()
    return () => { clearInterval(poll); clearInterval(tick); void supabase.removeChannel(ch) }
  }, [load, branch.id])

  // print queued tickets one at a time
  useEffect(() => { if (!printing && queue.current.length) setPrinting(queue.current.shift()!) }, [printing, tickets])

  const alertFor = useMemo(() => {
    const m = new Map(stations.map((x) => [x.id, x.alert_minutes])); return (id: string) => m.get(id) ?? 10
  }, [stations])

  async function move(k: KitchenTicket, to: KitchenTicket['status']) {
    if (hubMode) { hubSend({ type: 'ticket.status', id: k.id, status: to }); return }
    setTickets((cur) => cur.map((x) => (x.id === k.id ? { ...x, status: to } : x)).filter((x) => x.status !== 'served'))
    await approval.run(() => rpc('kds_set_status', { p_ticket: k.id, p_status: to }))
    void load()
  }
  async function toggleItem(itemId: string) {
    if (hubMode) { const tk = tickets.find((x) => x.kitchen_ticket_items.some((i) => i.id === itemId)); if (tk) hubSend({ type: 'item.toggle', id: tk.id, item: itemId }); return }
    setTickets((cur) => cur.map((x) => ({ ...x, kitchen_ticket_items: x.kitchen_ticket_items.map((i) => (i.id === itemId ? { ...i, done: !i.done } : i)) })))
    await approval.run(() => rpc('kds_toggle_item', { p_item: itemId }))
  }

  const cols: { status: KitchenTicket['status']; label: string }[] = [
    { status: 'new', label: 'New' }, { status: 'preparing', label: 'Preparing' }, { status: 'ready', label: 'Ready' },
  ]
  const stationName = (id: string) => stations.find((x) => x.id === id)?.name ?? ''
  const printable = stations.some((x) => x.mode !== 'kds' && (!station || x.id === station))

  return (
    <div className="kds">
      <header className="kds-head">
        <div className="row"><h1>{t('Kitchen')}</h1>
          {hub.status !== 'off' && <span className={`hub-badge ${hub.status}`}>{hub.status === 'connected' ? `${t('Local hub')} · ${hub.cloudOnline ? t('cloud synced') : t('internet down – working locally')}${hub.pending ? ` · ${t('{n} waiting to sync', { n: hub.pending })}` : ''}` : t('Hub reconnecting…')}</span>}</div>
        <div className="seg">
          <button className={!station ? 'on' : ''} onClick={() => setStation('')}>{t('All stations')}</button>
          {stations.map((x) => <button key={x.id} className={station === x.id ? 'on' : ''} onClick={() => setStation(x.id)}>{lang === 'ar' && x.name_ar ? x.name_ar : x.name}</button>)}
        </div>
        <div className="row">
          <button className={sound ? 'on-amber' : ''} onClick={() => { audio.current ??= new AudioContext(); void audio.current.resume(); setSound(!sound) }}>{sound ? t('Sound on') : t('Sound off')}</button>
          {printable && <label className="check"><input id="kds-autoprint" type="checkbox" checked={autoPrint} onChange={(e) => setAutoPrint(e.target.checked)} />{t('Print new tickets')}</label>}
          <button onClick={() => void document.documentElement.requestFullscreen?.().catch(() => undefined)}>{t('Full screen')}</button>
        </div>
      </header>
      {approval.error && <p className="error">{approval.error}</p>}
      <div className="kds-cols">
        {cols.map((c) => {
          const list = tickets.filter((x) => x.status === c.status)
          return (
            <section key={c.status} className={`kds-col ${c.status}`}>
              <h2>{t(c.label)} <span className="count">{list.length}</span></h2>
              {list.length === 0 ? <Empty title={t('Nothing here')} /> : list.map((k) => {
                const limit = alertFor(k.station_id)
                const created = new Date(k.created_at).getTime()
                const end = k.ready_at ? new Date(k.ready_at).getTime() : now
                const totalS = Math.max(0, Math.floor((end - created) / 1000))
                const stageS = Math.max(0, Math.floor((now - new Date(k.status === 'preparing' && k.started_at ? k.started_at : k.created_at).getTime()) / 1000))
                const mins = totalS / 60
                const tone = mins >= limit ? 'late' : mins >= limit * 0.6 ? 'warm' : 'ok'
                const pct = Math.min(100, (mins / limit) * 100)
                return (
                  <article key={k.id} className={`ticket ${tone}`}>
                    <header>
                      <b className="t-ref">{k.order_ref.startsWith('OFF-') ? <span className="t-off" title={t('Saved offline, number assigned when synced')}>{k.order_ref.slice(0, 8)}</span> : `#${parseInt(k.order_ref.split('-').pop() ?? '0', 10)}`}</b>
                      <span className="pill">{t(TYPE_LABEL[k.order_type])}{k.table_no ? ` · ${t('Table')} ${k.table_no}` : ''}</span>
                      <span className={`t-time ${tone}`} aria-label={t('Order time')}>{clock(totalS)}</span>
                    </header>
                    <div className="t-stage">
                      <span>{k.status === 'new' ? t('Waiting') : k.status === 'preparing' ? `${t('Preparing')} ${clock(stageS)}` : `${t('Ready in')} ${clock(totalS)}`}</span>
                      <span className="muted">{t('Target')} {limit}′</span>
                    </div>
                    <div className={`t-bar ${tone}`} role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(pct)}><i style={{ width: `${pct}%` }} /></div>
                    {!station && <div className="muted small">{stationName(k.station_id)}</div>}
                    {k.customer_name && <div className="small">{k.customer_name}</div>}
                    {k.note && <div className="t-note">{k.note}</div>}
                    <ul>{k.kitchen_ticket_items.map((i) => (
                      <li key={i.id} className={i.done ? 'done' : ''}>
                        <button disabled={!canBump} onClick={() => void toggleItem(i.id)}>
                          <b>{Number(i.qty)}×</b> {lang === 'ar' && i.name_ar ? i.name_ar : i.name}
                          {i.note && <em>{i.note}</em>}
                        </button>
                      </li>))}</ul>
                    {canBump && (
                      <footer>
                        {k.status === 'ready' && <button onClick={() => void move(k, 'preparing')}>{t('Recall')}</button>}
                        <button onClick={() => (hubMode && stations.some((st) => st.id === k.station_id && st.printer_ip) ? hubSend({ type: 'ticket.print', id: k.id }) : setPrinting(k))}>{t('Print')}</button>
                        <button className="primary" onClick={() => void move(k, NEXT[k.status].to)}>{t(NEXT[k.status].label)}</button>
                      </footer>)}
                  </article>
                )
              })}
            </section>
          )
        })}
      </div>
      {approval.dialog}
      {printing && <PrintChit ticket={printing} station={stationName(printing.station_id)} onDone={() => setPrinting(null)} />}
    </div>
  )
}

export const clock = (sec: number) => `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`

function beep(ctx: AudioContext) {
  const o = ctx.createOscillator(); const g = ctx.createGain()
  o.frequency.value = 880; o.connect(g); g.connect(ctx.destination)
  g.gain.setValueAtTime(0.25, ctx.currentTime); g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.6)
  o.start(); o.stop(ctx.currentTime + 0.6)
}

/** Kitchen chit for 80 mm printers. In Chrome started with --kiosk-printing it prints silently to the default printer. */
function PrintChit({ ticket, station, onDone }: { ticket: KitchenTicket; station: string; onDone: () => void }) {
  useEffect(() => {
    document.documentElement.dataset.paper = ls.get('zt.paper') || '80'
    const after = () => onDone()
    window.addEventListener('afterprint', after)
    const id = window.setTimeout(() => window.print(), 200)
    return () => { clearTimeout(id); window.removeEventListener('afterprint', after) }
  }, [onDone])
  return createPortal(
    <div id="print-root">
      <div className="receipt chit">
        <div className="r-center"><span className="r-big">{station}</span><span className="chit-ref">{ticket.order_ref.startsWith('OFF-') ? ticket.order_ref.slice(0, 8) : `#${parseInt(ticket.order_ref.split('-').pop() ?? '0', 10)}`}</span>
          <span className="r-big">{TYPE_LABEL[ticket.order_type]}{ticket.table_no ? ` · T${ticket.table_no}` : ''}</span>
          <span>{new Date(ticket.created_at).toLocaleTimeString('en-GB')}</span></div>
        <hr />
        {ticket.kitchen_ticket_items.map((i) => (
          <div key={i.id} className="chit-line"><b>{Number(i.qty)} × {i.name}</b>{i.name_ar && <div>{i.name_ar}</div>}{i.note && <div className="chit-note">» {i.note}</div>}</div>))}
        {ticket.note && <><hr /><div className="chit-note">{ticket.note}</div></>}
      </div>
    </div>, document.body)
}

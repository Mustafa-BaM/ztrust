import { CalendarPlus, ChevronLeft, ChevronRight, ShoppingBag } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { CustomerPicker } from '../components/CustomerPicker'
import { Empty, Modal } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { fmt } from '../lib/money'
import { useSession } from '../lib/session'
import { parseError, rpc, supabase } from '../lib/supabase'
import type { CartLine, Customer, Item } from '../lib/types'
import type { CheckoutContext } from './Pos'
import { partsIn, timeIn, todayIn, zoned } from '../lib/tz'

interface Staff { user_id: string; display_name: string; color: string | null }
interface Appt {
  id: string; customer_id: string | null; staff_id: string; starts_at: string; ends_at: string; status: string; source: string; note: string | null
  appointment_services: { item_id: string; name: string; duration_min: number; price: number }[]; customers: Customer | null
}
const START = 8, END = 23, SLOT = 15, PX = 14   // 08:00–23:00, 15-minute rows, 14 px per row
const STATUS: Record<string, string> = { booked: 'Booked', confirmed: 'Confirmed', arrived: 'Arrived', in_service: 'In service', completed: 'Paid', no_show: 'No-show', cancelled: 'Cancelled' }

/** Day view by staff member: book, move through the visit, and check out at the till. */
export default function Calendar() {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const nav = useNavigate()
  const tn = s.tenant!
  const tz = s.branch?.timezone ?? Intl.DateTimeFormat().resolvedOptions().timeZone
  const [day, setDay] = useState(() => todayIn(tz))
  const [staff, setStaff] = useState<Staff[]>([])
  const [services, setServices] = useState<Item[]>([])
  const [appts, setAppts] = useState<Appt[]>([])
  const [customers, setCustomers] = useState<Customer[]>([])
  const [create, setCreate] = useState<{ staff_id: string; date: string; time: string } | null>(null)
  const [open, setOpen] = useState<Appt | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [params, setParams] = useSearchParams()

  const load = useCallback(async () => {
    if (!s.branch) return
    const from = zoned(day, '00:00', tz), to = new Date(from.getTime() + 86_400_000)
    const [st, sv, ap, cu] = await Promise.all([
      supabase.from('memberships').select('user_id, display_name, color').eq('tenant_id', tn.id).eq('is_active', true).eq('bookable', true).order('display_name'),
      supabase.from('items').select('*').eq('tenant_id', tn.id).eq('item_type', 'service').eq('is_active', true).order('name'),
      supabase.from('appointments').select('*, appointment_services(item_id, name, duration_min, price), customers(*)').eq('branch_id', s.branch.id)
        .gte('starts_at', from.toISOString()).lt('starts_at', to.toISOString()).order('starts_at'),
      supabase.from('customers').select('*').eq('tenant_id', tn.id).order('name').limit(2000),
    ])
    setStaff((st.data ?? []) as Staff[]); setServices((sv.data ?? []) as Item[]); setAppts((ap.data ?? []) as Appt[]); setCustomers((cu.data ?? []) as Customer[])
  }, [day, s.branch, tn.id, tz])
  useEffect(() => { void load(); const id = window.setInterval(() => void load(), 30_000); return () => clearInterval(id) }, [load])
  useEffect(() => { if (params.get('new') && staff.length) { setCreate({ staff_id: staff[0].user_id, date: day, time: `${String(Math.min(Math.max(partsIn(new Date(), tz).h + 1, START), END - 1)).padStart(2, '0')}:00` }); setParams({}, { replace: true }) } }, [params, setParams, staff, day, tz])

  const shift = (n: number) => { const d = new Date(`${day}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); setDay(d.toISOString().slice(0, 10)) }
  const top = (iso: string) => { const p = partsIn(new Date(iso), tz); return ((p.h - START) * 60 + p.m) / SLOT * PX }
  const hm = (iso: string) => timeIn(iso, tz)
  const height = (a: Appt) => Math.max(((new Date(a.ends_at).getTime() - new Date(a.starts_at).getTime()) / 60000) / SLOT * PX, PX)
  const live = appts.filter((a) => a.status !== 'cancelled')
  const kpi = useMemo(() => ({
    booked: live.length, done: live.filter((a) => a.status === 'completed').length, noShow: live.filter((a) => a.status === 'no_show').length,
    value: live.filter((a) => a.status !== 'no_show').reduce((x, a) => x + a.appointment_services.reduce((y, v) => y + v.price, 0), 0),
  }), [live])

  async function status(a: Appt, st: string) {
    setMsg(null)
    try { await rpc('set_appointment_status', { p_id: a.id, p_status: st }); setOpen(null); await load() } catch (e) { const p = parseError(e); setMsg(p.kind === 'message' ? t(p.message) : t('Not allowed')) }
  }
  function checkout(a: Appt) {
    const lines: CartLine[] = a.appointment_services.map((v, i) => {
      const it = services.find((x) => x.id === v.item_id)
      return { key: `${a.id}-${i}`, item_id: v.item_id, name: v.name, name_ar: it?.name_ar ?? null, qty: 1, unit_price: it?.price ?? v.price, list_price: it?.price ?? v.price,
               discount: 0, tax_rate: it?.tax_rate ?? tn.vat_rate, staff_id: a.staff_id }
    })
    const ctx: CheckoutContext = { lines, customer: a.customers, appointment_id: a.id, label: `${t('Appointment')} · ${hm(a.starts_at)}` }
    nav('/pos', { state: { checkout: ctx } })
  }
  const hours = Array.from({ length: END - START }, (_, i) => START + i)
  const nowTop = day === todayIn(tz) ? top(new Date().toISOString()) : null

  return (
    <div className="page">
      <div className="row between wrap">
        <div className="row"><button className="icon" aria-label={t('Previous day')} onClick={() => shift(-1)}><ChevronLeft size={18} className="flip-rtl" /></button>
          <input id="cal-day" type="date" value={day} onChange={(e) => setDay(e.target.value)} />
          <button className="icon" aria-label={t('Next day')} onClick={() => shift(1)}><ChevronRight size={18} className="flip-rtl" /></button>
          <button className="ghost" onClick={() => setDay(todayIn(tz))}>{t('Today')}</button></div>
        <button className="primary" disabled={!staff.length} onClick={() => setCreate({ staff_id: staff[0]?.user_id, date: day, time: `${String(Math.min(Math.max(partsIn(new Date(), tz).h + 1, START), END - 1)).padStart(2, '0')}:00` })}><CalendarPlus size={16} />{t('New appointment')}</button>
      </div>
      <div className="kpi-row">
        <div className="kpi2"><span className="kpi2-label">{t('Appointments')}</span><b className="kpi2-value">{kpi.booked}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('Paid')}</span><b className="kpi2-value">{kpi.done}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('No-shows')}</span><b className={`kpi2-value ${kpi.noShow ? 'bad' : ''}`}>{kpi.noShow}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('Booked value')}</span><b className="kpi2-value">{fmt(kpi.value, tn, lang)}</b></div>
      </div>
      {msg && <p className="error">{msg}</p>}
      {staff.length === 0 ? <Empty title={t('Nobody takes bookings yet')} hint={t('In Settings → Staff, tick “Takes bookings” and set the working hours.')} /> : (
        <div className="cal-wrap">
          <div className="cal" style={{ gridTemplateColumns: `56px repeat(${staff.length}, minmax(150px, 1fr))` }}>
            <div className="cal-corner" />
            {staff.map((m) => <div key={m.user_id} className="cal-head" style={{ borderTopColor: m.color ?? 'var(--accent)' }}>{m.display_name}</div>)}
            <div className="cal-times">{hours.map((h) => <div key={h} style={{ height: PX * 4 }}>{String(h).padStart(2, '0')}:00</div>)}</div>
            {staff.map((m) => (
              <div key={m.user_id} className="cal-col" style={{ height: (END - START) * 4 * PX }}
                onClick={(e) => {
                  const y = e.clientY - (e.currentTarget as HTMLElement).getBoundingClientRect().top
                  const mins = Math.floor(y / PX) * SLOT
                  setCreate({ staff_id: m.user_id, date: day, time: `${String(START + Math.floor(mins / 60)).padStart(2, '0')}:${String(mins % 60).padStart(2, '0')}` })
                }}>
                {nowTop != null && nowTop > 0 && <i className="cal-now" style={{ top: nowTop }} />}
                {appts.filter((a) => a.staff_id === m.user_id && a.status !== 'cancelled').map((a) => (
                  <button key={a.id} className={`appt st-${a.status}`} style={{ top: top(a.starts_at), height: height(a) }} onClick={(e) => { e.stopPropagation(); setOpen(a) }}>
                    <b>{hm(a.starts_at)} {a.customers?.name ?? t('Walk-in')}</b>
                    <span>{a.appointment_services.map((v) => nameOf(services.find((x) => x.id === v.item_id) ?? { name: v.name })).join(' + ')}</span>
                    {a.source === 'online' && <em>{t('Online')}</em>}
                  </button>))}
              </div>))}
          </div>
        </div>)}
      {create && <NewAppointment init={create} staff={staff} services={services} customers={customers} onClose={() => setCreate(null)} onSaved={async () => { setCreate(null); await load() }}
        onCustomerCreated={(c) => setCustomers([...customers, c])} />}
      {open && (
        <Modal title={`${open.customers?.name ?? t('Walk-in')} · ${hm(open.starts_at)}`} onClose={() => setOpen(null)}>
          <div className="stack">
            <p><span className={`pill st-${open.status}`}>{t(STATUS[open.status])}</span> {open.source === 'online' && <span className="pill">{t('Booked online')}</span>}</p>
            <ul className="mod-list">{open.appointment_services.map((v, i) => <li key={i}><span>{v.name} · {v.duration_min} {t('min')}</span><b>{fmt(v.price, tn, lang)}</b></li>)}</ul>
            {open.customers?.phone && <p className="muted">{open.customers.phone}</p>}
            {open.note && <p className="muted">{open.note}</p>}
            {open.status !== 'completed' && (
              <div className="row wrap">
                {open.status === 'booked' && <button onClick={() => void status(open, 'confirmed')}>{t('Confirm')}</button>}
                {['booked', 'confirmed'].includes(open.status) && <button onClick={() => void status(open, 'arrived')}>{t('Arrived')}</button>}
                {['arrived', 'confirmed', 'booked'].includes(open.status) && <button onClick={() => void status(open, 'in_service')}>{t('Start')}</button>}
                {['booked', 'confirmed'].includes(open.status) && <button className="ghost" onClick={() => void status(open, 'no_show')}>{t('No-show')}</button>}
                <button className="ghost danger" onClick={() => void status(open, 'cancelled')}>{t('Cancel appointment')}</button>
                {s.can('sale.create') && <button className="primary" onClick={() => checkout(open)}><ShoppingBag size={16} />{t('Checkout')}</button>}
              </div>)}
          </div>
        </Modal>)}
    </div>
  )
}

function NewAppointment({ init, staff, services, customers, onClose, onSaved, onCustomerCreated }: {
  init: { staff_id: string; date: string; time: string }; staff: Staff[]; services: Item[]; customers: Customer[]
  onClose: () => void; onSaved: () => void; onCustomerCreated: (c: Customer) => void
}) {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const [f, setF] = useState({ staff_id: init.staff_id, date: init.date, time: init.time, service_ids: [] as string[], note: '' })
  const [customer, setCustomer] = useState<Customer | null>(null)
  const [picking, setPicking] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const mins = services.filter((x) => f.service_ids.includes(x.id)).reduce((a, x) => a + (x.duration_min ?? 30), 0)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try {
      await rpc('save_appointment', { p: { branch_id: s.branch!.id, staff_id: f.staff_id, customer_id: customer?.id ?? null, starts_at: zoned(f.date, f.time, s.branch?.timezone ?? Intl.DateTimeFormat().resolvedOptions().timeZone).toISOString(), service_ids: f.service_ids, note: f.note } })
      onSaved()
    } catch (x) { const p = parseError(x); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) }
  }
  return (
    <Modal title={t('New appointment')} onClose={onClose} wide>
      <form className="grid2" onSubmit={save}>
        <div className="span2 row"><button type="button" className="ghost" onClick={() => setPicking(true)}>{customer ? customer.name : t('Choose customer')}</button>{customer?.phone && <span className="muted">{customer.phone}</span>}</div>
        <label className="field"><span>{t('Staff')}</span><select id="appt-staff" value={f.staff_id} onChange={(e) => setF({ ...f, staff_id: e.target.value })}>{staff.map((m) => <option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label>
        <div className="row"><label className="field"><span>{t('Date')}</span><input id="appt-date" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label className="field"><span>{t('Time')}</span><input id="appt-time" type="time" step={300} value={f.time} onChange={(e) => setF({ ...f, time: e.target.value })} /></label></div>
        <fieldset className="span2 events-pick"><legend>{t('Services')}{mins ? ` · ${mins} ${t('min')}` : ''}</legend>
          {services.map((x) => <label key={x.id} className="check"><input type="checkbox" checked={f.service_ids.includes(x.id)} onChange={(e) => setF({ ...f, service_ids: e.target.checked ? [...f.service_ids, x.id] : f.service_ids.filter((v) => v !== x.id) })} />
            {nameOf(x)} <span className="muted small">{x.duration_min} {t('min')} · {fmt(x.price, s.tenant!, lang)}</span></label>)}
          {services.length === 0 && <span className="muted">{t('Add services in Products first.')}</span>}
        </fieldset>
        <label className="field span2"><span>{t('Note')}</span><input id="appt-note" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></label>
        {err && <p className="error span2">{err}</p>}
        <div className="row end span2"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!f.service_ids.length}>{t('Book')}</button></div>
      </form>
      {picking && <CustomerPicker tenantId={s.tenant!.id} customers={customers} online onClose={() => setPicking(false)} onPick={(c) => { setCustomer(c); setPicking(false) }} onCreated={onCustomerCreated} />}
    </Modal>
  )
}

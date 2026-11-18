import { useEffect, useMemo, useState } from 'react'
import { useParams } from 'react-router-dom'
import { Logo } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt } from '../lib/money'
import { parseError, rpc } from '../lib/supabase'
import { partsIn, todayIn } from '../lib/tz'

interface Info {
  business: string; business_ar: string | null; logo_url: string | null; brand_color: string | null; currency: string; decimals: number
  branches: { id: string; name: string; name_ar: string | null; address: string | null; timezone?: string }[]
  services: { id: string; name: string; name_ar: string | null; duration_min: number; price: number }[]
  staff: { id: string; name: string }[]
}

/** Public booking page: choose services, a day and a free time; no account needed. */
export default function Book() {
  const { slug = '' } = useParams()
  const { t, lang, setLang } = useT()
  const [info, setInfo] = useState<Info | null | undefined>(undefined)
  const [branch, setBranch] = useState('')
  const [picked, setPicked] = useState<string[]>([])
  const [staff, setStaff] = useState('')
  const [day, setDay] = useState('')
  const [slots, setSlots] = useState<{ staff_id: string; starts_at: string }[] | null>(null)
  const [slot, setSlot] = useState<{ staff_id: string; starts_at: string } | null>(null)
  const [who, setWho] = useState({ name: '', phone: '', note: '' })
  const [done, setDone] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const nm = (x: { name: string; name_ar?: string | null }) => (lang === 'ar' && x.name_ar ? x.name_ar : x.name)
  useEffect(() => { rpc<Info | null>('booking_info', { p_slug: slug }).then((i) => { setInfo(i); setBranch(i?.branches[0]?.id ?? ''); setDay(todayIn(i?.branches[0]?.timezone ?? 'Asia/Kuwait')) }).catch(() => setInfo(null)) }, [slug])
  const tz = info?.branches.find((b) => b.id === branch)?.timezone ?? 'Asia/Kuwait'
  const showTime = (iso: string, opts: Intl.DateTimeFormatOptions) => new Date(iso).toLocaleString(lang === 'ar' ? 'ar-u-nu-latn' : 'en-GB', { timeZone: tz, ...opts })
  useEffect(() => {
    setSlot(null); setSlots(null)
    if (!branch || !picked.length || !day) return
    rpc<{ staff_id: string; starts_at: string }[]>('booking_slots', { p_slug: slug, p_branch: branch, p_services: picked, p_day: day, p_staff: staff || null }).then(setSlots).catch(() => setSlots([]))
  }, [slug, branch, picked, day, staff])
  // one button per start time; the first free person takes it unless a person was chosen
  const times = useMemo(() => { const m = new Map<string, { staff_id: string; starts_at: string }>(); for (const x of slots ?? []) if (!m.has(x.starts_at)) m.set(x.starts_at, x); return [...m.values()] }, [slots])
  const money = (v: number) => (info ? fmt(v, { currency: info.currency, currency_decimals: info.decimals }, lang) : '')
  const chosen = info?.services.filter((x) => picked.includes(x.id)) ?? []
  async function book(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try {
      const r = await rpc<{ starts_at: string }>('book_online', { p_slug: slug, p: { branch_id: branch, service_ids: picked, staff_id: slot!.staff_id, starts_at: slot!.starts_at, ...who } })
      setDone(r.starts_at)
    } catch (x) { const p = parseError(x); setErr(p.kind === 'message' ? t(p.message) : '') }
  }
  // the next 14 days in the shop's calendar
  const days = Array.from({ length: 14 }, (_, i) => { const d = new Date(`${todayIn(tz)}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + i); return d })
  const ymd = (d: Date) => d.toISOString().slice(0, 10)
  return (
    <div className="auth book">
      <div className="auth-card wide" style={info?.brand_color ? { borderTopColor: info.brand_color } : undefined}>
        {info === undefined ? <p className="muted">{t('Loading…')}</p> : !info ? <p className="error">{t('This booking page is not available.')}</p> : done ? (
          <div className="stack center">
            {info.logo_url && <img className="paylink-logo" src={info.logo_url} alt="" />}
            <h1>{t('You are booked')}</h1>
            <p className="big-time">{showTime(done, { weekday: 'long', day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' })}</p>
            <p className="muted">{chosen.map(nm).join(' + ')}</p>
          </div>
        ) : (
          <form className="stack" onSubmit={book}>
            <div className="row">{info.logo_url && <img className="paylink-logo small" src={info.logo_url} alt="" />}<h1>{lang === 'ar' && info.business_ar ? info.business_ar : info.business}</h1></div>
            {info.branches.length > 1 && <label className="field"><span>{t('Branch')}</span><select id="bk-branch" value={branch} onChange={(e) => setBranch(e.target.value)}>{info.branches.map((b) => <option key={b.id} value={b.id}>{nm(b)}</option>)}</select></label>}
            <h3 className="sub-h">{t('1. Choose services')}</h3>
            <div className="svc-grid">{info.services.map((x) => (
              <button type="button" key={x.id} className={`choice ${picked.includes(x.id) ? 'on' : ''}`} aria-pressed={picked.includes(x.id)} onClick={() => setPicked(picked.includes(x.id) ? picked.filter((v) => v !== x.id) : [...picked, x.id])}>
                <b>{nm(x)}</b><span>{x.duration_min} {t('min')} · {money(x.price)}</span></button>))}</div>
            {picked.length > 0 && <>
              <h3 className="sub-h">{t('2. Choose a day and time')}</h3>
              {info.staff.length > 1 && <label className="field"><span>{t('With')}</span><select id="bk-staff" value={staff} onChange={(e) => setStaff(e.target.value)}><option value="">{t('Anyone available')}</option>{info.staff.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</select></label>}
              <div className="day-strip">{days.map((d) => (
                <button type="button" key={ymd(d)} className={day === ymd(d) ? 'on' : ''} onClick={() => setDay(ymd(d))}>
                  <small>{d.toLocaleDateString(lang === 'ar' ? 'ar' : 'en', { weekday: 'short', timeZone: 'UTC' })}</small><b>{d.getUTCDate()}</b></button>))}</div>
              <div className="chip-pick wrap">{slots === null ? <span className="muted">{t('Loading…')}</span> : times.length === 0 ? <span className="muted">{t('No free times this day. Try another day.')}</span> :
                times.map((x) => <button type="button" key={x.starts_at} className={slot?.starts_at === x.starts_at ? 'on' : ''} onClick={() => setSlot(x)}>{partsIn(new Date(x.starts_at), tz).hhmm}</button>)}</div>
            </>}
            {slot && <>
              <h3 className="sub-h">{t('3. Your details')}</h3>
              <div className="grid2">
                <label className="field"><span>{t('Name')}</span><input id="bk-name" required value={who.name} onChange={(e) => setWho({ ...who, name: e.target.value })} /></label>
                <label className="field"><span>{t('Mobile')}</span><input id="bk-phone" required inputMode="tel" value={who.phone} onChange={(e) => setWho({ ...who, phone: e.target.value })} /></label>
                <label className="field span2"><span>{t('Note (optional)')}</span><input id="bk-note" value={who.note} onChange={(e) => setWho({ ...who, note: e.target.value })} /></label>
              </div>
              {err && <p className="error">{err}</p>}
              <button className="primary big">{t('Book {time}', { time: showTime(slot.starts_at, { weekday: 'short', hour: '2-digit', minute: '2-digit' }) })} · {money(chosen.reduce((a, x) => a + x.price, 0))}</button>
            </>}
          </form>
        )}
        <div className="row between"><span className="row muted small"><Logo size={18} /> Z Trust</span>
          <button className="ghost small" onClick={() => setLang(lang === 'ar' ? 'en' : 'ar')}>{lang === 'ar' ? 'English' : 'العربية'}</button></div>
      </div>
    </div>
  )
}

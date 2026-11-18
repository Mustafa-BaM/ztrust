import { Bot, CalendarDays, Lock, MessageCircle, ScanLine, Ticket, UtensilsCrossed } from 'lucide-react'
import { useEffect, useState } from 'react'
import { useT } from '../../lib/i18n'
import { useSession } from '../../lib/session'
import { parseError, rpc, supabase } from '../../lib/supabase'
import type { BusinessProfile, FeatureModule } from '../../lib/types'

export const POS_MODE: Record<BusinessProfile['pos_mode'], { label: string; hint: string; icon: typeof ScanLine }> = {
  grid: { label: 'Menu grid', hint: 'Tiles with photos and add-ons', icon: UtensilsCrossed },
  scan: { label: 'Scan first', hint: 'Barcode scanner, fast list', icon: ScanLine },
  calendar: { label: 'Calendar', hint: 'Today’s appointments, then checkout', icon: CalendarDays },
  ticket: { label: 'Tickets', hint: 'Drop-off ticket, collect later', icon: Ticket },
}

/** Owner: business type and the modules switched on. Switching off hides a module and blocks its actions; data is kept. */
export default function Modules() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [profiles, setProfiles] = useState<BusinessProfile[]>([])
  const [mods, setMods] = useState<FeatureModule[]>([])
  const [busy, setBusy] = useState<string | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const nm = (x: { name_en: string; name_ar: string }) => (lang === 'ar' ? x.name_ar : x.name_en)

  useEffect(() => {
    void Promise.all([
      supabase.from('business_profiles').select('*').order('sort'),
      supabase.from('feature_modules').select('*').order('sort'),
    ]).then(([p, m]) => { setProfiles((p.data ?? []) as BusinessProfile[]); setMods((m.data ?? []) as FeatureModule[]) })
  }, [])

  const profile = profiles.find((p) => p.key === tn.business_profile)
  const on = (k: string) => Boolean(tn.features?.[k])

  async function toggle(m: FeatureModule, value: boolean) {
    setBusy(m.key); setMsg(null)
    try {
      await rpc('set_feature', { p_tenant: tn.id, p_key: m.key, p_on: value })
      await s.reload()
      setMsg({ ok: true, text: value ? t('{m} switched on', { m: nm(m) }) : t('{m} switched off. Its data is kept and returns when you switch it on again.', { m: nm(m) }) })
    } catch (e) { const x = parseError(e); setMsg({ ok: false, text: x.kind === 'message' ? t(x.message) : t('Not allowed') }) } finally { setBusy(null) }
  }

  async function changeProfile(key: string) {
    if (!key || key === tn.business_profile) return
    setBusy('profile'); setMsg(null)
    try {
      await rpc('set_business_profile', { p_tenant: tn.id, p_profile: key, p_apply_defaults: true })
      await s.reload()
      setMsg({ ok: true, text: t('Business type changed. Its modules were switched on; nothing was switched off.') })
    } catch (e) { const x = parseError(e); setMsg({ ok: false, text: x.kind === 'message' ? t(x.message) : t('Not allowed') }) } finally { setBusy(null) }
  }

  // only what this kind of business can use: its own modules plus the ones every business can use
  const allowed = mods.filter((m) => m.universal || profile?.modules[m.key] || on(m.key))
  const built = allowed.filter((m) => m.built)
  const planned = allowed.filter((m) => !m.built)
  const forProfile = planned.filter((m) => profile?.modules[m.key])
  const others = planned.filter((m) => !profile?.modules[m.key])
  const Mode = profile ? POS_MODE[profile.pos_mode] : null

  return (
    <section className="stack">
      <div className="card profile-card">
        <div className="row between wrap">
          <div>
            <span className="eyebrow">{t('Business type')}</span>
            <h2>{profile ? nm(profile) : tn.business_profile}</h2>
          </div>
          <label className="field"><span>{t('Change business type')}</span>
            <select id="profile-select" value={tn.business_profile} disabled={busy === 'profile'} onChange={(e) => void changeProfile(e.target.value)}>
              {profiles.filter((p) => p.launch || p.key === tn.business_profile).map((p) => <option key={p.key} value={p.key}>{nm(p)}</option>)}
            </select></label>
        </div>
        {Mode && <p className="muted small mode-line"><Mode.icon size={16} aria-hidden="true" /> {t('Point of sale')}: <b>{t(Mode.label)}</b> · {t(Mode.hint)}</p>}
        <p className="muted small">{t('The business type decides which modules start switched on. You can switch any available module on or off below.')}</p>
      </div>

      {msg && <p className={msg.ok ? 'success' : 'error'} role="status">{msg.text}</p>}

      <div className="card">
        <h2>{t('Available modules')}</h2>
        <ul className="mod-list">
          {built.map((m) => {
            const rec = profile?.modules[m.key]
            return (
              <li key={m.key}>
                <div><b>{nm(m)}</b>{rec === 2 && <span className="pill">{t('Recommended for you')}</span>}{rec === 1 && <span className="pill muted-pill">{t('Suggested')}</span>}
                  <p className="muted small">{t(MOD_HINT[m.key] ?? '')}</p></div>
                <button role="switch" aria-checked={on(m.key)} aria-label={nm(m)} id={`mod-${m.key}`} className={`switch ${on(m.key) ? 'on' : ''}`}
                  disabled={busy !== null} onClick={() => void toggle(m, !on(m.key))}><i /></button>
              </li>)
          })}
        </ul>
      </div>

      {forProfile.length > 0 && (
        <div className="card">
          <h2>{t('Coming for your business type')}</h2>
          <p className="muted small">{t('These are being built and will appear here when ready. Nothing to set up now.')}</p>
          <ul className="chip-list">{forProfile.map((m) => <li key={m.key}><Lock size={13} aria-hidden="true" />{nm(m)}</li>)}</ul>
        </div>
      )}

      <div className="card">
        <h2>{t('Paid add-ons')}</h2>
        <ul className="mod-list">
          <li><div><b><MessageCircle size={16} aria-hidden="true" /> WhatsApp</b><p className="muted small">{t('Receipts, “order ready”, appointment reminders and payment links on WhatsApp, from your own business number. Activated on request; Meta charges its message fees directly.')}</p></div>
            <span className={`pill ${tn.addons?.whatsapp ? '' : 'muted-pill'}`}>{tn.addons?.whatsapp ? t('Active') : t('On request')}</span></li>
          <li><div><b><Bot size={16} aria-hidden="true" /> {t('AI assistant')}</b><p className="muted small">{t('Ask questions about your numbers, get a morning summary and alerts on the dashboard. Activated on request, billed by use.')}</p></div>
            <span className={`pill ${tn.addons?.ai_assistant ? '' : 'muted-pill'}`}>{tn.addons?.ai_assistant ? t('Active') : t('On request')}</span></li>
        </ul>
      </div>

      {others.length > 0 && (
        <details className="card">
          <summary>{t('More modules on the roadmap ({n})', { n: others.length })}</summary>
          <ul className="chip-list">{others.map((m) => <li key={m.key}><Lock size={13} aria-hidden="true" />{nm(m)}</li>)}</ul>
        </details>
      )}
    </section>
  )
}

const MOD_HINT: Record<string, string> = {
  kitchen: 'Kitchen screens and station printers, order timer and kitchen report.',
  recipes: 'Items made from ingredients; each sale deducts the ingredients from stock.',
  delivery: 'Orders from Keeta, Talabat and others, with commission settlement.',
  credit: 'Sell on account to customers with a credit limit, and collect later.',
  purchasing: 'Suppliers, purchase orders with approval, and goods received.',
  integrations: 'Send events to n8n or any webhook, and read data with API keys.',
  tables: 'Floor plan, open orders per table, send rounds to the kitchen, split the bill.',
  modifiers: 'Sizes, milk, extras, gift wrap: priced add-ons that can use stock.',
  variants: 'Size × colour matrix; each variant has its own barcode and stock.',
  batches: 'Batch numbers and expiry dates; sales take the first to expire.',
  weighed: 'Sell by weight; scale labels with the weight or price are read at the till.',
  promotions: 'Percent off, buy X get Y, bundles, happy hour and coupons, applied automatically.',
  loyalty: 'Points on every purchase, redeemed at the till.',
  appointments: 'Calendar by staff member, online booking page, checkout from the appointment.',
  commissions: 'Commission per staff member or per service, with a report.',
  memberships: 'Prepaid session packages and memberships, booked as deferred revenue.',
  job_cards: 'Drop-off tickets with tag numbers, ready notice, collect and pay.',
  preorders: 'Orders for a future date with a deposit (cakes, flowers, tailoring).',
}

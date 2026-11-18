import { CakeSlice, CalendarDays, Car, Coffee, Dumbbell, Flower2, Gift, Scissors, Shirt, ShoppingBasket, ShoppingCart, Sparkles, Store, UtensilsCrossed, WashingMachine, Waves, Zap, type LucideIcon } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Logo } from '../components/ui'
import { useT } from '../lib/i18n'
import { useSession } from '../lib/session'
import { rpc, supabase } from '../lib/supabase'
import type { BusinessProfile, Country, FeatureModule } from '../lib/types'

const ICON: Record<string, LucideIcon> = {
  restaurant: UtensilsCrossed, cafe: Coffee, quick_service: Zap, grocery: ShoppingBasket, fashion: Shirt,
  stationery: Gift, perfume: Sparkles, salon: Scissors, laundry: WashingMachine,
  bakery: CakeSlice, florist: Flower2, spa: Waves, car_wash: Car, gym: Dumbbell, hypermarket: ShoppingCart,
}
const FAMILY: Record<string, string> = { food: 'Food & drinks', retail: 'Retail', services: 'Services', wholesale: 'Wholesale' }

/** Four short steps; everything else has a sensible default and can be changed later in Settings. */
export default function Onboarding() {
  const { t, lang } = useT()
  const s = useSession()
  const [countries, setCountries] = useState<Country[]>([])
  const [profiles, setProfiles] = useState<BusinessProfile[]>([])
  const [mods, setMods] = useState<FeatureModule[]>([])
  const [step, setStep] = useState(0)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [f, setF] = useState({
    country_code: 'KW', business_profile: '', name: '', name_ar: '', tax_number: '',
    branch_name: '', display_name: '', pin: '', brand_color: '#2346D8', language: lang,
  })
  const set = (k: keyof typeof f, v: string) => setF((p) => ({ ...p, [k]: v }))
  const country = countries.find((c) => c.code === f.country_code)
  const nm = (x: { name_en: string; name_ar: string }) => (lang === 'ar' ? x.name_ar : x.name_en)

  useEffect(() => {
    void Promise.all([
      supabase.from('countries').select('*').order('name_en'),
      supabase.from('business_profiles').select('*').eq('launch', true).order('sort'),
      supabase.from('feature_modules').select('*').order('sort'),
    ]).then(([c, p, m]) => { setCountries((c.data ?? []) as Country[]); setProfiles((p.data ?? []) as BusinessProfile[]); setMods((m.data ?? []) as FeatureModule[]) })
  }, [])

  async function finish() {
    setBusy(true); setErr(null)
    try {
      await rpc('create_tenant', { p: { ...f, language: lang } })
      await s.reload()
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  /** What the card promises: only modules that exist today, then the ones coming for this type. */
  const promise = (p: BusinessProfile) => {
    const keys = Object.entries(p.modules).filter(([, v]) => v === 2).map(([k]) => k)
    const ready = mods.filter((m) => m.built && keys.includes(m.key)).map(nm)
    const soon = mods.filter((m) => !m.built && keys.includes(m.key)).map(nm)
    return { ready: [t('Sales, stock, customers, accounting'), ...ready].join(' · '), soon: soon.join(' · ') }
  }
  const families = [...new Set(profiles.map((p) => p.family))]
  const steps = [t('Country'), t('Business type'), t('Business details'), t('You')]
  const canNext = [!!country, !!f.business_profile, f.name.trim().length > 1, f.display_name.trim().length > 0 && /^\d{4,6}$/.test(f.pin)][step]

  return (
    <div className="auth">
      <div className={`auth-card wide ${step === 1 ? 'wider' : ''}`}>
        <div className="auth-brand"><Logo size={44} tile /><h1 className="wordmark">{t('Set up your business')}</h1></div>
        <ol className="steps">{steps.map((x, i) => <li key={x} className={i === step ? 'on' : i < step ? 'done' : ''}>{x}</li>)}</ol>

        {step === 0 && (
          <div className="stack">
            <label className="field"><span>{t('Where is the business?')}</span>
              <select id="ob-country" value={f.country_code} onChange={(e) => set('country_code', e.target.value)}>
                {countries.map((c) => <option key={c.code} value={c.code}>{lang === 'ar' ? c.name_ar : c.name_en}</option>)}
              </select></label>
            {country && <p className="muted">{t('Currency')}: {country.currency} · {t('VAT')}: {country.vat_rate}% · {country.prices_include_tax ? t('Prices include VAT') : t('VAT added at checkout')}</p>}
          </div>
        )}
        {step === 1 && (
          <div className="stack">
            <p className="muted">{t('Pick the closest match. Z Trust shows the tools this kind of business needs and hides the rest; you can change it later.')}</p>
            {families.map((fam) => (
              <div key={fam} className="stack tight">
                <h3 className="fam-head">{t(FAMILY[fam])}</h3>
                <div className="profile-grid">
                  {profiles.filter((p) => p.family === fam).map((p) => {
                    const Icon = ICON[p.key] ?? Store
                    const pr = promise(p)
                    return (
                      <button key={p.key} className={`choice profile ${f.business_profile === p.key ? 'on' : ''}`} aria-pressed={f.business_profile === p.key} onClick={() => set('business_profile', p.key)}>
                        <span className="choice-ico"><Icon size={20} aria-hidden="true" /></span>
                        <b>{nm(p)}</b>
                        <span>{pr.ready}</span>
                        {pr.soon && <span className="soon"><CalendarDays size={12} aria-hidden="true" /> {t('Coming')}: {pr.soon}</span>}
                      </button>)
                  })}
                </div>
              </div>
            ))}
          </div>
        )}
        {step === 2 && (
          <div className="grid2">
            <label className="field"><span>{t('Business name (English)')}</span><input id="ob-name" value={f.name} onChange={(e) => set('name', e.target.value)} /></label>
            <label className="field"><span>{t('Business name (Arabic)')}</span><input id="ob-name-ar" dir="rtl" value={f.name_ar} onChange={(e) => set('name_ar', e.target.value)} /></label>
            <label className="field"><span>{t('First branch name')}</span><input id="ob-branch" value={f.branch_name} placeholder={t('Main branch')} onChange={(e) => set('branch_name', e.target.value)} /></label>
            <label className="field"><span>{t('VAT / tax number (optional)')}</span><input id="ob-tax" value={f.tax_number} onChange={(e) => set('tax_number', e.target.value)} /></label>
            <label className="field"><span>{t('Brand colour')}</span><input id="ob-color" type="color" value={f.brand_color} onChange={(e) => set('brand_color', e.target.value)} /></label>
          </div>
        )}
        {step === 3 && (
          <div className="grid2">
            <label className="field"><span>{t('Your name')}</span><input id="ob-display" value={f.display_name} onChange={(e) => set('display_name', e.target.value)} /></label>
            <label className="field"><span>{t('Approval PIN (4–6 digits)')}</span>
              <input id="ob-pin" type="password" inputMode="numeric" maxLength={6} value={f.pin} onChange={(e) => set('pin', e.target.value.replace(/\D/g, ''))} /></label>
            <p className="muted span2">{t('You will use this PIN to approve discounts, refunds and cancellations at the till.')}</p>
          </div>
        )}

        {err && <p className="error">{err}</p>}
        <div className="row between">
          <button className="ghost" disabled={step === 0} onClick={() => setStep(step - 1)}>{t('Back')}</button>
          {step < 3
            ? <button className="primary" disabled={!canNext} onClick={() => setStep(step + 1)}>{t('Next')}</button>
            : <button className="primary" disabled={!canNext || busy} onClick={finish}>{busy ? t('Please wait…') : t('Open my business')}</button>}
        </div>
      </div>
    </div>
  )
}

import { useEffect, useState } from 'react'
import { Logo } from '../components/ui'
import { useT } from '../lib/i18n'
import { useSession } from '../lib/session'
import { rpc, supabase } from '../lib/supabase'
import type { BusinessType, Country } from '../lib/types'

const TYPES: { id: BusinessType; label: string; hint: string }[] = [
  { id: 'retail', label: 'Retail shop', hint: 'Products, barcodes, variants, stock' },
  { id: 'food', label: 'Café or restaurant', hint: 'Menu, modifiers, kitchen screen or printer' },
  { id: 'services', label: 'Salon or services', hint: 'Services, staff, bookings' },
  { id: 'mixed', label: 'Mixed business', hint: 'All of the above' },
]

/** Four short steps; everything else has a sensible default and can be changed later in Settings. */
export default function Onboarding() {
  const { t, lang } = useT()
  const s = useSession()
  const [countries, setCountries] = useState<Country[]>([])
  const [step, setStep] = useState(0)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [f, setF] = useState({
    country_code: 'KW', business_type: 'retail' as BusinessType, name: '', name_ar: '', tax_number: '',
    branch_name: '', display_name: '', pin: '', brand_color: '#2346D8', language: lang,
  })
  const set = (k: keyof typeof f, v: string) => setF((p) => ({ ...p, [k]: v }))
  const country = countries.find((c) => c.code === f.country_code)

  useEffect(() => {
    supabase.from('countries').select('*').order('name_en').then(({ data }) => setCountries((data ?? []) as Country[]))
  }, [])

  async function finish() {
    setBusy(true); setErr(null)
    try {
      await rpc('create_tenant', { p: { ...f, language: lang } })
      await s.reload()
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  const steps = [t('Country'), t('Business type'), t('Business details'), t('You')]
  const canNext = [!!country, !!f.business_type, f.name.trim().length > 1, f.display_name.trim().length > 0 && /^\d{4,6}$/.test(f.pin)][step]

  return (
    <div className="auth">
      <div className="auth-card wide">
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
          <div className="choice-grid">
            {TYPES.map((x) => (
              <button key={x.id} className={`choice ${f.business_type === x.id ? 'on' : ''}`} onClick={() => set('business_type', x.id)}>
                <b>{t(x.label)}</b><span>{t(x.hint)}</span>
              </button>
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

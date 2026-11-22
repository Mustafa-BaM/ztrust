import { useState } from 'react'
import { cardMethods } from '../../components/PayDialog'
import { useT } from '../../lib/i18n'
import { num, toMinor } from '../../lib/money'
import { useSession } from '../../lib/session'
import { supabase } from '../../lib/supabase'

/**
 * Country rules kept as settings, never in code: cash ceiling per invoice, card networks, banknotes, quotation validity
 * and the HR rules used for leave, unpaid days and the end-of-service estimate.
 */
export function RulesSettings() {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const st = tn.settings ?? {}
  const d = tn.currency_decimals
  const [f, setF] = useState({
    cash_limit: st.cash_limit ? num(st.cash_limit, d) : '', cash_limit_mode: st.cash_limit_mode ?? 'off',
    card_methods: (st.card_methods?.length ? st.card_methods : cardMethods(tn.country_code)).join(', '),
    cash_notes: (st.cash_notes ?? []).join(', '), quote_valid_days: String(st.quote_valid_days ?? 14),
    hr_annual_leave_days: String(st.hr_annual_leave_days ?? 30), hr_days_per_month: String(st.hr_days_per_month ?? 26),
    hr_indemnity_first_days: String(st.hr_indemnity_first_days ?? 15), hr_indemnity_first_years: String(st.hr_indemnity_first_years ?? 5),
    hr_indemnity_after_days: String(st.hr_indemnity_after_days ?? 30), hr_indemnity_cap_months: String(st.hr_indemnity_cap_months ?? 18),
  })
  const [msg, setMsg] = useState<string | null>(null)
  const n = (v: string) => (v.trim() === '' ? undefined : Number(v))
  async function save() {
    const next = {
      ...st,
      cash_limit: f.cash_limit ? toMinor(f.cash_limit, d) : 0, cash_limit_mode: f.cash_limit_mode as 'off' | 'warn' | 'block',
      card_methods: f.card_methods.split(',').map((x) => x.trim()).filter(Boolean),
      cash_notes: f.cash_notes.split(',').map((x) => Number(x.trim())).filter((x) => x > 0),
      quote_valid_days: n(f.quote_valid_days), hr_annual_leave_days: n(f.hr_annual_leave_days), hr_days_per_month: n(f.hr_days_per_month),
      hr_indemnity_first_days: n(f.hr_indemnity_first_days), hr_indemnity_first_years: n(f.hr_indemnity_first_years),
      hr_indemnity_after_days: n(f.hr_indemnity_after_days), hr_indemnity_cap_months: n(f.hr_indemnity_cap_months),
    }
    const { error } = await supabase.from('tenants').update({ settings: next }).eq('id', tn.id)
    setMsg(error ? error.message : t('Saved')); if (!error) await s.reload()
  }
  const fld = (k: keyof typeof f, label: string, hint?: string) => (
    <label className="field"><span>{t(label)}{k === 'cash_limit' ? ` (${tn.currency})` : ''}</span><input id={`rule-${k}`} inputMode="decimal" value={f[k]} onChange={(e) => setF({ ...f, [k]: e.target.value })} />{hint && <small className="muted">{t(hint)}</small>}</label>)
  return (
    <section className="card grid2">
      <h2 className="span2">{t('Payments & compliance')}</h2>
      <p className="muted small span2">{t('Rules differ by country and sector. They are settings here, not fixed in the system. Check them against the regulations that apply to your business.')}</p>
      {fld('cash_limit', 'Cash ceiling per invoice', 'Leave empty for no ceiling.')}
      <label className="field"><span>{t('Above the ceiling')}</span>
        <select id="rule-cash_limit_mode" value={f.cash_limit_mode} onChange={(e) => setF({ ...f, cash_limit_mode: e.target.value as typeof f.cash_limit_mode })}>
          <option value="off">{t('No check')}</option><option value="warn">{t('Warn the cashier')}</option><option value="block">{t('Block cash above the ceiling')}</option></select></label>
      <label className="field span2"><span>{t('Card networks and wallets on the till')}</span>
        <input id="rule-card_methods" value={f.card_methods} onChange={(e) => setF({ ...f, card_methods: e.target.value })} />
        <small className="muted">{t('Separated by commas. The first one is used by the quick Card button.')}</small></label>
      {fld('cash_notes', 'Banknotes for quick cash buttons', 'e.g. 1, 5, 10, 20. Empty = the usual notes of your currency.')}
      {fld('quote_valid_days', 'Quotation valid for (days)')}
      <h3 className="span2 sub-h">{t('HR rules')}</h3>
      {fld('hr_annual_leave_days', 'Annual leave days per year')}
      {fld('hr_days_per_month', 'Days in a salary month (daily rate = salary ÷ days)')}
      {fld('hr_indemnity_first_days', 'End of service: days per year (first years)')}
      {fld('hr_indemnity_first_years', 'End of service: number of first years')}
      {fld('hr_indemnity_after_days', 'End of service: days per year after that')}
      {fld('hr_indemnity_cap_months', 'End of service: maximum (months of salary)')}
      <div className="row end span2">{msg && <span className="muted">{msg}</span>}<button className="primary" onClick={() => void save()}>{t('Save')}</button></div>
    </section>
  )
}

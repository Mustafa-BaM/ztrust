import { Fragment, useCallback, useEffect, useState } from 'react'
import { useT } from '../lib/i18n'
import { fmt, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { getShift, setShift } from '../lib/shift'
import { rpc, supabase } from '../lib/supabase'
import { tenderLabel } from '../components/Receipt'
import { useApproval } from '../components/ui'

interface Summary {
  shift: { id: string; opened_at: string; closed_at: string | null; opening_float: number; counted_cash: number | null; variance: number | null }
  invoices: number; credit_notes: number; sales_total: number; refunds_total: number; tax_total: number
  tenders: Record<string, number>; expected_cash: number | null
}

/** Open shift with a float, blind cash count at close, Z report. */
export default function Shift() {
  const { t, lang } = useT()
  const s = useSession()
  const tenant = s.tenant!
  const user = s.session!.user.id
  const branch = s.branch!
  const [shiftId, setShiftId] = useState<string | null>(getShift(branch.id, user))
  const [summary, setSummary] = useState<Summary | null>(null)
  const [float, setFloat] = useState('')
  const [counted, setCounted] = useState('')
  const [zReport, setZReport] = useState<Summary | null>(null)
  const [drawerReason, setDrawerReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const approval = useApproval()

  const load = useCallback(async () => {
    // reconcile local memory with the server
    const { data } = await supabase.from('shifts').select('id').eq('branch_id', branch.id).eq('opened_by', user).is('closed_at', null).maybeSingle()
    const id = data?.id ?? null
    setShift(branch.id, user, id); setShiftId(id)
    if (id) setSummary(await rpc<Summary>('shift_summary', { p_shift: id }))
  }, [branch.id, user])
  useEffect(() => { if (navigator.onLine) void load() }, [load])

  async function open() {
    setErr(null)
    const v = toMinor(float || '0', tenant.currency_decimals)
    if (!Number.isFinite(v)) return setErr(t('Enter a valid amount'))
    try { const id = await rpc<string>('open_shift', { p_branch: branch.id, p_float: v }); setShift(branch.id, user, id); setShiftId(id); await load() }
    catch (e) { setErr((e as Error).message) }
  }
  async function close() {
    setErr(null)
    const v = toMinor(counted, tenant.currency_decimals)
    if (!Number.isFinite(v)) return setErr(t('Enter the counted cash'))
    try { const z = await rpc<Summary>('close_shift', { p_shift: shiftId, p_counted: v }); setShift(branch.id, user, null); setShiftId(null); setSummary(null); setZReport(z) }
    catch (e) { setErr((e as Error).message) }
  }
  async function noSale() {
    const ok = await approval.run((pin) => rpc('log_drawer_open', { p_branch: branch.id, p_reason: drawerReason, p_pin: pin ?? null }))
    if (ok !== null) setDrawerReason('')
  }

  const m = (v: number | null | undefined) => (v == null ? '—' : fmt(v, tenant, lang))

  return (
    <div className="page narrow">
      <h1>{t('Shift')}</h1>
      {zReport && (
        <section className="card zreport">
          <h2>{t('Z report')}</h2>
          <dl className="dl">
            <dt>{t('Opened')}</dt><dd>{new Date(zReport.shift.opened_at).toLocaleString()}</dd>
            <dt>{t('Closed')}</dt><dd>{zReport.shift.closed_at && new Date(zReport.shift.closed_at).toLocaleString()}</dd>
            <dt>{t('Invoices')}</dt><dd>{zReport.invoices}</dd>
            <dt>{t('Sales')}</dt><dd>{m(zReport.sales_total)}</dd>
            <dt>{t('Refunds')}</dt><dd>{m(zReport.refunds_total)} ({zReport.credit_notes})</dd>
            <dt>{t('VAT')}</dt><dd>{m(zReport.tax_total)}</dd>
            {Object.entries(zReport.tenders).map(([k, v]) => <Fragment key={k}><dt>{tenderLabel(k, lang)}</dt><dd>{m(v)}</dd></Fragment>)}
            <dt>{t('Opening float')}</dt><dd>{m(zReport.shift.opening_float)}</dd>
            <dt>{t('Expected cash')}</dt><dd>{m(zReport.expected_cash)}</dd>
            <dt>{t('Counted cash')}</dt><dd>{m(zReport.shift.counted_cash)}</dd>
            <dt>{t('Over / short')}</dt><dd className={zReport.shift.variance ? 'bad' : 'good'}>{m(zReport.shift.variance)}</dd>
          </dl>
        </section>
      )}

      {!shiftId ? (
        <section className="card stack">
          <h2>{t('Open shift')}</h2>
          <label className="field"><span>{t('Opening cash float')} ({tenant.currency})</span>
            <input id="shift-float" inputMode="decimal" value={float} onChange={(e) => setFloat(e.target.value)} placeholder="0" /></label>
          <button className="primary big" onClick={open}>{t('Open shift')}</button>
        </section>
      ) : (
        <>
          <section className="card">
            <h2>{t('Current shift')}</h2>
            {summary && (
              <dl className="dl">
                <dt>{t('Opened')}</dt><dd>{new Date(summary.shift.opened_at).toLocaleString()}</dd>
                <dt>{t('Invoices')}</dt><dd>{summary.invoices}</dd>
                <dt>{t('Sales')}</dt><dd>{m(summary.sales_total)}</dd>
                <dt>{t('Refunds')}</dt><dd>{m(summary.refunds_total)}</dd>
                {summary.expected_cash != null && <><dt>{t('Expected cash')}</dt><dd>{m(summary.expected_cash)}</dd></>}
              </dl>
            )}
          </section>
          <section className="card stack">
            <h2>{t('Close shift')}</h2>
            <p className="muted">{t('Count the cash in the drawer and enter the total. The expected amount is shown after you close.')}</p>
            <label className="field"><span>{t('Counted cash')} ({tenant.currency})</span>
              <input id="shift-counted" inputMode="decimal" value={counted} onChange={(e) => setCounted(e.target.value)} /></label>
            <button className="primary" onClick={close} disabled={!counted}>{t('Close shift and print Z report')}</button>
          </section>
          <section className="card stack">
            <h2>{t('Open drawer without a sale')}</h2>
            <label className="field"><span>{t('Reason')}</span><input id="drawer-reason" value={drawerReason} onChange={(e) => setDrawerReason(e.target.value)} /></label>
            <button onClick={noSale} disabled={!drawerReason.trim()}>{t('Log drawer opening')}</button>
            {approval.error && <p className="error">{approval.error}</p>}
          </section>
        </>
      )}
      {err && <p className="error">{err}</p>}
      {approval.dialog}
    </div>
  )
}

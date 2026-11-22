import { ArrowDownToLine, ArrowUpFromLine, Printer } from 'lucide-react'
import { Fragment, useCallback, useEffect, useState } from 'react'
import { PrintDoc } from '../components/PrintDoc'
import { tenderLabel } from '../components/Receipt'
import { Modal, useApproval } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { getShift, setShift } from '../lib/shift'
import { rpc, supabase } from '../lib/supabase'

interface Move { kind: 'in' | 'out'; amount: number; counter: string; reason: string; at: string }
interface Summary {
  shift: { id: string; opened_at: string; closed_at: string | null; opening_float: number; counted_cash: number | null; variance: number | null }
  invoices: number; credit_notes: number; sales_total: number; refunds_total: number; discounts_total?: number; tax_total: number
  tenders: Record<string, number>; methods?: Record<string, number>; cash_in?: number; cash_out?: number; moves?: Move[]
  expected_cash: number | null; printed_at?: string
}
const COUNTER_LABEL: Record<string, string> = { safe: 'Safe', bank: 'Bank', expense: 'Expense', owner: 'Owner', exchange: 'Exchange difference' }

/** Open shift with a float, cash in / cash out with a reason, X report during the shift, blind count and Z report at close. */
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
  const [move, setMove] = useState<null | 'in' | 'out'>(null)
  const [print, setPrint] = useState<null | { kind: 'X' | 'Z'; data: Summary }>(null)
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
  async function xReport() { if (shiftId) { const x = await rpc<Summary>('shift_summary', { p_shift: shiftId }); setSummary(x); setPrint({ kind: 'X', data: x }) } }

  const m = (v: number | null | undefined) => (v == null ? '—' : fmt(v, tenant, lang))
  return (
    <div className="page narrow">
      <h1>{t('Shift')}</h1>
      {zReport && (
        <section className="card zreport">
          <header className="row between"><h2>{t('Z report')}</h2><button className="ghost" onClick={() => setPrint({ kind: 'Z', data: zReport })}><Printer size={16} />{t('Print')}</button></header>
          <ShiftDl r={zReport} m={m} final />
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
            <header className="row between"><h2>{t('Current shift')}</h2>
              <button className="ghost" onClick={() => void xReport()}><Printer size={16} />{t('Print X report')}</button></header>
            {summary && <ShiftDl r={summary} m={m} />}
          </section>
          <section className="card stack">
            <h2>{t('Cash in / cash out')}</h2>
            <p className="muted small">{t('Money put into or taken out of the drawer during the shift, with a reason. It changes the expected cash.')}</p>
            <div className="row">
              <button onClick={() => setMove('out')}><ArrowUpFromLine size={16} />{t('Cash out')}</button>
              <button onClick={() => setMove('in')}><ArrowDownToLine size={16} />{t('Cash in')}</button>
            </div>
            {summary?.moves && summary.moves.length > 0 && (
              <ul className="feed">{summary.moves.map((x, i) => (
                <li key={i}><span className={`feed-ico ${x.kind === 'out' ? 'bad' : ''}`} aria-hidden="true">{x.kind === 'out' ? '−' : '+'}</span>
                  <div><b>{x.reason}</b><p className="muted small">{t(COUNTER_LABEL[x.counter] ?? x.counter)} · {new Date(x.at).toLocaleTimeString(lang === 'ar' ? 'ar-u-nu-latn' : undefined, { hour: '2-digit', minute: '2-digit' })}</p></div>
                  <b className="num">{x.kind === 'out' ? '−' : '+'}{m(x.amount)}</b></li>))}</ul>)}
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
      <Checklists />
      {err && <p className="error">{err}</p>}
      {move && shiftId && <CashMoveDialog kind={move} shiftId={shiftId} onClose={() => setMove(null)} onDone={(x) => { setSummary(x); setMove(null) }} />}
      {print && (
        <PrintDoc paper="80" onDone={() => setPrint(null)}>
          <div className="receipt">
            <div className="r-center"><b>{tenant.name}</b><div>{branch.name}</div>
              <div><b>{print.kind === 'X' ? 'X report / تقرير X' : 'Z report / تقرير Z'}</b></div>
              <div>{new Date(print.data.printed_at ?? Date.now()).toLocaleString(lang === 'ar' ? 'ar-u-nu-latn' : undefined)}</div>
              <div>{s.member?.display_name}</div></div>
            <ShiftDl r={print.data} m={m} final={print.kind === 'Z'} />
            {print.kind === 'X' && <p className="r-note">{t('Mid-shift report. The shift stays open.')}</p>}
          </div>
        </PrintDoc>
      )}
      {approval.dialog}
    </div>
  )
}

function ShiftDl({ r, m, final }: { r: Summary; m: (v: number | null | undefined) => string; final?: boolean }) {
  const { t, lang } = useT()
  return (
    <dl className="dl">
      <dt>{t('Opened')}</dt><dd>{new Date(r.shift.opened_at).toLocaleString(lang === 'ar' ? 'ar-u-nu-latn' : undefined)}</dd>
      {final && <><dt>{t('Closed')}</dt><dd>{r.shift.closed_at && new Date(r.shift.closed_at).toLocaleString(lang === 'ar' ? 'ar-u-nu-latn' : undefined)}</dd></>}
      <dt>{t('Invoices')}</dt><dd>{r.invoices}</dd>
      <dt>{t('Sales')}</dt><dd>{m(r.sales_total)}</dd>
      {r.discounts_total != null && r.discounts_total > 0 && <><dt>{t('Discounts')}</dt><dd>{m(r.discounts_total)}</dd></>}
      <dt>{t('Refunds')}</dt><dd>{m(r.refunds_total)} ({r.credit_notes})</dd>
      <dt>{t('VAT')}</dt><dd>{m(r.tax_total)}</dd>
      {Object.entries(r.tenders).map(([k, v]) => <Fragment key={k}><dt>{tenderLabel(k, lang)}</dt><dd>{m(v)}</dd></Fragment>)}
      {r.methods && Object.entries(r.methods).map(([k, v]) => <Fragment key={k}><dt className="sub">· {k}</dt><dd>{m(v)}</dd></Fragment>)}
      <dt>{t('Opening float')}</dt><dd>{m(r.shift.opening_float)}</dd>
      {(r.cash_in ?? 0) > 0 && <><dt>{t('Cash in')}</dt><dd>{m(r.cash_in)}</dd></>}
      {(r.cash_out ?? 0) > 0 && <><dt>{t('Cash out')}</dt><dd>−{m(r.cash_out)}</dd></>}
      {r.expected_cash != null && <><dt>{t('Expected cash')}</dt><dd>{m(r.expected_cash)}</dd></>}
      {final && <><dt>{t('Counted cash')}</dt><dd>{m(r.shift.counted_cash)}</dd>
        <dt>{t('Over / short')}</dt><dd className={r.shift.variance ? 'bad' : 'good'}>{m(r.shift.variance)}</dd></>}
    </dl>
  )
}

function CashMoveDialog({ kind, shiftId, onClose, onDone }: { kind: 'in' | 'out'; shiftId: string; onClose: () => void; onDone: (s: Summary) => void }) {
  const { t, lang } = useT()
  const s = useSession()
  const tenant = s.tenant!
  const approval = useApproval()
  const [f, setF] = useState({ amount: '', counter: 'safe', reason: '', account_id: '' })
  const [accounts, setAccounts] = useState<{ id: string; code: string; name_en: string; name_ar: string }[]>([])
  useEffect(() => {
    if (kind === 'out') void supabase.from('accounts').select('id, code, name_en, name_ar').eq('tenant_id', tenant.id).eq('is_active', true)
      .in('section', ['operating_expense', 'other_expense']).order('code').then(({ data }) => setAccounts(data ?? []))
  }, [kind, tenant.id])
  const amt = toMinor(f.amount || '0', tenant.currency_decimals)
  async function save() {
    const r = await approval.run((pin) => rpc<Summary>('cash_move', { p: { shift_id: shiftId, kind, amount: amt, counter: f.counter, reason: f.reason,
      account_id: f.counter === 'expense' ? f.account_id : null, approver_pin: pin ?? null } }))
    if (r) onDone(r)
  }
  const counters = kind === 'out' ? ['safe', 'bank', 'expense', 'owner'] : ['safe', 'bank', 'owner']
  return (
    <Modal title={kind === 'out' ? t('Cash out') : t('Cash in')} onClose={onClose}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); void save() }}>
        <label className="field"><span>{t('Amount')} ({tenant.currency})</span><input id="cm-amount" autoFocus inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></label>
        <div className="seg" role="group" aria-label={kind === 'out' ? t('Where does the cash go?') : t('Where does the cash come from?')}>
          {counters.map((c) => <button type="button" key={c} className={f.counter === c ? 'on' : ''} onClick={() => setF({ ...f, counter: c })}>{t(COUNTER_LABEL[c])}</button>)}
        </div>
        {f.counter === 'expense' && (
          <label className="field"><span>{t('Expense account')}</span>
            <select id="cm-account" value={f.account_id} onChange={(e) => setF({ ...f, account_id: e.target.value })}>
              <option value="">—</option>{accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {lang === 'ar' ? a.name_ar : a.name_en}</option>)}</select></label>)}
        <label className="field"><span>{t('Reason')}</span><input id="cm-reason" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></label>
        {approval.error && <p className="error">{approval.error}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button>
          <button className="primary" disabled={!(amt > 0) || !f.reason.trim() || (f.counter === 'expense' && !f.account_id)}>{t('Save')}</button></div>
      </form>
      {approval.dialog}
    </Modal>
  )
}

/** Opening / closing / custom checklists for today at this branch: tick each task; who and when is kept. */
function Checklists() {
  const { t } = useT()
  const s = useSession()
  const [lists, setLists] = useState<{ id: string; name: string; items: string[] }[]>([])
  const [runs, setRuns] = useState<Record<string, { done: Record<string, { by: string; at: string }>; completed_at: string | null }>>({})
  const load = useCallback(async () => {
    const [a, b] = await Promise.all([supabase.from('checklists').select('id, name, items').eq('tenant_id', s.tenant!.id).eq('is_active', true).order('name'),
      supabase.from('checklist_runs').select('checklist_id, done, completed_at, run_date').eq('branch_id', s.branch!.id).order('run_date', { ascending: false }).limit(50)])
    setLists(a.data ?? [])
    const today = new Date().toLocaleDateString('en-CA')
    setRuns(Object.fromEntries(((b.data ?? []) as { checklist_id: string; done: Record<string, { by: string; at: string }>; completed_at: string | null; run_date: string }[]).filter((r) => r.run_date === today).map((r) => [r.checklist_id, r])))
  }, [s.tenant, s.branch])
  useEffect(() => { void load() }, [load])
  if (!lists.length) return null
  return (
    <section className="card stack">
      <h2>{t('Today\'s checklists')}</h2>
      {lists.map((l) => { const r = runs[l.id]
        return <div key={l.id} className="stack"><b>{l.name}{r?.completed_at ? ` ✓` : ''}</b>
          {l.items.map((it, i) => { const d = r?.done?.[String(i)]
            return <label key={i} className="check"><input id={`ck-${l.id}-${i}`} type="checkbox" checked={Boolean(d)} onChange={async (e) => { await rpc('tick_checklist', { p_checklist: l.id, p_branch: s.branch!.id, p_index: i, p_done: e.target.checked }); void load() }} />
              {it}{d && <span className="muted small"> · {d.by} {new Date(d.at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}</span>}</label> })}</div> })}
    </section>
  )
}

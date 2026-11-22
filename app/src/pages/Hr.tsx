import { Download, Plus, Printer } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { PrintDoc } from '../components/PrintDoc'
import { Empty, Modal, useApproval } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt, num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { rpc, supabase } from '../lib/supabase'

interface Emp { id: string; branch_id: string | null; user_id: string | null; name: string; name_ar: string | null; job_title: string | null; nationality: string | null; phone: string | null
  civil_id: string | null; civil_id_expiry: string | null; passport_no: string | null; passport_expiry: string | null; residency_expiry: string | null; health_card_expiry: string | null
  license_expiry: string | null; join_date: string; end_date: string | null; basic_salary: number; allowances: number; bank_name: string | null; iban: string | null
  annual_leave_days: number | null; is_active: boolean }
interface Overview { employee_id: string; name: string; years: number; leave_earned: number; leave_taken: number; leave_balance: number; indemnity: number; next_expiry: string | null; next_expiry_doc: string | null }
interface Run { id: string; month: string; status: 'draft' | 'posted' | 'paid'; gross: number; deductions: number; net: number }
interface PLine { id: string; employee_id: string; basic: number; allowances: number; commission: number; overtime: number; other_additions: number; unpaid_days: number; absence: number; advance: number; other_deductions: number; net: number; note: string | null }
const DOCS: Record<string, string> = { civil_id: 'Civil ID', passport: 'Passport', residency: 'Residency', health_card: 'Health card', license: 'Professional licence' }
const LEAVE: Record<string, string> = { annual: 'Annual', sick: 'Sick', emergency: 'Emergency', unpaid: 'Unpaid' }
const daysTo = (d: string | null) => (d ? Math.ceil((Date.parse(d) - Date.now()) / 86400000) : null)

/** Simple HR: employees and their documents, leave, advances and the monthly payroll. */
export default function Hr() {
  const { t } = useT()
  const s = useSession()
  const [tab, setTab] = useState<'employees' | 'leave' | 'advances' | 'payroll'>(s.can('hr.manage') ? 'employees' : 'payroll')
  const tabs = [['employees', 'Employees', s.can('hr.manage') || s.can('payroll.run')], ['leave', 'Leave', s.can('hr.manage')], ['advances', 'Advances', s.can('payroll.run')], ['payroll', 'Payroll', s.can('payroll.run')]] as const
  return (
    <div className="page">
      <div className="tabs" role="tablist">{tabs.filter((x) => x[2]).map(([k, l]) => <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>{t(l)}</button>)}</div>
      {tab === 'employees' && <Employees />}
      {tab === 'leave' && <Leave />}
      {tab === 'advances' && <Advances />}
      {tab === 'payroll' && <Payroll />}
    </div>
  )
}

function useEmployees() {
  const s = useSession()
  const [rows, setRows] = useState<Emp[]>([])
  const load = useCallback(async () => { const { data } = await supabase.from('employees').select('*').eq('tenant_id', s.tenant!.id).order('name'); setRows((data ?? []) as Emp[]) }, [s.tenant])
  useEffect(() => { void load() }, [load])
  return { rows, load }
}

function Employees() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const { rows, load } = useEmployees()
  const [ov, setOv] = useState<Record<string, Overview>>({})
  const [edit, setEdit] = useState<Partial<Emp> | null>(null)
  useEffect(() => { void rpc<Overview[]>('hr_overview', { p_tenant: tn.id }).then((r) => setOv(Object.fromEntries(r.map((x) => [x.employee_id, x])))).catch(() => setOv({})) }, [tn.id, rows])
  const expiring = Object.values(ov).filter((x) => { const n = daysTo(x.next_expiry); return n != null && n <= 30 })
  return (
    <div className="stack">
      <div className="row between wrap">
        {expiring.length > 0 ? <p className="amber-note">{t('{n} employees have a document expiring within 30 days', { n: expiring.length })}</p> : <span />}
        {s.can('hr.manage') && <button className="primary" onClick={() => setEdit({ join_date: new Date().toISOString().slice(0, 10), is_active: true })}><Plus size={16} />{t('Add employee')}</button>}
      </div>
      {rows.length === 0 ? <Empty title={t('No employees yet')} hint={t('Add each employee with their documents and salary. Link a staff login to bring POS commissions into payroll.')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>{t('Job title')}</th><th className="num">{t('Basic salary')}</th><th className="num">{t('Leave balance (days)')}</th><th className="num">{t('End of service (estimate)')}</th><th>{t('Next document to expire')}</th></tr></thead>
          <tbody>{rows.map((e) => { const o = ov[e.id]; const n = daysTo(o?.next_expiry ?? null)
            return <tr key={e.id} className={`clickable ${e.is_active ? '' : 'dim'}`} onClick={() => s.can('hr.manage') && setEdit(e)}>
              <td>{lang === 'ar' && e.name_ar ? e.name_ar : e.name}</td><td>{e.job_title ?? ''}</td><td className="num">{num(e.basic_salary, tn.currency_decimals)}</td>
              <td className="num">{o ? Number(o.leave_balance).toFixed(1) : ''}</td><td className="num">{o ? fmt(o.indemnity, tn, lang) : ''}</td>
              <td className={n != null && n <= 30 ? (n < 0 ? 'bad' : 'warn') : ''}>{o?.next_expiry ? `${t(DOCS[o.next_expiry_doc ?? ''] ?? '')} · ${o.next_expiry}` : '—'}</td></tr> })}</tbody>
        </table></div>)}
      <p className="muted small">{t('End of service and leave use the HR rules in Settings → Business. They are estimates; confirm them against the labour law that applies.')}</p>
      {edit && <EmpForm e={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); void load() }} />}
    </div>
  )
}

function EmpForm({ e, onClose, onSaved }: { e: Partial<Emp>; onClose: () => void; onSaved: () => void }) {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [staff, setStaff] = useState<{ user_id: string; display_name: string }[]>([])
  useEffect(() => { void supabase.from('memberships').select('user_id, display_name').eq('tenant_id', tn.id).eq('is_active', true).then(({ data }) => setStaff(data ?? [])) }, [tn.id])
  const str = (v: unknown) => (v == null ? '' : String(v))
  const [f, setF] = useState<Record<string, string>>({
    name: str(e.name), name_ar: str(e.name_ar), job_title: str(e.job_title), nationality: str(e.nationality), phone: str(e.phone), user_id: str(e.user_id),
    branch_id: str(e.branch_id ?? s.branch?.id), civil_id: str(e.civil_id), civil_id_expiry: str(e.civil_id_expiry), passport_no: str(e.passport_no), passport_expiry: str(e.passport_expiry),
    residency_expiry: str(e.residency_expiry), health_card_expiry: str(e.health_card_expiry), license_expiry: str(e.license_expiry), join_date: str(e.join_date), end_date: str(e.end_date),
    basic_salary: e.basic_salary != null ? num(e.basic_salary, d) : '', allowances: e.allowances != null ? num(e.allowances, d) : '', bank_name: str(e.bank_name), iban: str(e.iban),
    annual_leave_days: str(e.annual_leave_days), is_active: e.is_active === false ? 'no' : 'yes' })
  const [err, setErr] = useState<string | null>(null)
  async function save() {
    const row = { tenant_id: tn.id, name: f.name.trim(), name_ar: f.name_ar || null, job_title: f.job_title || null, nationality: f.nationality || null, phone: f.phone || null,
      user_id: f.user_id || null, branch_id: f.branch_id || null, civil_id: f.civil_id || null, civil_id_expiry: f.civil_id_expiry || null, passport_no: f.passport_no || null,
      passport_expiry: f.passport_expiry || null, residency_expiry: f.residency_expiry || null, health_card_expiry: f.health_card_expiry || null, license_expiry: f.license_expiry || null,
      join_date: f.join_date, end_date: f.end_date || null, basic_salary: toMinor(f.basic_salary || '0', d), allowances: toMinor(f.allowances || '0', d),
      bank_name: f.bank_name || null, iban: f.iban.replace(/\s/g, '').toUpperCase() || null, annual_leave_days: f.annual_leave_days ? Number(f.annual_leave_days) : null, is_active: f.is_active === 'yes' }
    const { error } = e.id ? await supabase.from('employees').update(row).eq('id', e.id) : await supabase.from('employees').insert(row)
    if (error) setErr(error.message); else onSaved()
  }
  const txt = (k: string, label: string, type = 'text') => <label className="field"><span>{t(label)}{['basic_salary', 'allowances'].includes(k) ? ` (${tn.currency})` : ''}</span><input id={`emp-${k}`} type={type} inputMode={['basic_salary', 'allowances', 'annual_leave_days'].includes(k) ? 'decimal' : undefined} value={f[k]} onChange={(x) => setF({ ...f, [k]: x.target.value })} /></label>
  return (
    <Modal title={e.id ? t('Edit employee') : t('Add employee')} onClose={onClose} wide>
      <form className="grid2" onSubmit={(x) => { x.preventDefault(); void save() }}>
        {txt('name', 'Name')}{txt('name_ar', 'Name (Arabic)')}{txt('job_title', 'Job title')}{txt('nationality', 'Nationality')}{txt('phone', 'Phone')}
        <label className="field"><span>{t('Staff login (for commissions)')}</span><select id="emp-user" value={f.user_id} onChange={(x) => setF({ ...f, user_id: x.target.value })}>
          <option value="">—</option>{staff.map((m) => <option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label>
        <h3 className="span2 sub-h">{t('Documents')}</h3>
        {txt('civil_id', 'Civil ID / national ID')}{txt('civil_id_expiry', 'ID expiry', 'date')}{txt('passport_no', 'Passport number')}{txt('passport_expiry', 'Passport expiry', 'date')}
        {txt('residency_expiry', 'Residency expiry', 'date')}{txt('health_card_expiry', 'Health card expiry', 'date')}{txt('license_expiry', 'Professional licence expiry', 'date')}
        <h3 className="span2 sub-h">{t('Salary and bank')}</h3>
        {txt('join_date', 'Joining date', 'date')}{txt('end_date', 'Last working day', 'date')}{txt('basic_salary', 'Basic salary')}{txt('allowances', 'Allowances')}
        {txt('bank_name', 'Bank')}{txt('iban', 'IBAN')}{txt('annual_leave_days', 'Annual leave days (empty = business default)')}
        <label className="field"><span>{t('Status')}</span><select id="emp-active" value={f.is_active} onChange={(x) => setF({ ...f, is_active: x.target.value })}><option value="yes">{t('Active')}</option><option value="no">{t('Left')}</option></select></label>
        {err && <p className="error span2">{err}</p>}
        <div className="row end span2"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!f.name.trim() || !f.join_date}>{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

function Leave() {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const { rows: emps } = useEmployees()
  const [rows, setRows] = useState<{ id: string; employee_id: string; kind: string; from_date: string; to_date: string; days: number; status: string; note: string | null }[]>([])
  const [f, setF] = useState({ employee_id: '', kind: 'annual', from_date: '', to_date: '', note: '' })
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => { const { data } = await supabase.from('leave_requests').select('*').eq('tenant_id', tn.id).order('from_date', { ascending: false }).limit(300); setRows(data ?? []) }, [tn.id])
  useEffect(() => { void load() }, [load])
  const days = f.from_date && f.to_date ? Math.round((Date.parse(f.to_date) - Date.parse(f.from_date)) / 86400000) + 1 : 0
  async function add() {
    const { error } = await supabase.from('leave_requests').insert({ tenant_id: tn.id, employee_id: f.employee_id, kind: f.kind, from_date: f.from_date, to_date: f.to_date, days, note: f.note || null, decided_by: s.session?.user.id })
    if (error) setErr(error.message); else { setF({ ...f, from_date: '', to_date: '', note: '' }); void load() }
  }
  const ename = (id: string) => emps.find((e) => e.id === id)?.name ?? ''
  return (
    <div className="stack">
      <form className="card row wrap" onSubmit={(e) => { e.preventDefault(); void add() }}>
        <label className="field"><span>{t('Employee')}</span><select id="lv-emp" value={f.employee_id} onChange={(e) => setF({ ...f, employee_id: e.target.value })}><option value="">—</option>{emps.filter((e) => e.is_active).map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}</select></label>
        <label className="field"><span>{t('Type')}</span><select id="lv-kind" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}>{Object.entries(LEAVE).map(([k, l]) => <option key={k} value={k}>{t(l)}</option>)}</select></label>
        <label className="field"><span>{t('From')}</span><input id="lv-from" type="date" value={f.from_date} onChange={(e) => setF({ ...f, from_date: e.target.value })} /></label>
        <label className="field"><span>{t('To')}</span><input id="lv-to" type="date" min={f.from_date} value={f.to_date} onChange={(e) => setF({ ...f, to_date: e.target.value })} /></label>
        <label className="field"><span>{t('Note')}</span><input id="lv-note" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></label>
        <button className="primary" disabled={!f.employee_id || days <= 0}>{t('Record leave')}{days > 0 ? ` (${days})` : ''}</button>
      </form>
      {err && <p className="error">{err}</p>}
      {rows.length === 0 ? <Empty title={t('No leave recorded')} /> : <div className="table-wrap"><table className="list compact">
        <thead><tr><th>{t('Employee')}</th><th>{t('Type')}</th><th>{t('From')}</th><th>{t('To')}</th><th className="num">{t('Days')}</th><th>{t('Note')}</th></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.id}><td>{ename(r.employee_id)}</td><td>{t(LEAVE[r.kind])}</td><td>{r.from_date}</td><td>{r.to_date}</td><td className="num">{Number(r.days)}</td><td>{r.note ?? ''}</td></tr>)}</tbody></table></div>}
      <p className="muted small">{t('Unpaid leave in a month is deducted in that month\'s payroll (salary ÷ days in a salary month × days).')}</p>
    </div>
  )
}

function Advances() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const { rows: emps } = useEmployees()
  const approval = useApproval()
  const [rows, setRows] = useState<{ id: string; employee_id: string; amount: number; monthly_deduction: number; recovered: number; given_on: string; note: string | null }[]>([])
  const [f, setF] = useState({ employee_id: '', amount: '', monthly: '', paid_from: 'bank', note: '' })
  const load = useCallback(async () => { const { data } = await supabase.from('employee_advances').select('*').eq('tenant_id', tn.id).order('given_on', { ascending: false }); setRows(data ?? []) }, [tn.id])
  useEffect(() => { void load() }, [load])
  async function give() {
    const r = await approval.run(() => rpc('give_advance', { p: { employee_id: f.employee_id, amount: toMinor(f.amount, d), monthly_deduction: toMinor(f.monthly || f.amount, d), paid_from: f.paid_from, note: f.note || null } }))
    if (r) { setF({ ...f, amount: '', monthly: '', note: '' }); void load() }
  }
  return (
    <div className="stack">
      <form className="card row wrap" onSubmit={(e) => { e.preventDefault(); void give() }}>
        <label className="field"><span>{t('Employee')}</span><select id="adv-emp" value={f.employee_id} onChange={(e) => setF({ ...f, employee_id: e.target.value })}><option value="">—</option>{emps.filter((e) => e.is_active).map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}</select></label>
        <label className="field"><span>{t('Amount')}</span><input id="adv-amount" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></label>
        <label className="field"><span>{t('Deduct per month')}</span><input id="adv-monthly" inputMode="decimal" value={f.monthly} onChange={(e) => setF({ ...f, monthly: e.target.value })} /></label>
        <label className="field"><span>{t('Paid from')}</span><select id="adv-from" value={f.paid_from} onChange={(e) => setF({ ...f, paid_from: e.target.value })}>
          <option value="bank">{t('Bank')}</option><option value="cash_safe">{t('Safe')}</option><option value="petty_cash">{t('Petty cash')}</option></select></label>
        <button className="primary" disabled={!f.employee_id || !f.amount}>{t('Give advance')}</button>
      </form>
      {approval.error && <p className="error">{approval.error}</p>}
      {rows.length === 0 ? <Empty title={t('No advances')} /> : <div className="table-wrap"><table className="list compact">
        <thead><tr><th>{t('Employee')}</th><th>{t('Date')}</th><th className="num">{t('Amount')}</th><th className="num">{t('Per month')}</th><th className="num">{t('Still to recover')}</th></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.id}><td>{emps.find((e) => e.id === r.employee_id)?.name}</td><td>{r.given_on}</td><td className="num">{fmt(r.amount, tn, lang)}</td>
          <td className="num">{fmt(r.monthly_deduction, tn, lang)}</td><td className="num">{fmt(r.amount - r.recovered, tn, lang)}</td></tr>)}</tbody></table></div>}
      {approval.dialog}
    </div>
  )
}

function Payroll() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const { rows: emps } = useEmployees()
  const approval = useApproval()
  const [month, setMonth] = useState(new Date().toISOString().slice(0, 7))
  const [run, setRun] = useState<Run | null>(null)
  const [lines, setLines] = useState<PLine[]>([])
  const [slip, setSlip] = useState<PLine | 'all' | null>(null)
  const load = useCallback(async () => {
    const { data } = await supabase.from('payroll_runs').select('*').eq('tenant_id', tn.id).eq('month', `${month}-01`).maybeSingle()
    setRun((data ?? null) as Run | null)
    if (data) { const l = await supabase.from('payroll_lines').select('*').eq('run_id', data.id); setLines((l.data ?? []) as PLine[]) } else setLines([])
  }, [tn.id, month])
  useEffect(() => { void load() }, [load])
  // these functions return nothing: success is "no error"
  const call = async (fn: string, args: Record<string, unknown>) => { const r = await approval.run(() => rpc(fn, args).then(() => true)); if (r) await load() }
  const ename = (id: string) => emps.find((e) => e.id === id)
  const editLine = async (l: PLine, k: 'overtime' | 'other_additions' | 'other_deductions', v: string) => {
    const r = await approval.run(() => rpc('update_payroll_line', { p: { id: l.id, [k]: toMinor(v || '0', d) } }).then(() => true)); if (r) await load()
  }
  function bankFile() {
    const rows = [['Employee', 'Civil ID', 'Bank', 'IBAN', 'Amount', 'Currency', 'Month'],
      ...lines.filter((l) => l.net > 0).map((l) => { const e = ename(l.employee_id); return [e?.name ?? '', e?.civil_id ?? '', e?.bank_name ?? '', e?.iban ?? '', num(l.net, d), tn.currency, month] })]
    const csv = '﻿' + rows.map((r) => r.map((x) => `"${String(x).replace(/"/g, '""')}"`).join(',')).join('\r\n')
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' })); a.download = `salaries-${month}.csv`; a.click()
  }
  const m = (v: number) => num(v, d)
  const Slip = ({ l }: { l: PLine }) => { const e = ename(l.employee_id)
    return (
      <div className="a4-doc payslip">
        <header className="a4-head"><div><h1>{lang === 'ar' && tn.name_ar ? tn.name_ar : tn.name}</h1></div><div><h2>{t('Payslip')}</h2><div>{month}</div></div></header>
        <p><b>{lang === 'ar' && e?.name_ar ? e.name_ar : e?.name}</b>{e?.job_title ? ` · ${e.job_title}` : ''}{e?.civil_id ? ` · ${e.civil_id}` : ''}</p>
        <table className="list compact"><tbody>
          <tr><td>{t('Basic salary')}</td><td className="num">{m(l.basic)}</td></tr><tr><td>{t('Allowances')}</td><td className="num">{m(l.allowances)}</td></tr>
          {l.commission > 0 && <tr><td>{t('Commission')}</td><td className="num">{m(l.commission)}</td></tr>}{l.overtime > 0 && <tr><td>{t('Overtime')}</td><td className="num">{m(l.overtime)}</td></tr>}
          {l.other_additions > 0 && <tr><td>{t('Other additions')}</td><td className="num">{m(l.other_additions)}</td></tr>}
          {l.absence > 0 && <tr><td>{t('Unpaid leave')} ({Number(l.unpaid_days)})</td><td className="num">−{m(l.absence)}</td></tr>}
          {l.advance > 0 && <tr><td>{t('Advance instalment')}</td><td className="num">−{m(l.advance)}</td></tr>}
          {l.other_deductions > 0 && <tr><td>{t('Other deductions')}</td><td className="num">−{m(l.other_deductions)}</td></tr>}
          <tr><td><b>{t('Net pay')}</b></td><td className="num"><b>{fmt(l.net, tn, lang)}</b></td></tr></tbody></table>
        {e?.iban && <p className="muted">{t('Paid to')} {e.bank_name ?? ''} · {e.iban}</p>}
      </div>) }
  return (
    <div className="stack">
      <div className="row wrap">
        <label className="field"><span>{t('Month')}</span><input id="pay-month" type="month" value={month} onChange={(e) => setMonth(e.target.value)} /></label>
        {(!run || run.status === 'draft') && <button onClick={() => void call('prepare_payroll', { p_tenant: tn.id, p_month: `${month}-01` })}>{run ? t('Recalculate') : t('Prepare payroll')}</button>}
        {run?.status === 'draft' && <button className="primary" onClick={() => void call('post_payroll', { p_run: run.id })}>{t('Post to accounts')}</button>}
        {run?.status === 'posted' && <button className="primary" onClick={() => void call('pay_payroll', { p_run: run.id, p_from: 'bank' })}>{t('Mark as paid from the bank')}</button>}
        {run && lines.length > 0 && <><button className="ghost" onClick={bankFile}><Download size={16} />{t('Bank transfer file (CSV)')}</button>
          <button className="ghost" onClick={() => setSlip('all')}><Printer size={16} />{t('Print payslips')}</button></>}
        {run && <span className={`pill ${run.status}`}>{t(run.status)}</span>}
      </div>
      {approval.error && <p className="error">{approval.error}</p>}
      {!run ? <Empty title={t('No payroll for this month yet')} hint={t('Prepare it to bring in salaries, allowances, POS commissions, advance instalments and unpaid leave.')} /> : (
        <div className="table-wrap"><table className="list compact">
          <thead><tr><th>{t('Employee')}</th><th className="num">{t('Basic')}</th><th className="num">{t('Allowances')}</th><th className="num">{t('Commission')}</th><th className="num">{t('Overtime')}</th>
            <th className="num">{t('Other +')}</th><th className="num">{t('Unpaid leave')}</th><th className="num">{t('Advance')}</th><th className="num">{t('Other −')}</th><th className="num">{t('Net')}</th><th /></tr></thead>
          <tbody>{lines.map((l) => <tr key={l.id}><td>{ename(l.employee_id)?.name}</td><td className="num">{m(l.basic)}</td><td className="num">{m(l.allowances)}</td><td className="num">{m(l.commission)}</td>
            {(['overtime', 'other_additions'] as const).map((k) => <td key={k} className="num">{run.status === 'draft' ? <input className="qty-in" aria-label={t(k === 'overtime' ? 'Overtime' : 'Other +')} inputMode="decimal" defaultValue={l[k] ? m(l[k]) : ''} onBlur={(e) => void editLine(l, k, e.target.value)} /> : m(l[k])}</td>)}
            <td className="num">{l.absence ? `−${m(l.absence)}` : ''}</td><td className="num">{l.advance ? `−${m(l.advance)}` : ''}</td>
            <td className="num">{run.status === 'draft' ? <input className="qty-in" aria-label={t('Other −')} inputMode="decimal" defaultValue={l.other_deductions ? m(l.other_deductions) : ''} onBlur={(e) => void editLine(l, 'other_deductions', e.target.value)} /> : m(l.other_deductions)}</td>
            <td className="num"><b>{m(l.net)}</b></td><td><button className="icon" aria-label={t('Payslip')} onClick={() => setSlip(l)}><Printer size={15} /></button></td></tr>)}
            <tr><td><b>{t('Total')}</b></td><td colSpan={8} /><td className="num"><b>{fmt(run.net, tn, lang)}</b></td><td /></tr></tbody>
        </table></div>)}
      {approval.dialog}
      {slip && <PrintDoc paper="a4" onDone={() => setSlip(null)}>{(slip === 'all' ? lines : [slip]).map((l) => <Slip key={l.id} l={l} />)}</PrintDoc>}
    </div>
  )
}

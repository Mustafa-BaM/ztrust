import { Upload } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Empty, useApproval } from '../../components/ui'
import { useT } from '../../lib/i18n'
import { fmt, num, toMinor } from '../../lib/money'
import { useSession } from '../../lib/session'
import { rpc, supabase } from '../../lib/supabase'

const today = () => new Date().toISOString().slice(0, 10)
const monthStart = () => `${today().slice(0, 8)}01`
interface Acc { id: string; code: string; name_en: string; name_ar: string; system_key: string | null; section: string }
function useCashAccounts() {
  const s = useSession()
  const [rows, setRows] = useState<Acc[]>([])
  useEffect(() => { void supabase.from('accounts').select('id, code, name_en, name_ar, system_key, section').eq('tenant_id', s.tenant!.id).eq('section', 'current_asset').eq('is_active', true).order('code').then(({ data }) => setRows((data ?? []) as Acc[])) }, [s.tenant])
  return rows
}
function Range({ r, set }: { r: { from: string; to: string }; set: (r: { from: string; to: string }) => void }) {
  const { t } = useT()
  return <div className="row wrap"><label className="field"><span>{t('From')}</span><input type="date" value={r.from} max={r.to} onChange={(e) => set({ ...r, from: e.target.value })} /></label>
    <label className="field"><span>{t('To')}</span><input type="date" value={r.to} min={r.from} onChange={(e) => set({ ...r, to: e.target.value })} /></label></div>
}

/** Cash flow (direct): every movement of cash, safe, petty cash and bank, by what was on the other side. */
export function CashFlow() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [r, setR] = useState({ from: monthStart(), to: today() })
  const [data, setData] = useState<{ opening: number; closing: number; rows: { activity: string; code: string; name_en: string; name_ar: string; amount: number }[] } | null>(null)
  useEffect(() => { void rpc<typeof data>('fin_cash_flow', { p_tenant: tn.id, p_from: r.from, p_to: r.to, p_branch: null }).then(setData).catch(() => setData(null)) }, [tn.id, r])
  const m = (v: number) => fmt(v, tn, lang)
  const groups = ['operating', 'investing', 'financing'] as const
  const label = { operating: 'Operating activities', investing: 'Investing activities', financing: 'Financing activities' }
  return (
    <div className="stack">
      <Range r={r} set={setR} />
      {data && <div className="panel"><table className="list compact"><tbody>
        <tr><td><b>{t('Cash at the start')}</b></td><td className="num"><b>{m(data.opening)}</b></td></tr>
        {groups.map((g) => { const rows = data.rows.filter((x) => x.activity === g); const sum = rows.reduce((a, x) => a + x.amount, 0)
          return [<tr key={g} className="sub-h-row"><td><b>{t(label[g])}</b></td><td className="num"><b>{m(sum)}</b></td></tr>,
            ...rows.map((x) => <tr key={g + x.code}><td className="indent">{x.code} · {lang === 'ar' ? x.name_ar : x.name_en}</td><td className="num">{m(x.amount)}</td></tr>)] })}
        <tr><td><b>{t('Cash at the end')}</b></td><td className="num"><b>{m(data.closing)}</b></td></tr>
      </tbody></table>
      <p className="muted small">{t('Cash includes the drawer, the safe, petty cash and the bank. When one entry moves cash against several accounts, the cash is shared between them in proportion.')}</p></div>}
    </div>
  )
}

/** Bank reconciliation: import the bank's CSV, match to the ledger (same amount, within 3 days), see what is open on each side. */
export function BankRec() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const accs = useCashAccounts().filter((a) => !['cash', 'ar', 'inventory', 'vat_input', 'prepaid', 'employee_advances'].includes(a.system_key ?? ''))
  const [acc, setAcc] = useState('')
  const [asOf, setAsOf] = useState(today())
  const [data, setData] = useState<{ book_balance: number; statement_total: number; matched: number; unmatched_statement: { id: string; line_date: string; description: string | null; amount: number }[]; unmatched_book: { id: number; date: string; entry_no: number; memo: string | null; reference: string | null; amount: number }[] } | null>(null)
  const approval = useApproval()
  const [msg, setMsg] = useState<string | null>(null)
  useEffect(() => { if (!acc) setAcc(accs.find((a) => a.system_key === 'bank')?.id ?? '') }, [accs, acc])
  const load = useCallback(async () => { if (acc) setData(await rpc<typeof data>('bank_reconciliation', { p_tenant: tn.id, p_account: acc, p_as_of: asOf })) }, [tn.id, acc, asOf])
  useEffect(() => { void load() }, [load])
  async function importCsv(f: File) {
    // date, description, amount  — or date, description, debit, credit (money out, money in)
    const text = await f.text()
    const rows = text.split(/\r?\n/).map((l) => l.split(/[,;\t]/).map((x) => x.replace(/^"|"$/g, '').trim())).filter((c) => /\d{4}-\d{2}-\d{2}|\d{1,2}\/\d{1,2}\/\d{2,4}/.test(c[0] ?? ''))
    const iso = (v: string) => (/^\d{4}-/.test(v) ? v.slice(0, 10) : (() => { const [a, b, c] = v.split('/'); return `${c.length === 2 ? `20${c}` : c}-${b.padStart(2, '0')}-${a.padStart(2, '0')}` })())
    const lines = rows.map((c) => ({ date: iso(c[0]), description: c[1], amount: c.length >= 4 ? toMinor(c[3] || '0', d) - toMinor(c[2] || '0', d) : toMinor(c[2] || '0', d) })).filter((x) => x.amount !== 0)
    const r = await approval.run(() => rpc<{ imported: number; matched: number }>('import_bank_lines', { p_tenant: tn.id, p_account: acc, p_lines: lines }))
    if (r) { setMsg(t('{i} lines imported, {m} matched automatically', { i: r.imported, m: r.matched })); await load() }
  }
  async function match(lineId: string, jl: string) { const r = await approval.run(() => rpc('bank_match', { p_line: lineId, p_journal_line: Number(jl) }).then(() => true)); if (r) await load() }
  const m = (v: number) => fmt(v, tn, lang)
  return (
    <div className="stack">
      <div className="row wrap">
        <label className="field"><span>{t('Account')}</span><select id="br-acc" value={acc} onChange={(e) => setAcc(e.target.value)}>{accs.map((a) => <option key={a.id} value={a.id}>{a.code} · {lang === 'ar' ? a.name_ar : a.name_en}</option>)}</select></label>
        <label className="field"><span>{t('As of')}</span><input id="br-asof" type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} /></label>
        {s.can('finance.journal') && <label className="button"><Upload size={16} />{t('Import bank statement (CSV)')}<input id="br-file" type="file" accept=".csv,.txt" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) void importCsv(f); e.target.value = '' }} /></label>}
      </div>
      <p className="muted small">{t('CSV columns: date, description, amount (+ in, − out) — or date, description, money out, money in.')}</p>
      {msg && <p className="success">{msg}</p>}{approval.error && <p className="error">{approval.error}</p>}
      {data && <>
        <div className="mini-kpis"><div><span>{t('Ledger balance')}</span><b>{m(data.book_balance)}</b></div><div><span>{t('Imported statement total')}</span><b>{m(data.statement_total)}</b></div><div><span>{t('Matched lines')}</span><b>{data.matched}</b></div></div>
        <div className="grid2">
          <section className="panel"><header><h2>{t('On the statement, not in the books')}</h2></header>
            {data.unmatched_statement.length === 0 ? <p className="success">{t('Nothing open')}</p> : <table className="list compact"><tbody>{data.unmatched_statement.map((x) => (
              <tr key={x.id}><td>{x.line_date}</td><td>{x.description}</td><td className="num">{num(x.amount, d)}</td>
                <td>{s.can('finance.journal') && <select aria-label={t('Match to')} defaultValue="" onChange={(e) => e.target.value && void match(x.id, e.target.value)}><option value="">{t('Match to…')}</option>
                  {data.unmatched_book.filter((b) => b.amount === x.amount).map((b) => <option key={b.id} value={b.id}>#{b.entry_no} · {b.date} · {b.reference ?? b.memo}</option>)}</select>}</td></tr>))}</tbody></table>}
            <p className="muted small">{t('Bank charges or interest found here are booked as an expense or a journal, then matched.')}</p></section>
          <section className="panel"><header><h2>{t('In the books, not yet on the statement')}</h2></header>
            {data.unmatched_book.length === 0 ? <p className="success">{t('Nothing open')}</p> : <table className="list compact"><tbody>{data.unmatched_book.slice(0, 100).map((x) => (
              <tr key={x.id}><td>{x.date}</td><td>#{x.entry_no} · {x.reference ?? x.memo}</td><td className="num">{num(x.amount, d)}</td></tr>))}</tbody></table>}</section>
        </div></>}
      {approval.dialog}
    </div>
  )
}

/** Petty cash: balance and movements; top up from the bank or the safe. Spending is recorded under Expenses → paid from petty cash. */
export function Petty() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const accs = useCashAccounts()
  const petty = accs.find((a) => a.system_key === 'petty_cash')
  const approval = useApproval()
  const [r, setR] = useState({ from: monthStart(), to: today() })
  const [rows, setRows] = useState<{ entry_date: string; entry_no: number; memo: string | null; debit: number; credit: number; balance: number }[]>([])
  const [f, setF] = useState({ amount: '', from: 'bank', note: '' })
  const load = useCallback(async () => { if (petty) setRows(await rpc('fin_ledger', { p_tenant: tn.id, p_account: petty.id, p_from: r.from, p_to: r.to })) }, [tn.id, petty, r])
  useEffect(() => { void load() }, [load])
  async function topup() {
    const x = await approval.run(() => rpc('petty_topup', { p: { tenant_id: tn.id, branch_id: s.branch!.id, amount: toMinor(f.amount, tn.currency_decimals), from: f.from, note: f.note || null } }))
    if (x !== null) { setF({ ...f, amount: '', note: '' }); await load() }
  }
  const bal = rows.length ? rows[rows.length - 1].balance : null
  return (
    <div className="stack">
      <div className="row wrap"><Range r={r} set={setR} />{bal != null && <div className="kpi2 slim"><span className="kpi2-label">{t('Petty cash balance')}</span><b className="kpi2-value">{fmt(bal, tn, lang)}</b></div>}</div>
      {s.can('payables.pay') && <form className="card row wrap" onSubmit={(e) => { e.preventDefault(); void topup() }}>
        <label className="field"><span>{t('Top up')}</span><input id="pc-amount" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></label>
        <label className="field"><span>{t('From')}</span><select id="pc-from" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })}><option value="bank">{t('Bank')}</option><option value="cash_safe">{t('Safe')}</option></select></label>
        <label className="field"><span>{t('Note')}</span><input id="pc-note" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></label>
        <button className="primary" disabled={!f.amount}>{t('Top up petty cash')}</button></form>}
      {approval.error && <p className="error">{approval.error}</p>}
      {rows.length === 0 ? <Empty title={t('No petty cash movements in this period')} hint={t('Record spending under Expenses, paid from petty cash.')} /> : (
        <div className="table-wrap"><table className="list compact"><thead><tr><th>{t('Date')}</th><th>{t('Entry')}</th><th>{t('Description')}</th><th className="num">{t('In')}</th><th className="num">{t('Out')}</th><th className="num">{t('Balance')}</th></tr></thead>
          <tbody>{rows.map((x, i) => <tr key={i}><td>{x.entry_date}</td><td>#{x.entry_no}</td><td>{x.memo}</td><td className="num">{x.debit ? num(x.debit, tn.currency_decimals) : ''}</td>
            <td className="num">{x.credit ? num(x.credit, tn.currency_decimals) : ''}</td><td className="num">{num(x.balance, tn.currency_decimals)}</td></tr>)}</tbody></table></div>)}
      {approval.dialog}
    </div>
  )
}

/** Cost centres: one per branch is applied automatically to every posting of that branch; others can be chosen on expenses. */
export function CostCenters() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [rows, setRows] = useState<{ id: string; code: string; name: string; name_ar: string | null; branch_id: string | null; is_active: boolean }[]>([])
  const [f, setF] = useState({ code: '', name: '', name_ar: '', branch_id: '' })
  const [sel, setSel] = useState('')
  const [r, setR] = useState({ from: monthStart(), to: today() })
  const [pl, setPl] = useState<{ section: string; code: string; name_en: string; name_ar: string; amount: number }[]>([])
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => { const { data } = await supabase.from('cost_centers').select('*').eq('tenant_id', tn.id).order('code'); setRows(data ?? []) }, [tn.id])
  useEffect(() => { void load() }, [load])
  useEffect(() => { if (sel) void rpc<typeof pl>('fin_income_statement_cc', { p_tenant: tn.id, p_from: r.from, p_to: r.to, p_cost_center: sel }).then(setPl).catch(() => setPl([])) }, [tn.id, sel, r])
  async function add() {
    const { error } = await supabase.from('cost_centers').insert({ tenant_id: tn.id, code: f.code.trim(), name: f.name.trim(), name_ar: f.name_ar || null, branch_id: f.branch_id || null })
    if (error) setErr(error.message); else { setF({ code: '', name: '', name_ar: '', branch_id: '' }); await load() }
  }
  const income = pl.filter((x) => ['revenue', 'other_income'].includes(x.section)).reduce((a, x) => a + Number(x.amount), 0)
  const cost = pl.filter((x) => !['revenue', 'other_income'].includes(x.section)).reduce((a, x) => a + Number(x.amount), 0)
  return (
    <div className="stack">
      {s.can('finance.manage') && <form className="card row wrap" onSubmit={(e) => { e.preventDefault(); void add() }}>
        <label className="field"><span>{t('Code')}</span><input id="cc-code" value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} placeholder="HW" /></label>
        <label className="field"><span>{t('Name')}</span><input id="cc-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>{t('Name (Arabic)')}</span><input id="cc-name-ar" dir="rtl" value={f.name_ar} onChange={(e) => setF({ ...f, name_ar: e.target.value })} /></label>
        <label className="field"><span>{t('Branch (applied automatically)')}</span><select id="cc-branch" value={f.branch_id} onChange={(e) => setF({ ...f, branch_id: e.target.value })}><option value="">—</option>{s.branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
        <button className="primary" disabled={!f.code.trim() || !f.name.trim()}>{t('Add cost centre')}</button></form>}
      {err && <p className="error">{err}</p>}
      {rows.length === 0 ? <Empty title={t('No cost centres yet')} hint={t('Give each branch or department a cost centre to see its own profit and loss.')} /> : (
        <div className="row wrap">{rows.map((x) => <button key={x.id} className={`chipbtn ${sel === x.id ? 'on' : ''}`} onClick={() => setSel(x.id)}>{x.code} · {lang === 'ar' && x.name_ar ? x.name_ar : x.name}</button>)}</div>)}
      {sel && <><Range r={r} set={setR} />
        <div className="panel"><table className="list compact"><tbody>{pl.map((x) => <tr key={x.code}><td>{x.code} · {lang === 'ar' ? x.name_ar : x.name_en}</td><td className="num">{num(Number(x.amount), tn.currency_decimals)}</td></tr>)}
          <tr><td><b>{t('Profit of this cost centre')}</b></td><td className="num"><b>{fmt(income - cost, tn, lang)}</b></td></tr></tbody></table></div></>}
    </div>
  )
}

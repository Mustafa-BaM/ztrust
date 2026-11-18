import JSZip from 'jszip'
import { CheckCircle2, Download, FilePlus2, Lock, LockOpen, RotateCcw, ShieldAlert, ShieldCheck } from 'lucide-react'
import { Fragment, useCallback, useEffect, useMemo, useState } from 'react'
import { Empty, Modal, useApproval } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt, num as plain, toMinor } from '../lib/money'

/** Display figures with thousands separators; CSV exports use plain() so Excel reads them as numbers. */
const num = (v: number, d: number) => new Intl.NumberFormat('en', { minimumFractionDigits: d, maximumFractionDigits: d }).format(v / 10 ** d)
import { downloadCsv, toCsv } from '../lib/reports'
import { useSession } from '../lib/session'
import { friendly, rpc, supabase } from '../lib/supabase'
import type { Supplier } from '../lib/types'

interface Account { id: string; code: string; name_en: string; name_ar: string; type: string; section: string; system_key: string | null; is_system: boolean; is_active: boolean }
interface Verify { entries: number; first_entry: number | null; last_entry: number | null; hash_mismatches: number; chain_breaks: number; numbering_gaps: number; unbalanced_entries: number; total_debit: number; total_credit: number; problem_entries: number[]; last_hash: string | null; checked_at: string }
interface Line { id: number; account_id: string; debit: number; credit: number; customer_id: string | null; supplier_id: string | null; branch_id: string | null }
interface Entry { id: number; entry_no: number; entry_date: string; source_type: string; source_id: string | null; memo: string | null; reference: string | null; hash: string; prev_hash: string | null; created_at: string; created_by: string | null; approved_by: string | null; reversal_of: number | null; journal_lines: Line[] }
interface Draft { id: string; entry_date: string; memo: string; reference: string | null; total: number; status: string; created_by: string; created_at: string; lines: { account_id: string; debit?: number; credit?: number }[]; review_note: string | null }

const SECTION: Record<string, string> = {
  current_asset: 'Current assets', non_current_asset: 'Non-current assets', contra_asset: 'Accumulated depreciation',
  current_liability: 'Current liabilities', non_current_liability: 'Non-current liabilities', equity: 'Equity',
  revenue: 'Revenue', other_income: 'Other income', cogs: 'Cost of sales', operating_expense: 'Operating expenses', other_expense: 'Other expenses',
}
const SOURCE: Record<string, string> = {
  sale: 'Sale', refund: 'Refund', cancel: 'Cancellation', collection: 'Collection', payment_link: 'Payment link', shift_variance: 'Cash over/short',
  stock_adjustment: 'Stock adjustment', stock_receipt: 'Goods received', goods_receipt: 'Goods received', manual: 'Manual journal', reversal: 'Reversal',
  expense: 'Expense', supplier_payment: 'Supplier payment', opening: 'Opening balance',
}
const today = () => new Date().toISOString().slice(0, 10)
const monthStart = () => today().slice(0, 8) + '01'

function useAccounts(tenantId: string) {
  const [accounts, setAccounts] = useState<Account[]>([])
  const load = useCallback(async () => {
    const { data } = await supabase.from('accounts').select('*').eq('tenant_id', tenantId).order('code')
    setAccounts((data ?? []) as Account[])
  }, [tenantId])
  useEffect(() => { void load() }, [load])
  return { accounts, reload: load }
}

/** Audit-ready accounting: verifiable ledger, maker-checker journals, statements, periods and an exportable audit pack. */
export default function Accounting() {
  const { t } = useT()
  const s = useSession()
  const tabs = [
    { id: 'overview', label: 'Overview', show: s.can('finance.view') },
    { id: 'journal', label: 'Journal', show: s.can('finance.view') || s.can('finance.journal') },
    { id: 'statements', label: 'Statements', show: s.can('finance.view') },
    { id: 'ledger', label: 'Account ledger', show: s.can('finance.view') },
    { id: 'arap', label: 'Receivables & payables', show: s.can('finance.view') || s.can('payables.pay') },
    { id: 'expenses', label: 'Expenses', show: s.can('expenses.create') || s.can('finance.view') },
    { id: 'accounts', label: 'Chart of accounts', show: s.can('finance.view') || s.can('finance.manage') },
    { id: 'periods', label: 'Periods', show: s.can('finance.view') },
  ].filter((x) => x.show)
  const [tab, setTab] = useState(tabs[0]?.id ?? 'expenses')
  return (
    <div className="page">
      <div className="tabs">{tabs.map((x) => <button key={x.id} className={tab === x.id ? 'on' : ''} onClick={() => setTab(x.id)}>{t(x.label)}</button>)}</div>
      {tab === 'overview' && <Overview go={setTab} />}
      {tab === 'journal' && <Journal />}
      {tab === 'statements' && <Statements />}
      {tab === 'ledger' && <Ledger />}
      {tab === 'arap' && <ArAp />}
      {tab === 'expenses' && <Expenses />}
      {tab === 'accounts' && <Accounts />}
      {tab === 'periods' && <Periods />}
    </div>
  )
}

// ---------------------------------------------------------------- overview
function Overview({ go }: { go: (tab: string) => void }) {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [v, setV] = useState<Verify | null>(null)
  const [busy, setBusy] = useState(false)
  const [bal, setBal] = useState<Record<string, number>>({})
  const [vat, setVat] = useState<number | null>(null)
  const [drafts, setDrafts] = useState(0)
  const [closed, setClosed] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const verify = useCallback(async () => { setBusy(true); try { setV(await rpc<Verify>('verify_ledger', { p_tenant: tn.id })) } finally { setBusy(false) } }, [tn.id])
  useEffect(() => {
    void verify()
    void rpc<{ system_key: string | null; closing: number }[]>('fin_trial_balance', { p_tenant: tn.id, p_from: monthStart(), p_to: today(), p_branch: null }).then((rows) => {
      const m: Record<string, number> = {}; for (const r of rows as unknown as Array<Account & { closing: number }>) if (r.code) m[(r as Account).code] = r.closing
      setBal(m)
    })
    void rpc<{ net_vat: number }>('fin_vat_return', { p_tenant: tn.id, p_from: monthStart(), p_to: today() }).then((x) => setVat(x.net_vat))
    void supabase.from('journal_drafts').select('id', { count: 'exact', head: true }).eq('tenant_id', tn.id).eq('status', 'draft').then(({ count }) => setDrafts(count ?? 0))
    void supabase.from('fiscal_periods').select('period_start').eq('tenant_id', tn.id).eq('period_start', monthStart()).then(({ data }) => setClosed((data ?? []).length > 0))
  }, [tn.id, verify])

  const ok = v && v.hash_mismatches + v.chain_breaks + v.numbering_gaps + v.unbalanced_entries === 0
  const cashBank = (bal['1010'] ?? 0) + (bal['1015'] ?? 0) + (bal['1020'] ?? 0)
  const m = (x: number) => fmt(x, tn, lang)

  async function auditPack() {
    setMsg(t('Preparing audit pack…'))
    try { await buildAuditPack(tn.id, tn.name, tn.currency_decimals, v); setMsg(t('Audit pack downloaded')) } catch (e) { setMsg((e as Error).message) }
  }

  return (
    <div className="acc-overview">
      <section className={`panel integrity ${ok ? 'ok' : v ? 'bad' : ''}`}>
        <header>
          <div className="row">{ok ? <ShieldCheck size={26} /> : <ShieldAlert size={26} />}
            <div><h2>{v ? (ok ? t('Ledger verified') : t('Ledger problems found')) : t('Checking ledger…')}</h2>
              <p className="muted small">{t('Every entry is numbered without gaps and sealed with a SHA-256 hash chained to the previous entry.')}</p></div></div>
          <button onClick={() => void verify()} disabled={busy}>{busy ? t('Please wait…') : t('Verify again')}</button>
        </header>
        {v && (
          <dl className="checks">
            <div><dt>{t('Entries')}</dt><dd>{v.entries}{v.first_entry ? ` · JV-${v.first_entry} → JV-${v.last_entry}` : ''}</dd></div>
            <div className={v.hash_mismatches ? 'bad' : ''}><dt>{t('Altered entries')}</dt><dd>{v.hash_mismatches}</dd></div>
            <div className={v.chain_breaks ? 'bad' : ''}><dt>{t('Chain breaks')}</dt><dd>{v.chain_breaks}</dd></div>
            <div className={v.numbering_gaps ? 'bad' : ''}><dt>{t('Numbering gaps')}</dt><dd>{v.numbering_gaps}</dd></div>
            <div className={v.unbalanced_entries ? 'bad' : ''}><dt>{t('Unbalanced entries')}</dt><dd>{v.unbalanced_entries}</dd></div>
            <div><dt>{t('Debits = credits')}</dt><dd>{num(v.total_debit, tn.currency_decimals)} = {num(v.total_credit, tn.currency_decimals)}</dd></div>
            <div className="span-all"><dt>{t('Latest hash')}</dt><dd className="mono">{v.last_hash ? `${v.last_hash.slice(0, 24)}…` : '—'}</dd></div>
          </dl>
        )}
        {v && !ok && <p className="error">{t('Problem entries')}: {v.problem_entries.map((n) => `JV-${n}`).join(', ')}</p>}
      </section>

      <div className="acc-kpis">
        <button className="kpi2" onClick={() => go('ledger')}><span className="kpi2-label">{t('Cash and bank')}</span><b className="kpi2-value">{m(cashBank)}</b></button>
        <button className="kpi2" onClick={() => go('arap')}><span className="kpi2-label">{t('Receivables')}</span><b className="kpi2-value">{m(bal['1100'] ?? 0)}</b></button>
        <button className="kpi2" onClick={() => go('arap')}><span className="kpi2-label">{t('Payables')}</span><b className="kpi2-value">{m(Math.max(0, -(bal['2010'] ?? 0)) || 0)}</b></button>
        <button className="kpi2" onClick={() => go('statements')}><span className="kpi2-label">{vat != null && vat < 0 ? t('VAT refundable this month') : t('VAT due this month')}</span><b className="kpi2-value">{vat == null ? '…' : m(Math.abs(vat))}</b></button>
      </div>

      <section className="panel">
        <header><h2>{t('Month-end checklist')}</h2><span className={`pill ${closed ? '' : 'warn'}`}>{closed ? t('Closed') : t('Open')}</span></header>
        <ul className="checklist">
          <li className={ok ? 'done' : ''}><CheckCircle2 size={18} />{t('Ledger verifies with no breaks')}</li>
          <li className={drafts === 0 ? 'done' : ''}><CheckCircle2 size={18} />{drafts === 0 ? t('No draft journals waiting') : t('{n} draft journals waiting for approval', { n: drafts })}
            {drafts > 0 && <button className="link" onClick={() => go('journal')}>{t('Review')}</button>}</li>
          <li><CheckCircle2 size={18} />{t('Review the exceptions report and the cash over/short')}</li>
          <li className={closed ? 'done' : ''}><CheckCircle2 size={18} />{t('Close the period so nothing can be posted into it')}
            {!closed && s.can('finance.close') && <button className="link" onClick={() => go('periods')}>{t('Close')}</button>}</li>
        </ul>
        <div className="row end">
          {msg && <span className="muted small">{msg}</span>}
          <button className="primary" onClick={() => void auditPack()}><Download size={17} />{t('Download audit pack')}</button>
        </div>
      </section>
    </div>
  )
}

async function buildAuditPack(tenantId: string, name: string, d: number, v: Verify | null) {
  const n = (x: number) => (x / 10 ** d).toFixed(d)
  const [acc, ent, aud, tb] = await Promise.all([
    supabase.from('accounts').select('*').eq('tenant_id', tenantId).order('code'),
    supabase.from('journal_entries').select('*, journal_lines(*)').eq('tenant_id', tenantId).order('entry_no').limit(100000),
    supabase.from('audit_log').select('*').eq('tenant_id', tenantId).order('id').limit(100000),
    rpc<Array<{ code: string; name_en: string; opening: number; debit: number; credit: number; closing: number }>>('fin_trial_balance', { p_tenant: tenantId, p_from: '1900-01-01', p_to: today(), p_branch: null }),
  ])
  const accounts = (acc.data ?? []) as Account[]
  const byId = new Map(accounts.map((a) => [a.id, a]))
  const lines: Record<string, unknown>[] = []
  for (const e of (ent.data ?? []) as Entry[]) for (const l of e.journal_lines.sort((a, b) => a.id - b.id)) {
    lines.push({ entry_no: e.entry_no, entry_date: e.entry_date, source: e.source_type, memo: e.memo ?? '', reference: e.reference ?? '',
      account_code: byId.get(l.account_id)?.code, account_name: byId.get(l.account_id)?.name_en, debit: n(l.debit), credit: n(l.credit),
      branch_id: l.branch_id ?? '', customer_id: l.customer_id ?? '', supplier_id: l.supplier_id ?? '', created_at: e.created_at,
      created_by: e.created_by ?? '', approved_by: e.approved_by ?? '', reversal_of: e.reversal_of ?? '', prev_hash: e.prev_hash ?? '', hash: e.hash })
  }
  const zip = new JSZip()
  zip.file('journal_lines.csv', toCsv(lines))
  zip.file('trial_balance.csv', toCsv(tb.map((r) => ({ code: r.code, account: r.name_en, opening: n(r.opening), debit: n(r.debit), credit: n(r.credit), closing: n(r.closing) }))))
  zip.file('chart_of_accounts.csv', toCsv(accounts.map((a) => ({ code: a.code, name_en: a.name_en, name_ar: a.name_ar, type: a.type, section: a.section, system: a.is_system, active: a.is_active }))))
  zip.file('audit_log.csv', toCsv(((aud.data ?? []) as Record<string, unknown>[]).map((r) => ({ ...r, meta: JSON.stringify(r.meta) }))))
  zip.file('verification.json', JSON.stringify(v, null, 2))
  zip.file('README.txt', [
    `Z Trust audit pack · ${name} · generated ${new Date().toISOString()}`, '',
    'journal_lines.csv  every posted line with its entry number, source document, approver and hash',
    'trial_balance.csv  all-time trial balance (debits equal credits)',
    'chart_of_accounts.csv, audit_log.csv (discounts, refunds, cancellations, approvals, period close/reopen)', '',
    'Hash chain: each entry hash = SHA-256 of prev_hash|tenant|entry_no|entry_date|source|source_id|memo|reference|approved_by|reversal_of|created_at(UTC)|lines',
    'where lines = account_id:debit:credit:branch:customer:supplier joined by ";" in posting order.',
    'Entry numbers are gapless; posted entries and lines cannot be edited or deleted; corrections are reversing entries or credit notes.',
  ].join('\n'))
  const blob = await zip.generateAsync({ type: 'blob' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a'); a.href = url; a.download = `z-trust-audit-pack-${today()}.zip`; a.click()
  setTimeout(() => URL.revokeObjectURL(url), 2000)
}

// ---------------------------------------------------------------- journal
function Journal() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const { accounts } = useAccounts(tn.id)
  const byId = useMemo(() => new Map(accounts.map((a) => [a.id, a])), [accounts])
  const aname = (id: string) => { const a = byId.get(id); return a ? `${a.code} · ${lang === 'ar' ? a.name_ar : a.name_en}` : '…' }
  const [from, setFrom] = useState(monthStart()); const [to, setTo] = useState(today())
  const [entries, setEntries] = useState<Entry[]>([])
  const [drafts, setDrafts] = useState<Draft[]>([])
  const [open, setOpen] = useState<number | null>(null)
  const [people, setPeople] = useState<Record<string, string>>({})
  const [form, setForm] = useState(false)
  const [reverse, setReverse] = useState<Entry | null>(null)
  const [reject, setReject] = useState<Draft | null>(null)
  const approval = useApproval()

  const load = useCallback(async () => {
    const [e, dr, mb] = await Promise.all([
      s.can('finance.view') ? supabase.from('journal_entries').select('*, journal_lines(*)').eq('tenant_id', tn.id).gte('entry_date', from).lte('entry_date', to).order('entry_no', { ascending: false }).limit(300) : Promise.resolve({ data: [] }),
      supabase.from('journal_drafts').select('*').eq('tenant_id', tn.id).order('created_at', { ascending: false }).limit(50),
      supabase.from('memberships').select('user_id, display_name').eq('tenant_id', tn.id),
    ])
    setEntries((e.data ?? []) as Entry[]); setDrafts((dr.data ?? []) as Draft[])
    const m: Record<string, string> = {}; for (const x of mb.data ?? []) m[x.user_id] = x.display_name; setPeople(m)
  }, [tn.id, from, to, s])
  useEffect(() => { void load() }, [load])

  async function post(dr: Draft) {
    const r = await approval.run((pin) => rpc<number>('post_journal_draft', { p_id: dr.id, p_pin: pin ?? null }))
    if (r !== null) await load()
  }
  const pending = drafts.filter((x) => x.status === 'draft')

  return (
    <div className="stack">
      {pending.length > 0 && (
        <section className="panel warn-panel">
          <header><h2>{t('Waiting for approval')} <span className="badge-count">{pending.length}</span></h2></header>
          <div className="table-wrap"><table className="list">
            <thead><tr><th>{t('Date')}</th><th>{t('Description')}</th><th>{t('Prepared by')}</th><th className="num">{t('Amount')}</th><th /></tr></thead>
            <tbody>{pending.map((dr) => (
              <tr key={dr.id}><td>{dr.entry_date}</td><td>{dr.memo}{dr.reference ? <span className="muted small"> · {dr.reference}</span> : null}
                <div className="muted small">{dr.lines.map((l) => `${aname(l.account_id)} ${l.debit ? 'Dr ' + num(l.debit, d) : 'Cr ' + num(l.credit ?? 0, d)}`).join(' / ')}</div></td>
                <td>{people[dr.created_by] ?? '…'}</td><td className="num">{num(dr.total, d)}</td>
                <td className="row end">{s.can('finance.post') && <button className="ghost small" onClick={() => setReject(dr)}>{t('Reject')}</button>}
                  <button className="primary small" onClick={() => void post(dr)}>{t('Approve and post')}</button></td></tr>))}</tbody>
          </table></div>
          <p className="muted small">{t('The person who prepared a journal cannot post it. Another approver enters their PIN.')}</p>
        </section>
      )}
      <div className="filters">
        <label className="field"><span>{t('From')}</span><input id="jv-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="field"><span>{t('To')}</span><input id="jv-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label>
        <div className="grow" />
        {s.can('finance.journal') && <button className="primary" onClick={() => setForm(true)}><FilePlus2 size={17} />{t('New journal entry')}</button>}
      </div>
      {approval.error && <p className="error">{approval.error}</p>}
      {!s.can('finance.view') ? null : entries.length === 0 ? <Empty title={t('No journal entries in this period')} /> : (
        <div className="table-wrap"><table className="list jv">
          <thead><tr><th>{t('No.')}</th><th>{t('Date')}</th><th>{t('Source')}</th><th>{t('Description')}</th><th className="num">{t('Amount')}</th><th>{t('Hash')}</th></tr></thead>
          <tbody>{entries.map((e) => {
            const total = e.journal_lines.reduce((a, l) => a + l.debit, 0)
            return (
              <Fragment key={e.id}>
                <tr tabIndex={0} onClick={() => setOpen(open === e.id ? null : e.id)} onKeyDown={(k) => { if (k.key === 'Enter') setOpen(open === e.id ? null : e.id) }} className={open === e.id ? 'open' : ''}>
                  <td className="mono">JV-{e.entry_no}</td><td>{e.entry_date}</td>
                  <td><span className={`pill src-${e.source_type}`}>{t(SOURCE[e.source_type] ?? e.source_type)}</span></td>
                  <td>{e.memo}{e.reference && <span className="muted small"> · {e.reference}</span>}{e.reversal_of && <span className="muted small"> · {t('reverses')} #{e.reversal_of}</span>}</td>
                  <td className="num">{num(total, d)}</td><td className="mono muted small">{e.hash?.slice(0, 10)}</td>
                </tr>
                {open === e.id && (
                  <tr className="jv-detail"><td colSpan={6}>
                    <table className="list compact"><tbody>{e.journal_lines.sort((a, b) => a.id - b.id).map((l) => (
                      <tr key={l.id}><td className={l.credit ? 'indent' : ''}>{aname(l.account_id)}</td><td className="num">{l.debit ? num(l.debit, d) : ''}</td><td className="num">{l.credit ? num(l.credit, d) : ''}</td></tr>))}</tbody></table>
                    <div className="row between wrap small muted">
                      <span>{t('Posted')} {new Date(e.created_at).toLocaleString()} · {people[e.created_by ?? ''] ?? t('System')}{e.approved_by ? ` · ${t('Approved by')} ${people[e.approved_by] ?? '…'}` : ''}</span>
                      {e.source_type === 'manual' && s.can('finance.post') && <button className="ghost small" onClick={() => setReverse(e)}><RotateCcw size={15} />{t('Reverse')}</button>}
                    </div>
                  </td></tr>)}
              </Fragment>)
          })}</tbody>
        </table></div>
      )}
      {drafts.some((x) => x.status === 'rejected') && (
        <details className="panel"><summary>{t('Rejected journals')}</summary>
          <ul className="plain">{drafts.filter((x) => x.status === 'rejected').map((x) => <li key={x.id}>{x.entry_date} · {x.memo} · <span className="bad">{x.review_note}</span></li>)}</ul>
        </details>)}
      {form && <JournalForm accounts={accounts} onClose={() => setForm(false)} onSaved={async () => { setForm(false); await load() }} />}
      {reverse && <ReasonDialog title={`${t('Reverse')} JV-${reverse.entry_no}`} date onClose={() => setReverse(null)}
        onSubmit={async (reason, date) => { const r = await approval.run(() => rpc('reverse_entry', { p_entry: reverse.id, p_date: date, p_reason: reason })); if (r !== null) { setReverse(null); await load() } }} />}
      {reject && <ReasonDialog title={t('Reject journal')} onClose={() => setReject(null)}
        onSubmit={async (reason) => { const r = await approval.run(() => rpc('reject_journal_draft', { p_id: reject.id, p_note: reason }).then(() => true)); if (r) { setReject(null); await load() } }} />}
      {approval.dialog}
    </div>
  )
}

function ReasonDialog({ title, date, onSubmit, onClose }: { title: string; date?: boolean; onSubmit: (reason: string, date: string) => void; onClose: () => void }) {
  const { t } = useT()
  const [reason, setReason] = useState(''); const [dt, setDt] = useState(today())
  return (
    <Modal title={title} onClose={onClose}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); if (reason.trim()) onSubmit(reason.trim(), dt) }}>
        {date && <label className="field"><span>{t('Date')}</span><input id="rd-date" type="date" value={dt} onChange={(e) => setDt(e.target.value)} /></label>}
        <label className="field"><span>{t('Reason (required)')}</span><input id="rd-reason" autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></label>
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!reason.trim()}>{t('Confirm')}</button></div>
      </form>
    </Modal>
  )
}

function JournalForm({ accounts, onClose, onSaved }: { accounts: Account[]; onClose: () => void; onSaved: () => void }) {
  const { t, lang } = useT()
  const s = useSession()
  const d = s.tenant!.currency_decimals
  const [f, setF] = useState({ date: today(), memo: '', reference: '' })
  const [lines, setLines] = useState([{ account_id: '', debit: '', credit: '' }, { account_id: '', debit: '', credit: '' }])
  const [err, setErr] = useState<string | null>(null)
  const dr = lines.reduce((a, l) => a + (toMinor(l.debit || '0', d) || 0), 0), cr = lines.reduce((a, l) => a + (toMinor(l.credit || '0', d) || 0), 0)
  const set = (i: number, p: Partial<(typeof lines)[number]>) => setLines(lines.map((l, j) => (j === i ? { ...l, ...p } : l)))
  const active = accounts.filter((a) => a.is_active)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try {
      await rpc('save_journal_draft', { p: { tenant_id: s.tenant!.id, branch_id: s.branch?.id ?? null, entry_date: f.date, memo: f.memo, reference: f.reference,
        lines: lines.filter((l) => l.account_id && (l.debit || l.credit)).map((l) => l.debit ? { account_id: l.account_id, debit: toMinor(l.debit, d) } : { account_id: l.account_id, credit: toMinor(l.credit, d) }) } })
      onSaved()
    } catch (x) { setErr(t(friendly((x as Error).message))) }
  }
  return (
    <Modal title={t('New journal entry')} onClose={onClose} wide>
      <form className="stack" onSubmit={save}>
        <div className="grid2">
          <label className="field"><span>{t('Date')}</span><input id="jf-date" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label className="field"><span>{t('Reference (document number)')}</span><input id="jf-ref" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></label>
          <label className="field span2"><span>{t('Description')}</span><input id="jf-memo" required value={f.memo} onChange={(e) => setF({ ...f, memo: e.target.value })} placeholder={t('e.g. Opening balances, monthly depreciation, accrued rent')} /></label>
        </div>
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Account')}</th><th className="num">{t('Debit')}</th><th className="num">{t('Credit')}</th><th /></tr></thead>
          <tbody>{lines.map((l, i) => (
            <tr key={i}>
              <td><select id={`jf-acc-${i}`} value={l.account_id} onChange={(e) => set(i, { account_id: e.target.value })}><option value="">—</option>
                {active.map((a) => <option key={a.id} value={a.id}>{a.code} · {lang === 'ar' ? a.name_ar : a.name_en}</option>)}</select></td>
              <td><input id={`jf-dr-${i}`} className="qty-in" inputMode="decimal" value={l.debit} onChange={(e) => set(i, { debit: e.target.value, credit: e.target.value ? '' : l.credit })} /></td>
              <td><input id={`jf-cr-${i}`} className="qty-in" inputMode="decimal" value={l.credit} onChange={(e) => set(i, { credit: e.target.value, debit: e.target.value ? '' : l.debit })} /></td>
              <td>{lines.length > 2 && <button type="button" className="icon" aria-label={t('Remove')} onClick={() => setLines(lines.filter((_, j) => j !== i))}>✕</button>}</td>
            </tr>))}</tbody>
          <tfoot><tr><td><button type="button" className="ghost small" onClick={() => setLines([...lines, { account_id: '', debit: '', credit: '' }])}>{t('Add line')}</button></td>
            <td className="num"><b>{num(dr, d)}</b></td><td className="num"><b>{num(cr, d)}</b></td><td /></tr></tfoot>
        </table></div>
        <p className={dr === cr && dr > 0 ? 'success' : 'muted'}>{dr === cr && dr > 0 ? t('Balanced') : t('Difference') + ': ' + num(Math.abs(dr - cr), d)}</p>
        <p className="muted small">{t('Saved as a draft. Another approver posts it; posted entries cannot be edited, only reversed.')}</p>
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={dr !== cr || dr === 0 || !f.memo.trim()}>{t('Save draft')}</button></div>
      </form>
    </Modal>
  )
}

// ---------------------------------------------------------------- statements
type StatementKind = 'pl' | 'bs' | 'tb' | 'vat'
function Statements() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [kind, setKind] = useState<StatementKind>('pl')
  const [from, setFrom] = useState(monthStart()); const [to, setTo] = useState(today())
  const [branch, setBranch] = useState('')
  const [rows, setRows] = useState<Array<Record<string, unknown>>>([])
  const [vat, setVat] = useState<Record<string, number> | null>(null)
  const name = (r: Record<string, unknown>) => String(lang === 'ar' ? r.name_ar : r.name_en)
  const n = (v: number) => num(v, d)
  const p = (v: number) => plain(v, d)

  useEffect(() => {
    setRows([]); setVat(null)
    if (kind === 'pl') void rpc<Array<Record<string, unknown>>>('fin_income_statement', { p_tenant: tn.id, p_from: from, p_to: to, p_branch: branch || null }).then(setRows)
    if (kind === 'bs') void rpc<Array<Record<string, unknown>>>('fin_balance_sheet', { p_tenant: tn.id, p_as_of: to }).then(setRows)
    if (kind === 'tb') void rpc<Array<Record<string, unknown>>>('fin_trial_balance', { p_tenant: tn.id, p_from: from, p_to: to, p_branch: branch || null }).then(setRows)
    if (kind === 'vat') void rpc<Record<string, number>>('fin_vat_return', { p_tenant: tn.id, p_from: from, p_to: to }).then(setVat)
  }, [kind, from, to, branch, tn.id])

  const sumOf = (secs: string[]) => rows.filter((r) => secs.includes(String(r.section))).reduce((a, r) => a + Number(r.amount ?? 0), 0)
  const block = (secs: string[]) => rows.filter((r) => secs.includes(String(r.section)))
  const exportRows = () => kind === 'tb'
    ? rows.map((r) => ({ code: r.code, account: name(r), opening: p(Number(r.opening)), debit: p(Number(r.debit)), credit: p(Number(r.credit)), closing: p(Number(r.closing)) }))
    : kind === 'vat' ? [Object.fromEntries(Object.entries(vat ?? {}).map(([k, v]) => [k, p(Number(v))]))]
    : rows.map((r) => ({ section: t(SECTION[String(r.section)] ?? String(r.section)), code: r.code, account: name(r), amount: p(Number(r.amount)) }))

  const Section = ({ title, secs, sign = 1 }: { title: string; secs: string[]; sign?: number }) => {
    const list = block(secs)
    if (!list.length) return null
    return (
      <>
        <tr className="st-sec"><td colSpan={2}>{title}</td></tr>
        {list.map((r) => <tr key={String(r.code)}><td className="indent"><span className="mono muted">{String(r.code)}</span> {name(r)}</td><td className="num">{n(sign * Number(r.amount))}</td></tr>)}
      </>
    )
  }
  const Total = ({ label, value, strong }: { label: string; value: number; strong?: boolean }) =>
    <tr className={`st-total ${strong ? 'strong' : ''}`}><td>{label}</td><td className="num">{n(value)}</td></tr>

  const revenue = sumOf(['revenue']), cogs = sumOf(['cogs']), opex = sumOf(['operating_expense']), oi = sumOf(['other_income']), oe = sumOf(['other_expense'])
  const gross = revenue - cogs, operating = gross - opex, net = operating + oi - oe
  const assets = sumOf(['current_asset', 'non_current_asset', 'contra_asset']), liab = sumOf(['current_liability', 'non_current_liability']), eq = sumOf(['equity'])

  return (
    <div className="stack">
      <div className="filters">
        <div className="seg">{([['pl', 'Income statement'], ['bs', 'Balance sheet'], ['tb', 'Trial balance'], ['vat', 'VAT return']] as const).map(([k, l]) =>
          <button key={k} className={kind === k ? 'on' : ''} onClick={() => setKind(k)}>{t(l)}</button>)}</div>
        {kind !== 'bs' && <label className="field"><span>{t('From')}</span><input id="st-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>}
        <label className="field"><span>{kind === 'bs' ? t('As of') : t('To')}</span><input id="st-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label>
        {(kind === 'pl' || kind === 'tb') && s.branches.length > 1 && <label className="field"><span>{t('Branch')}</span>
          <select id="st-branch" value={branch} onChange={(e) => setBranch(e.target.value)}><option value="">{t('All branches')}</option>{s.branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>}
        <button onClick={() => downloadCsv(`z-trust-${kind}-${from}-${to}.csv`, exportRows() as Record<string, unknown>[])}><Download size={16} />{t('Export CSV')}</button>
      </div>

      <section className="panel statement">
        <header className="st-head"><div><h2>{t({ pl: 'Income statement', bs: 'Balance sheet', tb: 'Trial balance', vat: 'VAT return' }[kind])}</h2>
          <p className="muted small">{lang === 'ar' && tn.name_ar ? tn.name_ar : tn.name} · {kind === 'bs' ? `${t('As of')} ${to}` : `${from} → ${to}`} · {tn.currency}</p></div></header>
        {kind === 'pl' && (rows.length === 0 ? <Empty title={t('No activity in this period')} /> : (
          <table className="list st"><tbody>
            <Section title={t('Revenue')} secs={['revenue']} />
            <Section title={t('Cost of sales')} secs={['cogs']} />
            <Total label={`${t('Gross profit')}${revenue ? ` · ${Math.round((gross / revenue) * 1000) / 10}%` : ''}`} value={gross} />
            <Section title={t('Operating expenses')} secs={['operating_expense']} />
            <Total label={t('Operating profit')} value={operating} />
            <Section title={t('Other income')} secs={['other_income']} />
            <Section title={t('Other expenses')} secs={['other_expense']} />
            <Total label={t('Net profit')} value={net} strong />
          </tbody></table>))}
        {kind === 'bs' && (rows.length === 0 ? <Empty title={t('No balances yet')} /> : (
          <table className="list st"><tbody>
            <Section title={t('Current assets')} secs={['current_asset']} />
            <Section title={t('Non-current assets')} secs={['non_current_asset', 'contra_asset']} />
            <Total label={t('Total assets')} value={assets} strong />
            <Section title={t('Current liabilities')} secs={['current_liability']} />
            <Section title={t('Non-current liabilities')} secs={['non_current_liability']} />
            <Total label={t('Total liabilities')} value={liab} />
            <Section title={t('Equity')} secs={['equity']} />
            <Total label={t('Total equity')} value={eq} />
            <Total label={t('Total liabilities and equity')} value={liab + eq} strong />
            <tr className={`st-check ${assets === liab + eq ? 'good' : 'bad'}`}><td colSpan={2}>{assets === liab + eq ? `✓ ${t('Balanced')}` : `✗ ${t('Out of balance by')} ${n(assets - liab - eq)}`}</td></tr>
          </tbody></table>))}
        {kind === 'tb' && (
          <div className="table-wrap"><table className="list st-tb">
            <thead><tr><th>{t('Account')}</th><th className="num">{t('Opening')}</th><th className="num">{t('Debit')}</th><th className="num">{t('Credit')}</th><th className="num">{t('Closing debit')}</th><th className="num">{t('Closing credit')}</th></tr></thead>
            <tbody>{rows.filter((r) => Number(r.opening) || Number(r.debit) || Number(r.credit) || Number(r.closing)).map((r) => (
              <tr key={String(r.code)}><td><span className="mono muted">{String(r.code)}</span> {name(r)}</td><td className="num">{n(Number(r.opening))}</td><td className="num">{n(Number(r.debit))}</td><td className="num">{n(Number(r.credit))}</td>
                <td className="num">{Number(r.closing) > 0 ? n(Number(r.closing)) : ''}</td><td className="num">{Number(r.closing) < 0 ? n(-Number(r.closing)) : ''}</td></tr>))}</tbody>
            <tfoot><tr className="st-total strong"><td>{t('Total')}</td><td /><td className="num">{n(rows.reduce((a, r) => a + Number(r.debit), 0))}</td><td className="num">{n(rows.reduce((a, r) => a + Number(r.credit), 0))}</td>
              <td className="num">{n(rows.reduce((a, r) => a + Math.max(0, Number(r.closing)), 0))}</td><td className="num">{n(rows.reduce((a, r) => a + Math.max(0, -Number(r.closing)), 0))}</td></tr></tfoot>
          </table></div>)}
        {kind === 'vat' && vat && (
          <table className="list st"><tbody>
            <tr className="st-sec"><td colSpan={2}>{t('Sales')}</td></tr>
            <tr><td className="indent">{t('Taxable sales (net)')}</td><td className="num">{n(vat.sales_net)}</td></tr>
            <tr><td className="indent">{t('Output VAT')}</td><td className="num">{n(vat.output_vat)}</td></tr>
            <tr className="st-sec"><td colSpan={2}>{t('Purchases and expenses')}</td></tr>
            <tr><td className="indent">{t('Expenses (net)')}</td><td className="num">{n(vat.expenses_net)}</td></tr>
            <tr><td className="indent">{t('Stock purchases (net)')}</td><td className="num">{n(vat.purchases_net)}</td></tr>
            <tr><td className="indent">{t('Input VAT')}</td><td className="num">{n(vat.input_vat)}</td></tr>
            <Total label={vat.net_vat >= 0 ? t('VAT payable') : t('VAT refundable')} value={Math.abs(vat.net_vat)} strong />
          </tbody></table>)}
      </section>
    </div>
  )
}

// ---------------------------------------------------------------- ledger
function Ledger() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const { accounts } = useAccounts(tn.id)
  const [acc, setAcc] = useState('')
  const [from, setFrom] = useState(monthStart()); const [to, setTo] = useState(today())
  const [rows, setRows] = useState<Array<{ entry_no: number | null; entry_date: string; source_type: string; memo: string; reference: string | null; debit: number | null; credit: number | null; balance: number; party: string | null }>>([])
  useEffect(() => { if (!acc && accounts.length) setAcc(accounts.find((a) => a.system_key === 'cash')?.id ?? accounts[0].id) }, [accounts, acc])
  useEffect(() => { if (acc) void rpc<typeof rows>('fin_ledger', { p_tenant: tn.id, p_account: acc, p_from: from, p_to: to }).then(setRows) }, [acc, from, to, tn.id])
  const a = accounts.find((x) => x.id === acc)
  return (
    <div className="stack">
      <div className="filters">
        <label className="field grow"><span>{t('Account')}</span><select id="lg-acc" value={acc} onChange={(e) => setAcc(e.target.value)}>
          {accounts.map((x) => <option key={x.id} value={x.id}>{x.code} · {lang === 'ar' ? x.name_ar : x.name_en}</option>)}</select></label>
        <label className="field"><span>{t('From')}</span><input id="lg-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="field"><span>{t('To')}</span><input id="lg-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label>
        <button onClick={() => downloadCsv(`ledger-${a?.code}-${from}-${to}.csv`, rows.map((r) => ({ entry: r.entry_no ? `JV-${r.entry_no}` : '', date: r.entry_date, source: r.source_type, description: r.memo, reference: r.reference ?? '', party: r.party ?? '', debit: r.debit ? plain(r.debit, d) : '', credit: r.credit ? plain(r.credit, d) : '', balance: plain(r.balance, d) })))}><Download size={16} />{t('Export CSV')}</button>
      </div>
      <div className="table-wrap"><table className="list">
        <thead><tr><th>{t('Date')}</th><th>{t('No.')}</th><th>{t('Description')}</th><th>{t('Party')}</th><th className="num">{t('Debit')}</th><th className="num">{t('Credit')}</th><th className="num">{t('Balance')}</th></tr></thead>
        <tbody>{rows.map((r, i) => (
          <tr key={i} className={r.entry_no == null ? 'st-sec' : ''}><td>{r.entry_date}</td><td className="mono">{r.entry_no ? `JV-${r.entry_no}` : ''}</td>
            <td>{r.entry_no == null ? t('Opening balance') : <>{t(SOURCE[r.source_type] ?? r.source_type)} · {r.memo}</>}{r.reference && <span className="muted small"> · {r.reference}</span>}</td>
            <td>{r.party}</td><td className="num">{r.debit ? num(r.debit, d) : ''}</td><td className="num">{r.credit ? num(r.credit, d) : ''}</td><td className="num"><b>{num(r.balance, d)}</b></td></tr>))}</tbody>
      </table></div>
    </div>
  )
}

// ---------------------------------------------------------------- receivables & payables
function ArAp() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [asOf, setAsOf] = useState(today())
  const [ar, setAr] = useState<AgingRow[]>([]); const [ap, setAp] = useState<AgingRow[]>([])
  const [pay, setPay] = useState<AgingRow | null>(null)
  const load = useCallback(async () => {
    if (!s.can('finance.view')) return
    setAr(await rpc<AgingRow[]>('fin_aging', { p_tenant: tn.id, p_kind: 'ar', p_as_of: asOf }))
    setAp(await rpc<AgingRow[]>('fin_aging', { p_tenant: tn.id, p_kind: 'ap', p_as_of: asOf }))
  }, [tn.id, asOf, s])
  useEffect(() => { void load() }, [load])
  const Table = ({ rows, kind }: { rows: AgingRow[]; kind: 'ar' | 'ap' }) => rows.length === 0 ? <Empty title={kind === 'ar' ? t('No customer balances') : t('Nothing owed to suppliers')} /> : (
    <div className="table-wrap"><table className="list">
      <thead><tr><th>{kind === 'ar' ? t('Customer') : t('Supplier')}</th><th className="num">0–30</th><th className="num">31–60</th><th className="num">61–90</th><th className="num">90+</th><th className="num">{t('Total')}</th>{kind === 'ap' && <th />}</tr></thead>
      <tbody>{rows.map((r) => (
        <tr key={r.party_id ?? r.party}><td>{r.party}</td><td className="num">{r.d0_30 ? num(r.d0_30, d) : ''}</td><td className="num">{r.d31_60 ? num(r.d31_60, d) : ''}</td>
          <td className="num">{r.d61_90 ? num(r.d61_90, d) : ''}</td><td className={`num ${r.d90_plus ? 'bad' : ''}`}>{r.d90_plus ? num(r.d90_plus, d) : ''}</td><td className="num"><b>{num(r.total, d)}</b></td>
          {kind === 'ap' && <td>{s.can('payables.pay') && r.party_id && <button className="primary small" onClick={() => setPay(r)}>{t('Pay')}</button>}</td>}</tr>))}</tbody>
      <tfoot><tr className="st-total"><td>{t('Total')}</td><td className="num">{num(rows.reduce((a, r) => a + (r.d0_30 ?? 0), 0), d)}</td><td className="num">{num(rows.reduce((a, r) => a + (r.d31_60 ?? 0), 0), d)}</td>
        <td className="num">{num(rows.reduce((a, r) => a + (r.d61_90 ?? 0), 0), d)}</td><td className="num">{num(rows.reduce((a, r) => a + (r.d90_plus ?? 0), 0), d)}</td><td className="num"><b>{num(rows.reduce((a, r) => a + r.total, 0), d)}</b></td>{kind === 'ap' && <td />}</tr></tfoot>
    </table></div>)
  return (
    <div className="stack">
      <div className="filters"><label className="field"><span>{t('As of')}</span><input id="ag-asof" type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} /></label>
        <p className="muted small grow">{t('Aged by document date; payments settle the oldest items first.')}</p></div>
      <section className="panel"><header><h2>{t('Receivables (customers owe us)')}</h2><b>{fmt(ar.reduce((a, r) => a + r.total, 0), tn, lang)}</b></header><Table rows={ar} kind="ar" /></section>
      <section className="panel"><header><h2>{t('Payables (we owe suppliers)')}</h2><b>{fmt(ap.reduce((a, r) => a + r.total, 0), tn, lang)}</b></header><Table rows={ap} kind="ap" /></section>
      {pay && <PayForm row={pay} onClose={() => setPay(null)} onDone={async () => { setPay(null); await load() }} />}
    </div>
  )
}
interface AgingRow { party_id: string | null; party: string; total: number; d0_30: number | null; d31_60: number | null; d61_90: number | null; d90_plus: number | null }

function PayForm({ row, onClose, onDone }: { row: AgingRow; onClose: () => void; onDone: () => void }) {
  const { t } = useT()
  const s = useSession()
  const d = s.tenant!.currency_decimals
  const [f, setF] = useState({ amount: plain(row.total, d), from: 'bank', reference: '', date: today() })
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try { await rpc('pay_supplier', { p: { tenant_id: s.tenant!.id, branch_id: s.branch!.id, supplier_id: row.party_id, amount: toMinor(f.amount, d), paid_from: f.from, reference: f.reference, entry_date: f.date } }); onDone() }
    catch (x) { setErr((x as Error).message) }
  }
  return (
    <Modal title={`${t('Pay')} ${row.party}`} onClose={onClose}>
      <form className="stack" onSubmit={save}>
        <label className="field"><span>{t('Amount')}</span><input id="pay-sup-amount" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></label>
        <div className="seg"><button type="button" className={f.from === 'bank' ? 'on' : ''} onClick={() => setF({ ...f, from: 'bank' })}>{t('Bank')}</button><button type="button" className={f.from === 'cash' ? 'on' : ''} onClick={() => setF({ ...f, from: 'cash' })}>{t('Cash')}</button></div>
        <label className="field"><span>{t('Transfer / cheque reference')}</span><input id="pay-sup-ref" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></label>
        <label className="field"><span>{t('Date')}</span><input id="pay-sup-date" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Record payment')}</button></div>
      </form>
    </Modal>
  )
}

// ---------------------------------------------------------------- expenses
function Expenses() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const { accounts } = useAccounts(tn.id)
  const [rows, setRows] = useState<Array<{ id: string; entry_date: string; description: string; amount: number; vat: number; total: number; paid_from: string; reference: string | null; account_id: string }>>([])
  const [suppliers, setSuppliers] = useState<Supplier[]>([])
  const [open, setOpen] = useState(false)
  const load = useCallback(async () => {
    const { data } = await supabase.from('expenses').select('*').eq('tenant_id', tn.id).order('entry_date', { ascending: false }).limit(200)
    setRows((data ?? []) as typeof rows)
  }, [tn.id])
  useEffect(() => { void load(); void supabase.from('suppliers').select('*').eq('tenant_id', tn.id).eq('is_active', true).then(({ data }) => setSuppliers((data ?? []) as Supplier[])) }, [load, tn.id])
  const expenseAccounts = accounts.filter((a) => a.is_active && ['operating_expense', 'other_expense', 'cogs', 'non_current_asset'].includes(a.section) && a.system_key !== 'inventory')
  const an = (id: string) => { const a = accounts.find((x) => x.id === id); return a ? (lang === 'ar' ? a.name_ar : a.name_en) : '' }
  return (
    <div className="stack">
      <div className="row between"><p className="muted small">{t('Every expense posts to the ledger with its input VAT and payment source.')}</p>
        {s.can('expenses.create') && <button className="primary" onClick={() => setOpen(true)}><FilePlus2 size={17} />{t('Record expense')}</button>}</div>
      {rows.length === 0 ? <Empty title={t('No expenses recorded')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Date')}</th><th>{t('Description')}</th><th>{t('Account')}</th><th>{t('Paid from')}</th><th className="num">{t('Net')}</th><th className="num">{t('VAT')}</th><th className="num">{t('Total')}</th></tr></thead>
          <tbody>{rows.map((r) => <tr key={r.id}><td>{r.entry_date}</td><td>{r.description}{r.reference && <span className="muted small"> · {r.reference}</span>}</td><td>{an(r.account_id)}</td>
            <td>{t({ cash: 'Cash', petty_cash: 'Petty cash', bank: 'Bank', ap: 'Unpaid bill' }[r.paid_from] ?? r.paid_from)}</td>
            <td className="num">{num(r.amount, d)}</td><td className="num">{num(r.vat, d)}</td><td className="num"><b>{num(r.total, d)}</b></td></tr>)}</tbody>
        </table></div>)}
      {open && <ExpenseForm accounts={expenseAccounts} suppliers={suppliers} onClose={() => setOpen(false)} onSaved={async () => { setOpen(false); await load() }} />}
    </div>
  )
}

function ExpenseForm({ accounts, suppliers, onClose, onSaved }: { accounts: Account[]; suppliers: Supplier[]; onClose: () => void; onSaved: () => void }) {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [f, setF] = useState({ account_id: accounts.find((a) => a.code === '6100')?.id ?? '', description: '', total: '', withVat: tn.vat_rate > 0, paid_from: 'bank', supplier_id: '', reference: '', date: today() })
  const [err, setErr] = useState<string | null>(null)
  const gross = toMinor(f.total || '0', d) || 0
  const vat = f.withVat ? Math.round((gross * tn.vat_rate) / (100 + tn.vat_rate)) : 0
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try {
      await rpc('record_expense', { p: { tenant_id: tn.id, branch_id: s.branch!.id, entry_date: f.date, account_id: f.account_id, description: f.description, amount: gross - vat, vat,
        paid_from: f.paid_from, supplier_id: f.supplier_id || null, reference: f.reference } })
      onSaved()
    } catch (x) { setErr((x as Error).message) }
  }
  return (
    <Modal title={t('Record expense')} onClose={onClose}>
      <form className="stack" onSubmit={save}>
        <label className="field"><span>{t('Account')}</span><select id="ex-acc" required value={f.account_id} onChange={(e) => setF({ ...f, account_id: e.target.value })}>
          <option value="">—</option>{accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {lang === 'ar' ? a.name_ar : a.name_en}</option>)}</select></label>
        <label className="field"><span>{t('Description')}</span><input id="ex-desc" required value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} /></label>
        <div className="grid2">
          <label className="field"><span>{t('Total paid')}</span><input id="ex-total" inputMode="decimal" required value={f.total} onChange={(e) => setF({ ...f, total: e.target.value })} /></label>
          <label className="field"><span>{t('Date')}</span><input id="ex-date" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
        </div>
        {tn.vat_rate > 0 && <label className="check"><input id="ex-vat" type="checkbox" checked={f.withVat} onChange={(e) => setF({ ...f, withVat: e.target.checked })} />{t('Includes VAT {r}% (tax invoice received)', { r: tn.vat_rate })}</label>}
        <p className="muted small">{t('Net')} {num(gross - vat, d)} · {t('VAT')} {num(vat, d)}</p>
        <div className="seg">{(['bank', 'cash', 'petty_cash', 'ap'] as const).map((k) => <button type="button" key={k} className={f.paid_from === k ? 'on' : ''} onClick={() => setF({ ...f, paid_from: k })}>{t({ cash: 'Cash', petty_cash: 'Petty cash', bank: 'Bank', ap: 'Unpaid bill' }[k])}</button>)}</div>
        {(f.paid_from === 'ap' || suppliers.length > 0) && <label className="field"><span>{t('Supplier')}{f.paid_from === 'ap' ? '' : ` (${t('optional')})`}</span>
          <select id="ex-sup" value={f.supplier_id} required={f.paid_from === 'ap'} onChange={(e) => setF({ ...f, supplier_id: e.target.value })}><option value="">—</option>{suppliers.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></label>}
        <label className="field"><span>{t('Invoice / receipt number')}</span><input id="ex-ref" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></label>
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!gross}>{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

// ---------------------------------------------------------------- chart of accounts
function Accounts() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const { accounts, reload } = useAccounts(tn.id)
  const [f, setF] = useState({ code: '', name_en: '', name_ar: '', section: 'operating_expense' })
  const [err, setErr] = useState<string | null>(null)
  const typeOf: Record<string, string> = { current_asset: 'asset', non_current_asset: 'asset', contra_asset: 'asset', current_liability: 'liability', non_current_liability: 'liability',
    equity: 'equity', revenue: 'income', other_income: 'income', cogs: 'expense', operating_expense: 'expense', other_expense: 'expense' }
  async function add(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    const r = await supabase.from('accounts').insert({ tenant_id: tn.id, code: f.code.trim(), name_en: f.name_en.trim(), name_ar: f.name_ar.trim() || f.name_en.trim(), section: f.section, type: typeOf[f.section] })
    if (r.error) setErr(r.error.message); else { setF({ ...f, code: '', name_en: '', name_ar: '' }); await reload() }
  }
  const sections = Object.keys(SECTION)
  return (
    <div className="stack">
      {sections.map((sec) => {
        const list = accounts.filter((a) => a.section === sec)
        if (!list.length) return null
        return (
          <section key={sec} className="panel">
            <header><h2>{t(SECTION[sec])}</h2><span className="muted small">{list.length}</span></header>
            <table className="list compact"><tbody>{list.map((a) => (
              <tr key={a.id} className={a.is_active ? '' : 'dim'}><td className="mono">{a.code}</td><td>{lang === 'ar' ? a.name_ar : a.name_en}<span className="muted small"> · {lang === 'ar' ? a.name_en : a.name_ar}</span></td>
                <td>{a.is_system ? <span className="pill">{t('System')}</span> : <span className="pill warn">{t('custom')}</span>}</td>
                <td className="num">{s.can('finance.manage') && <label className="check"><input id={`acc-act-${a.id}`} type="checkbox" checked={a.is_active} onChange={async (e) => { await supabase.from('accounts').update({ is_active: e.target.checked }).eq('id', a.id); await reload() }} />{t('Active')}</label>}</td></tr>))}</tbody></table>
          </section>)
      })}
      {s.can('finance.manage') && (
        <form className="panel grid2" onSubmit={add}>
          <h2 className="span2">{t('Add account')}</h2>
          <label className="field"><span>{t('Code')}</span><input id="na-code" required pattern="[0-9]{3,6}" value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} placeholder="6950" /></label>
          <label className="field"><span>{t('Statement section')}</span><select id="na-sec" value={f.section} onChange={(e) => setF({ ...f, section: e.target.value })}>{sections.map((x) => <option key={x} value={x}>{t(SECTION[x])}</option>)}</select></label>
          <label className="field"><span>{t('Name (English)')}</span><input id="na-en" required value={f.name_en} onChange={(e) => setF({ ...f, name_en: e.target.value })} /></label>
          <label className="field"><span>{t('Name (Arabic)')}</span><input id="na-ar" dir="rtl" value={f.name_ar} onChange={(e) => setF({ ...f, name_ar: e.target.value })} /></label>
          {err && <p className="error span2">{err}</p>}
          <div className="row end span2"><button className="primary">{t('Add account')}</button></div>
        </form>)}
    </div>
  )
}

// ---------------------------------------------------------------- periods
function Periods() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [closed, setClosed] = useState<Record<string, { closed_at: string; closed_by: string }>>({})
  const [people, setPeople] = useState<Record<string, string>>({})
  const [reopen, setReopen] = useState<{ y: number; m: number } | null>(null)
  const approval = useApproval()
  const load = useCallback(async () => {
    const [p, mb] = await Promise.all([supabase.from('fiscal_periods').select('*').eq('tenant_id', tn.id), supabase.from('memberships').select('user_id, display_name').eq('tenant_id', tn.id)])
    const m: Record<string, { closed_at: string; closed_by: string }> = {}; for (const r of p.data ?? []) m[r.period_start] = r; setClosed(m)
    const pp: Record<string, string> = {}; for (const r of mb.data ?? []) pp[r.user_id] = r.display_name; setPeople(pp)
  }, [tn.id])
  useEffect(() => { void load() }, [load])
  const months = Array.from({ length: 12 }, (_, i) => { const d = new Date(); d.setDate(1); d.setMonth(d.getMonth() - i); return { y: d.getFullYear(), m: d.getMonth() + 1, current: i === 0, key: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01` } })
  return (
    <div className="stack">
      <p className="muted small">{t('A closed period accepts no new entries from any source. Only finished months can be closed; only the owner can reopen one, with a reason kept in the audit log.')}</p>
      {approval.error && <p className="error">{approval.error}</p>}
      <div className="periods">
        {months.map((p) => {
          const c = closed[p.key]
          return (
            <div key={p.key} className={`period ${c ? 'closed' : ''}`}>
              <div className="period-name">{new Date(p.y, p.m - 1, 1).toLocaleDateString(lang === 'ar' ? 'ar-u-nu-latn' : 'en-GB', { month: 'long', year: 'numeric' })}</div>
              <div className="period-state">{c ? <><Lock size={15} />{t('Closed')}</> : p.current ? <><LockOpen size={15} />{t('In progress')}</> : <><LockOpen size={15} />{t('Open')}</>}</div>
              {c && <div className="muted small">{people[c.closed_by] ?? '…'} · {new Date(c.closed_at).toLocaleDateString()}</div>}
              {!c && !p.current && s.can('finance.close') && <button className="small" onClick={async () => { const r = await approval.run(() => rpc('close_period', { p_tenant: tn.id, p_year: p.y, p_month: p.m }).then(() => true)); if (r) await load() }}>{t('Close period')}</button>}
              {c && s.role === 'owner' && <button className="ghost small" onClick={() => setReopen(p)}>{t('Reopen')}</button>}
            </div>)
        })}
      </div>
      {reopen && <ReasonDialog title={t('Reopen period')} onClose={() => setReopen(null)}
        onSubmit={async (reason) => { const r = await approval.run(() => rpc('reopen_period', { p_tenant: tn.id, p_year: reopen.y, p_month: reopen.m, p_reason: reason }).then(() => true)); if (r) { setReopen(null); await load() } }} />}
      {approval.dialog}
    </div>
  )
}

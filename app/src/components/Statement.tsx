import { Printer } from 'lucide-react'
import { useEffect, useState } from 'react'
import { useT } from '../lib/i18n'
import { fmt, num } from '../lib/money'
import { useSession } from '../lib/session'
import { rpc } from '../lib/supabase'
import { PrintDoc } from './PrintDoc'

interface Row { date: string; entry_no: number; source: string; ref: string | null; memo: string | null; debit: number; credit: number; balance: number }
const SOURCE: Record<string, string> = {
  sale: 'Invoice', refund: 'Credit note', cancel: 'Cancelled invoice', payment: 'Payment received', debit_note: 'Debit note', goods_receipt: 'Goods received',
  supplier_invoice: 'Supplier invoice', purchase_return: 'Return to supplier', supplier_payment: 'Payment to supplier', expense: 'Bill', manual: 'Journal',
  link_paid: 'Payment link paid', exchange_payout: 'Exchange',
}

/** Statement of account for a customer (AR) or supplier (AP): opening, every posting with a running balance, closing. Prints on A4. */
export function Statement({ kind, partyId, partyName }: { kind: 'ar' | 'ap'; partyId: string; partyName: string }) {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const today = new Date().toISOString().slice(0, 10)
  const [range, setRange] = useState({ from: `${today.slice(0, 4)}-01-01`, to: today })
  const [data, setData] = useState<{ opening: number; closing: number; rows: Row[] } | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [printing, setPrinting] = useState(false)
  useEffect(() => {
    setErr(null)
    rpc<{ opening: number; closing: number; rows: Row[] }>('party_statement', { p_tenant: tn.id, p_kind: kind, p_party: partyId, p_from: range.from, p_to: range.to })
      .then(setData).catch((e) => setErr((e as Error).message))
  }, [tn.id, kind, partyId, range])
  const label = kind === 'ar' ? t('Customer owes') : t('We owe the supplier')
  const table = data && (
    <table className="list compact">
      <thead><tr><th>{t('Date')}</th><th>{t('Document')}</th><th>{t('Reference')}</th><th className="num">{t('Debit')}</th><th className="num">{t('Credit')}</th><th className="num">{t('Balance')}</th></tr></thead>
      <tbody>
        <tr className="muted"><td>{range.from}</td><td colSpan={4}>{t('Opening balance')}</td><td className="num">{num(data.opening, d)}</td></tr>
        {data.rows.map((r, i) => <tr key={i}><td>{r.date}</td><td>{t(SOURCE[r.source] ?? r.source)}</td><td>{r.ref ?? r.memo ?? ''}</td>
          <td className="num">{r.debit ? num(r.debit, d) : ''}</td><td className="num">{r.credit ? num(r.credit, d) : ''}</td><td className="num">{num(r.balance, d)}</td></tr>)}
        <tr><td colSpan={5}><b>{t('Closing balance')}</b></td><td className="num"><b>{num(data.closing, d)}</b></td></tr>
      </tbody>
    </table>)
  return (
    <div className="stack">
      <div className="row wrap">
        <label className="field"><span>{t('From')}</span><input id={`st-from-${kind}`} type="date" value={range.from} max={range.to} onChange={(e) => setRange({ ...range, from: e.target.value })} /></label>
        <label className="field"><span>{t('To')}</span><input id={`st-to-${kind}`} type="date" value={range.to} min={range.from} onChange={(e) => setRange({ ...range, to: e.target.value })} /></label>
        {data && <div className="kpi2 slim"><span className="kpi2-label">{label}</span><b className="kpi2-value">{fmt(data.closing, tn, lang)}</b></div>}
        <button className="ghost" disabled={!data} onClick={() => setPrinting(true)}><Printer size={16} />{t('Print statement')}</button>
      </div>
      {err && <p className="error">{err}</p>}
      {data && (data.rows.length === 0 && data.opening === 0 ? <p className="muted">{t('No postings in this period.')}</p> : <div className="table-wrap">{table}</div>)}
      {printing && data && (
        <PrintDoc paper="a4" onDone={() => setPrinting(false)}>
          <div className="a4-doc">
            <header className="a4-head"><div><h1>{lang === 'ar' && tn.name_ar ? tn.name_ar : tn.name}</h1>{tn.tax_number && <div>{t('Tax number')}: {tn.tax_number}</div>}</div>
              <div><h2>{t('Statement of account')}</h2><div>{partyName}</div><div>{range.from} → {range.to}</div></div></header>
            {table}
            <p className="a4-foot">{label}: <b>{fmt(data.closing, tn, lang)}</b></p>
          </div>
        </PrintDoc>)}
    </div>
  )
}

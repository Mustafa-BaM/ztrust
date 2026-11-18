import { useEffect, useState } from 'react'
import { tenderLabel } from '../components/Receipt'
import { Empty } from '../components/ui'
import { useT } from '../lib/i18n'
import { num } from '../lib/money'
import * as R from '../lib/reports'
import { useSession } from '../lib/session'

type Tab = 'daily' | 'items' | 'tenders' | 'cashiers' | 'kitchen' | 'channels' | 'exceptions' | 'vat' | 'tb'

/** Every figure in minor units is shown in the tenant currency; every tab exports to CSV for Excel. */
export default function Reports() {
  const { t, lang } = useT()
  const s = useSession()
  const tenant = s.tenant!
  const d = tenant.currency_decimals
  const [tab, setTab] = useState<Tab>('daily')
  const [{ from, to }, setRange] = useState(R.rangeFor('month'))
  const [branch, setBranch] = useState<string>('')
  const [rows, setRows] = useState<Record<string, unknown>[] | null>(null)
  const [extra, setExtra] = useState<R.KitchenRow[]>([])
  const costs = s.can('reports.costs')

  const tabs: { id: Tab; label: string; show: boolean }[] = [
    { id: 'daily', label: 'Sales by day', show: true },
    { id: 'items', label: 'Items', show: true },
    { id: 'tenders', label: 'Payments', show: true },
    { id: 'cashiers', label: 'Cashiers', show: true },
    { id: 'kitchen', label: 'Kitchen times', show: s.has('kitchen') },
    { id: 'channels', label: 'Sales channels', show: s.has('delivery') },
    { id: 'exceptions', label: 'Exceptions', show: s.can('reports.exceptions') },
    { id: 'vat', label: 'VAT', show: true },
    { id: 'tb', label: 'Trial balance', show: s.can('finance.view') },
  ]

  useEffect(() => {
    const r: R.Range = { from, to, branchId: branch || null }
    const m = (v: number) => num(v, d)
    setRows(null)
    void (async () => {
      switch (tab) {
        case 'daily': setRows((await R.daily(r)).map((x) => ({ [t('Day')]: x.day, [t('Invoices')]: x.invoices, [t('Gross sales')]: m(x.gross_sales), [t('Discounts')]: m(x.discounts), [t('Refunds')]: m(x.refunds), [t('Net sales')]: m(x.net_sales), [t('VAT')]: m(x.tax) }))); break
        case 'items': setRows((await R.itemSales(r)).map((x) => ({ [t('Item')]: x.name, [t('Qty')]: Number(x.qty), [t('Sales')]: m(x.total), [t('Net')]: m(x.net),
          ...(costs ? { [t('Cost')]: m(x.cost), [t('Margin')]: m(x.net - x.cost), [t('Margin %')]: x.net ? `${Math.round(((x.net - x.cost) / x.net) * 1000) / 10}%` : '—' } : {}) }))); break
        case 'tenders': setRows((await R.tenders(r)).map((x) => ({ [t('Payment method')]: tenderLabel(x.tender, lang), [t('Status')]: t(x.status), [t('Count')]: x.count, [t('Amount')]: m(x.amount) }))); break
        case 'cashiers': setRows((await R.cashiers(r)).map((x) => ({ [t('Cashier')]: x.cashier, [t('Invoices')]: x.invoices, [t('Sales')]: m(x.sales), [t('Discounts')]: m(x.discounts), [t('Refunds')]: m(x.refunds) }))); break
        case 'kitchen': {
          const rows = await R.kitchenTimes(r)
          const sum = R.kitchenSummary(rows)
          setRows(sum.map((x) => ({ [t('Station')]: x.station === '*' ? t('All stations') : x.station, [t('Tickets')]: x.tickets, [t('Average wait')]: R.mmss(x.wait), [t('Average preparation')]: R.mmss(x.prep),
            [t('Average order time')]: R.mmss(x.total), [t('Average pickup')]: R.mmss(x.pickup), [t('On time')]: x.onTime == null ? '—' : `${x.onTime}%`, [t('Late')]: x.lateCount,
            [t('Slowest')]: x.slowest ? `${x.slowest.order_ref} · ${R.mmss(x.slowest.total_s)}` : '—' })))
          setExtra(rows); break
        }
        case 'channels': setRows((await R.channelSales(r)).map((x) => ({ [t('Channel')]: x.channel === 'In store' ? t('In store') : x.channel, [t('Orders')]: x.orders, [t('Net sales')]: m(x.net_sales) }))); break
        case 'exceptions': setRows((await R.exceptions(r)).map((x) => ({ [t('Time')]: new Date(x.created_at).toLocaleString(), [t('Action')]: t(R.ACTION_LABEL[x.action] ?? x.action), [t('By')]: x.user_name, [t('Approved by')]: x.approver_name ?? '', [t('Reason')]: x.reason ?? '', [t('Amount')]: x.amount != null ? m(x.amount) : '' }))); break
        case 'vat': {
          const dd = await R.daily(r)
          const tot = dd.reduce((a, x) => ({ g: a.g + x.net_sales, v: a.v + x.tax }), { g: 0, v: 0 })
          setRows([{ [t('Period')]: `${from} → ${to}`, [t('VAT rate')]: `${tenant.vat_rate}%`, [t('Sales incl. VAT')]: m(tot.g), [t('Sales excl. VAT')]: m(tot.g - tot.v), [t('Output VAT')]: m(tot.v) }]); break
        }
        case 'tb': setRows((await R.trialBalance(tenant.id)).map((x) => ({ [t('Code')]: x.code, [t('Account')]: lang === 'ar' ? x.name_ar : x.name_en, [t('Debit')]: m(x.debit), [t('Credit')]: m(x.credit), [t('Balance')]: m(x.balance) }))); break
      }
    })()
  }, [tab, from, to, branch, d, t, lang, costs, tenant.id, tenant.vat_rate])

  const cols = rows?.[0] ? Object.keys(rows[0]) : []
  return (
    <div className="page">
      <h1>{t('Reports')}</h1>
      <div className="tabs">{tabs.filter((x) => x.show).map((x) => <button key={x.id} className={tab === x.id ? 'on' : ''} onClick={() => setTab(x.id)}>{t(x.label)}</button>)}</div>
      <div className="filters">
        <label className="field"><span>{t('From')}</span><input id="rep-from" type="date" value={from} onChange={(e) => setRange({ from: e.target.value, to })} /></label>
        <label className="field"><span>{t('To')}</span><input id="rep-to" type="date" value={to} onChange={(e) => setRange({ from, to: e.target.value })} /></label>
        <label className="field"><span>{t('Branch')}</span>
          <select id="rep-branch" value={branch} onChange={(e) => setBranch(e.target.value)}>
            <option value="">{t('All branches')}</option>{s.branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select></label>
        <button disabled={!rows?.length} onClick={() => R.downloadCsv(`z-trust-${tab}-${from}-${to}.csv`, rows ?? [])}>{t('Export CSV')}</button>
      </div>
      {tab === 'tb' && <p className="muted small">{t('All time, all branches. Debits must equal credits.')}</p>}
      {tab === 'kitchen' && extra.length > 0 && <KitchenHours rows={extra} />}
      {rows === null ? <p className="muted">{t('Loading…')}</p> : rows.length === 0 ? <Empty title={t('No data for this period')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr>{cols.map((c) => <th key={c}>{c}</th>)}</tr></thead>
          <tbody>{rows.map((r, i) => <tr key={i}>{cols.map((c) => <td key={c} className={typeof r[c] === 'number' || /^-?[\d.]+%?$/.test(String(r[c])) ? 'num' : ''}>{String(r[c] ?? '')}</td>)}</tr>)}</tbody>
        </table></div>
      )}
    </div>
  )
}

/** Average order time by hour of day with late orders highlighted: shows when the kitchen falls behind. */
function KitchenHours({ rows }: { rows: R.KitchenRow[] }) {
  const { t } = useT()
  const byHour = new Map<number, R.KitchenRow[]>()
  for (const r of rows) if (r.total_s != null) byHour.set(r.hour, [...(byHour.get(r.hour) ?? []), r])
  const real = [...byHour.keys()].sort((a, b) => a - b)
  if (!real.length) return null
  let lo = real[0], hi = real[real.length - 1]
  while (hi - lo < 7) { if (lo > 0) lo--; if (hi - lo < 7 && hi < 23) hi++; if (lo === 0 && hi === 23) break }
  const hours = Array.from({ length: hi - lo + 1 }, (_, i) => lo + i)
  const avgOf = (h: number) => { const l = byHour.get(h); return l ? l.reduce((a, b) => a + (b.total_s ?? 0), 0) / l.length : 0 }
  const max = Math.max(...hours.map(avgOf), 60)
  return (
    <section className="panel">
      <header><h2>{t('Average order time by hour')}</h2><span className="muted small">{t('Red: hours with late orders')}</span></header>
      <div className="bars" role="img" aria-label={t('Average order time by hour')}>
        {hours.map((h) => { const l = byHour.get(h) ?? []; const late = l.filter((x) => x.late).length
          return <div key={h} className="bar" title={`${h}:00 · ${R.mmss(avgOf(h))} · ${l.length} ${t('Tickets')} · ${late} ${t('Late')}`}>
            <i style={{ height: `${l.length ? Math.max(3, (avgOf(h) / max) * 100) : 0}%`, background: late ? 'var(--bad)' : 'var(--accent)' }} /><span>{h}</span></div> })}
      </div>
    </section>
  )
}

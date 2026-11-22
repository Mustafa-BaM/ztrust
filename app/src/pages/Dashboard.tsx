import { AlertTriangle, ArrowDown, ArrowUp, ArrowUpRight, EyeOff, GripVertical, Plus, RotateCcw, SlidersHorizontal, Table2 } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { AreaChart, Delta, Donut, HBars, Heatmap, Sparkline, type SeriesPoint, type Slice } from '../components/charts'
import { tenderLabel } from '../components/Receipt'
import { Empty } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt } from '../lib/money'
import * as R from '../lib/reports'
import { useSession } from '../lib/session'
import { getShift } from '../lib/shift'
import { usePrefs } from '../lib/prefs'
import { rpc, supabase } from '../lib/supabase'

export const WIDGETS: { id: string; label: string; perm?: string; feature?: string }[] = [
  { id: 'alerts', label: 'Needs attention' },
  { id: 'kpis', label: 'Sales summary' },
  { id: 'profit', label: 'Profit', perm: 'reports.costs' },
  { id: 'hourly', label: 'Sales trend' },
  { id: 'tenders', label: 'Payment methods' },
  { id: 'heatmap', label: 'Busy hours' },
  { id: 'top_items', label: 'Top items' },
  { id: 'cashiers', label: 'Sales by cashier', perm: 'reports.all' },
  { id: 'exceptions', label: 'Exceptions (voids, refunds, discounts)', perm: 'reports.exceptions' },
  { id: 'stock', label: 'Out of stock' },
  { id: 'my_shift', label: 'My shift' },
  { id: 'kitchen', label: 'Kitchen now', perm: 'kds.view', feature: 'kitchen' },
]

export const DEFAULT_LAYOUT: Record<string, string[]> = {
  owner: ['alerts', 'kitchen', 'kpis', 'profit', 'hourly', 'tenders', 'heatmap', 'top_items', 'cashiers', 'exceptions', 'stock'],
  manager: ['alerts', 'kitchen', 'kpis', 'profit', 'hourly', 'tenders', 'heatmap', 'top_items', 'cashiers', 'exceptions', 'stock'],
  supervisor: ['my_shift', 'alerts', 'kitchen', 'kpis', 'hourly', 'top_items', 'stock'],
  cashier: ['my_shift'],
  accountant: ['kpis', 'hourly', 'tenders', 'exceptions'],
  staff: [], waiter: [], kitchen: [],
  purchasing: ['stock'], storekeeper: ['stock'], hr: [],
  auditor: ['kpis', 'hourly', 'tenders', 'cashiers', 'exceptions'],
}
export const layoutFor = (role: string | null) => DEFAULT_LAYOUT[role ?? ''] ?? ['my_shift']

type Preset = 'today' | '7d' | '30d' | 'month' | 'custom'
type Metric = 'net' | 'orders' | 'avg' | 'refunds'
const ACTION_ICON: Record<string, string> = { 'sale.refund': '↩', 'sale.cancel': '✕', 'sale.discount': '%', 'shift.variance': '≠', 'drawer.no_sale': '⊡' }

interface Data {
  cur: R.DailyRow[]; prev: R.DailyRow[]; hours: R.HourDayRow[]; prevHours: R.HourDayRow[]; tenders: R.TenderRow[]
  items: R.ItemRow[]; cashiers: R.CashierRow[]; exceptions: R.ExceptionRow[]; stock: { name: string; qty: number }[]
  shift: { sales_total: number; invoices: number; refunds_total: number } | null
  profit: { gross: number; prevGross: number; net_sales: number; net: number | null } | null
}

/** Interactive dashboard: the owner chooses widgets per role; every number respects the viewer's permissions. */
export default function Dashboard() {
  const { t, lang } = useT()
  const s = useSession()
  const tenant = s.tenant!
  const [preset, setPreset] = useState<Preset>('7d')
  const [allBranches, setAllBranches] = useState(s.can('reports.all'))
  const [compare, setCompare] = useState(true)
  const [metric, setMetric] = useState<Metric>('net')
  const [asTable, setAsTable] = useState(false)
  const [widgets, setWidgets] = useState<string[]>(layoutFor(s.role))
  const [data, setData] = useState<Data | null>(null)
  const { prefs, set } = usePrefs()
  const [editing, setEditing] = useState(false)
  const [custom, setCustom] = useState(() => { const d = new Date(); const f = new Date(d); f.setDate(f.getDate() - 13); return { from: f.toISOString().slice(0, 10), to: d.toISOString().slice(0, 10) } })

  useEffect(() => {
    if (!s.role) return
    void supabase.from('dashboard_layouts').select('widgets').eq('tenant_id', tenant.id).eq('role', s.role).maybeSingle()
      .then(({ data: l }) => { if (l?.widgets) setWidgets(l.widgets as string[]) })
  }, [tenant.id, s.role])
  const visible = (prefs.dashboard ? prefs.dashboard.order.filter((w) => !prefs.dashboard!.hidden.includes(w)) : widgets).filter((w) => { const def = WIDGETS.find((x) => x.id === w); return def && (!def.perm || s.can(def.perm)) })

  const range = useMemo(() => (preset === 'custom' ? { from: custom.from, to: custom.to } : R.rangeFor(preset)), [preset, custom])
  const prevRange = useMemo(() => R.previousRange(range.from, range.to), [range])

  useEffect(() => {
    const branchId = allBranches ? null : s.branch?.id ?? null
    const cur: R.Range = { ...range, branchId }, prv: R.Range = { from: prevRange.from, to: prevRange.to, branchId }
    const shiftId = getShift(s.branch?.id, s.session?.user.id)
    const need = (w: string) => visible.includes(w)
    let live = true
    void (async () => {
      const wantProfit = need('profit') && s.can('reports.costs')
      const [c, p, h, ph, tn, it, cs, ex, st, sh, pit, pprev, inc] = await Promise.all([
        need('kpis') || need('hourly') ? R.daily(cur) : [], need('kpis') || need('hourly') ? R.daily(prv) : [],
        need('hourly') || need('heatmap') ? R.hourlyByDay(cur) : [], need('hourly') && preset === 'today' ? R.hourlyByDay(prv) : [],
        need('tenders') ? R.tenders(cur) : [], need('top_items') ? R.itemSales(cur) : [], need('cashiers') ? R.cashiers(cur) : [],
        need('exceptions') ? R.exceptions(cur) : [], need('stock') && s.branch ? outOfStock(tenant.id, s.branch.id) : [],
        need('my_shift') && shiftId ? rpc<Data['shift']>('shift_summary', { p_shift: shiftId }).catch(() => null) : null,
        wantProfit ? R.itemSales(cur) : [], wantProfit ? R.itemSales(prv) : [],
        wantProfit && s.can('finance.view') ? rpc<{ section: string; amount: number }[]>('fin_income_statement', { p_tenant: tenant.id, p_from: cur.from, p_to: cur.to, p_branch: branchId }).catch(() => null) : null,
      ])
      const gp = (rows: R.ItemRow[]) => rows.reduce((a, r) => a + Number(r.net) - Number(r.cost), 0)
      const profit = wantProfit ? { gross: gp(pit), prevGross: gp(pprev), net_sales: pit.reduce((a, r) => a + Number(r.net), 0),
        net: inc ? inc.reduce((a, r) => a + (['revenue', 'other_income'].includes(r.section) ? Number(r.amount) : -Number(r.amount)), 0) : null } : null
      if (live) setData({ cur: c, prev: p, hours: h, prevHours: ph, tenders: tn, items: it, cashiers: cs, exceptions: ex, stock: st, shift: sh, profit })
    })()
    return () => { live = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [range, prevRange, allBranches, s.branch?.id, visible.join()])

  const d = tenant.currency_decimals
  const nf = lang === 'ar' ? 'ar-u-nu-latn' : 'en'
  const money = (v: number) => fmt(v, tenant, lang)
  const compact = (v: number) => new Intl.NumberFormat(nf, { notation: 'compact', maximumFractionDigits: 1 }).format(v / 10 ** d)
  const count = (v: number) => new Intl.NumberFormat(nf).format(Math.round(v))

  const days = R.eachDay(range.from, range.to), pdays = R.eachDay(prevRange.from, prevRange.to)
  const byDay = (rows: R.DailyRow[]) => new Map(rows.map((r) => [r.day, r]))
  const sum = (rows: R.DailyRow[], k: keyof R.DailyRow) => rows.reduce((a, r) => a + Number(r[k] ?? 0), 0)
  const valueOf = (m: Metric, r?: { net_sales: number; invoices: number; refunds: number }) =>
    !r ? 0 : m === 'net' ? Number(r.net_sales) : m === 'orders' ? Number(r.invoices) : m === 'refunds' ? Number(r.refunds) : r.invoices ? r.net_sales / r.invoices : 0
  const totals = (rows: R.DailyRow[]) => ({ net_sales: sum(rows, 'net_sales'), invoices: sum(rows, 'invoices'), refunds: sum(rows, 'refunds') })
  const kNow = data ? totals(data.cur) : null, kPrev = data ? totals(data.prev) : null

  const series: SeriesPoint[] = useMemo(() => {
    if (!data) return []
    if (preset === 'today') {
      const agg = (rows: R.HourDayRow[]) => {
        const m = new Map<number, { net_sales: number; invoices: number; refunds: number }>()
        for (const r of rows) { const c = m.get(r.hour) ?? { net_sales: 0, invoices: 0, refunds: 0 }; c.net_sales += Number(r.net_sales); c.invoices += Number(r.docs); m.set(r.hour, c) }
        return m
      }
      const c = agg(data.hours), p = agg(data.prevHours)
      const hrs = [...c.keys(), ...p.keys()]
      const lo = Math.min(8, ...hrs), hi = Math.max(22, ...hrs)
      return Array.from({ length: hi - lo + 1 }, (_, i) => lo + i)
        .map((h) => ({ label: `${String(h).padStart(2, '0')}:00`, value: valueOf(metric, c.get(h)), prev: compare ? valueOf(metric, p.get(h)) : undefined }))
    }
    const c = byDay(data.cur), p = byDay(data.prev)
    const label = (iso: string) => new Date(iso + 'T00:00:00').toLocaleDateString(lang === 'ar' ? 'ar-u-nu-latn' : 'en-GB', { day: 'numeric', month: 'short' })
    return days.map((day, i) => ({ label: label(day), value: valueOf(metric, c.get(day)), prev: compare ? valueOf(metric, p.get(pdays[i])) : undefined }))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data, metric, compare, preset, lang])

  const spark = (m: Metric) => (data ? days.map((day) => valueOf(m, byDay(data.cur).get(day))) : [])
  const mFormat = (m: Metric) => (m === 'orders' ? count : money)
  const metricName: Record<Metric, string> = { net: t('Net sales'), orders: t('Orders'), avg: t('Average ticket'), refunds: t('Refunds') }
  const presetName: Record<Preset, string> = { today: t('Today'), '7d': t('7 days'), '30d': t('30 days'), month: t('This month'), custom: t('Custom') }
  const prevName = preset === 'today' ? t('Yesterday') : t('Previous period')

  // payment mix: up to 4 categorical slots, the rest folds into Other (hues are never cycled)
  const slices: Slice[] = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of data?.tenders ?? []) if (Number(r.amount) > 0) m.set(r.tender, (m.get(r.tender) ?? 0) + Number(r.amount))
    const list = [...m.entries()].sort((a, b) => b[1] - a[1])
    const top = list.slice(0, 4).map(([k, v]) => ({ key: k, label: tenderLabel(k, lang), value: v }))
    const rest = list.slice(4).reduce((a, [, v]) => a + v, 0)
    return rest > 0 ? [...top, { key: 'other', label: t('Other'), value: rest }] : top
  }, [data, lang, t])

  const dayLabels = useMemo(() => [0, 1, 2, 3, 4, 5, 6].map((i) => new Date(Date.UTC(2026, 10, 15 + i)).toLocaleDateString(lang === 'ar' ? 'ar' : 'en-GB', { weekday: 'short', timeZone: 'UTC' })), [lang])
  const heat = useMemo(() => {
    const g = Array.from({ length: 7 }, () => Array(24).fill(0) as number[])
    for (const r of data?.hours ?? []) { const wd = new Date(r.day + 'T00:00:00Z').getUTCDay(); g[wd][r.hour] += Number(r.net_sales) }
    return g
  }, [data])
  const heatHours = useMemo(() => Array.from({ length: 24 }, (_, i) => i), [])

  const tiles: { m: Metric; value: number; prev: number; invert?: boolean }[] = kNow && kPrev ? [
    { m: 'net', value: kNow.net_sales, prev: kPrev.net_sales },
    { m: 'orders', value: kNow.invoices, prev: kPrev.invoices },
    { m: 'avg', value: kNow.invoices ? kNow.net_sales / kNow.invoices : 0, prev: kPrev.invoices ? kPrev.net_sales / kPrev.invoices : 0 },
    { m: 'refunds', value: kNow.refunds, prev: kPrev.refunds, invert: true },
  ] : []

  // ---- this user's layout: order and hidden widgets (saved to their account); role layout is the starting point
  const allowed = WIDGETS.filter((w) => (!w.perm || s.can(w.perm)) && (!w.feature || s.has(w.feature))).map((w) => w.id)
  const layout = prefs.dashboard
  const order = layout ? [...layout.order.filter((w) => allowed.includes(w)), ...allowed.filter((w) => !layout.order.includes(w))] : [...widgets.filter((w) => allowed.includes(w)), ...allowed.filter((w) => !widgets.includes(w))]
  const hidden = layout ? layout.hidden.filter((w) => allowed.includes(w)) : allowed.filter((w) => !widgets.includes(w))
  const saveLayout = (o: string[], h: string[]) => set({ dashboard: { order: o, hidden: h } })
  const move = (id: string, to: number) => { const o = order.filter((x) => x !== id); o.splice(Math.max(0, Math.min(to, o.length)), 0, id); saveLayout(o, hidden) }
  const [dragging, setDragging] = useState<string | null>(null)

  const blocks: Record<string, React.ReactNode> = !data ? {} : {
    my_shift: (
      <section className="panel shift-panel">
        <header><h2>{t('My shift')}</h2>{!data.shift && <Link to="/shift" className="link-more">{t('Open shift')} <ArrowUpRight size={14} className="flip-rtl" /></Link>}</header>
        {data.shift ? (
          <div className="mini-kpis">
            <div><span>{t('Sales')}</span><b>{money(data.shift.sales_total)}</b></div>
            <div><span>{t('Invoices')}</span><b>{count(data.shift.invoices)}</b></div>
            <div><span>{t('Refunds')}</span><b>{money(data.shift.refunds_total)}</b></div>
          </div>) : <p className="muted">{t('No open shift.')}</p>}
      </section>),
    alerts: <Alerts />,
    kitchen: s.has('kitchen') && s.branch ? <KitchenNow branchId={s.branch.id} /> : null,
    kpis: (
      <section className="kpi-row" role="tablist" aria-label={t('Choose what the chart shows')}>
        {tiles.map((k) => (
          <button key={k.m} role="tab" aria-selected={metric === k.m} className={`kpi2 ${metric === k.m ? 'on' : ''}`} onClick={() => setMetric(k.m)}>
            <span className="kpi2-label">{metricName[k.m]}</span>
            <b className="kpi2-value">{mFormat(k.m)(k.value)}</b>
            <span className="kpi2-foot"><Delta now={k.value} prev={k.prev} invert={k.invert} /><span className="muted">{t('vs')} {mFormat(k.m)(k.prev)}</span></span>
            <Sparkline values={spark(k.m)} />
          </button>
        ))}
      </section>),
    profit: data.profit && (
      <section className="panel profit-panel">
        <header><div><h2>{t('Profit')}</h2><p className="muted small">{presetName[preset]}</p></div></header>
        <div className="mini-kpis">
          <div><span>{t('Gross profit')}</span><b>{money(data.profit.gross)}</b><Delta now={data.profit.gross} prev={data.profit.prevGross} /></div>
          <div><span>{t('Gross margin')}</span><b>{data.profit.net_sales ? `${Math.round((data.profit.gross / data.profit.net_sales) * 1000) / 10}%` : '—'}</b></div>
          {data.profit.net != null && <div><span>{t('Net profit (after expenses)')}</span><b className={data.profit.net < 0 ? 'bad' : ''}>{money(data.profit.net)}</b></div>}
        </div>
      </section>),
    hourly: (
      <section className="panel trend">
        <header>
          <div><h2>{metricName[metric]}</h2><p className="muted small">{preset === 'today' ? t('By hour') : t('By day')} · {presetName[preset]}</p></div>
          <div className="row">
            {compare && <span className="legend-inline"><i className="key main" />{presetName[preset]}<i className="key prev" />{prevName}</span>}
            <button className={`icon-btn ${asTable ? 'on' : ''}`} onClick={() => setAsTable(!asTable)} title={t('Show as table')} aria-pressed={asTable}><Table2 size={17} /></button>
          </div>
        </header>
        {asTable ? (
          <div className="table-wrap"><table className="list compact">
            <thead><tr><th>{preset === 'today' ? t('Hour') : t('Day')}</th><th className="num">{presetName[preset]}</th>{compare && <th className="num">{prevName}</th>}</tr></thead>
            <tbody>{series.map((p) => <tr key={p.label}><td>{p.label}</td><td className="num">{mFormat(metric)(p.value)}</td>{compare && <td className="num">{mFormat(metric)(p.prev ?? 0)}</td>}</tr>)}</tbody>
          </table></div>
        ) : <AreaChart points={series} format={mFormat(metric)} axisFormat={metric === 'orders' ? count : compact} seriesName={presetName[preset]} prevName={prevName} />}
      </section>),
    tenders: (
      <section className="panel">
        <header><h2>{t('Payment methods')}</h2></header>
        {slices.length === 0 ? <Empty title={t('No payments yet')} /> :
          <Donut items={slices} format={money} center={<><b>{compact(slices.reduce((a, b) => a + b.value, 0))}</b><span>{tenant.currency}</span></>} />}
      </section>),
    heatmap: (
      <section className="panel wide">
        <header><div><h2>{t('Busy hours')}</h2><p className="muted small">{t('Net sales by weekday and hour')}</p></div></header>
        {data.hours.length === 0 ? <Empty title={t('No sales yet')} /> : <Heatmap grid={heat} format={money} dayLabels={dayLabels} hours={heatHours} />}
      </section>),
    top_items: (
      <section className="panel">
        <header><h2>{t('Top items')}</h2>{s.can('reports.all') && <Link to="/reports" className="link-more">{t('All items')} <ArrowUpRight size={14} className="flip-rtl" /></Link>}</header>
        {data.items.length === 0 ? <Empty title={t('No sales yet')} /> :
          <HBars items={data.items.slice(0, 7).map((r) => ({ key: r.item_id ?? r.name, label: r.name, value: r.total, sub: `${Number(r.qty)} ×` }))} format={money} />}
      </section>),
    cashiers: (
      <section className="panel">
        <header><h2>{t('Sales by cashier')}</h2></header>
        {data.cashiers.length === 0 ? <Empty title={t('No sales yet')} /> :
          <HBars items={data.cashiers.map((r) => ({ key: r.created_by, label: r.cashier || '—', value: r.sales,
            sub: r.discounts || r.refunds ? `${t('Discounts')} ${compact(r.discounts)} · ${t('Refunds')} ${compact(r.refunds)}` : undefined }))} format={money} />}
      </section>),
    exceptions: (
      <section className="panel">
        <header><h2>{t('Exceptions')}</h2>{data.exceptions.length > 0 && <span className="badge-count">{data.exceptions.length}</span>}</header>
        {data.exceptions.length === 0 ? <Empty title={t('Nothing unusual in this period')} /> : (
          <ul className="feed">{data.exceptions.slice(0, 8).map((r) => (
            <li key={r.id}>
              <span className="feed-ico" aria-hidden="true">{ACTION_ICON[r.action] ?? '•'}</span>
              <div><b>{t(R.ACTION_LABEL[r.action] ?? r.action)}</b>{r.amount != null && <span className="feed-amt">{money(r.amount)}</span>}
                <p className="muted small">{r.user_name}{r.approver_name ? ` · ${t('Approved by')} ${r.approver_name}` : ''}{r.reason ? ` · ${r.reason}` : ''}</p></div>
              <time className="muted small">{new Date(r.created_at).toLocaleTimeString(nf, { hour: '2-digit', minute: '2-digit' })}</time>
            </li>))}</ul>)}
      </section>),
    stock: (
      <section className="panel">
        <header><h2>{t('Out of stock')}</h2>{data.stock.length > 0 && <AlertTriangle size={17} className="warn-ico" aria-label={t('Needs attention')} />}</header>
        {data.stock.length === 0 ? <Empty title={t('All tracked items are in stock')} /> : (
          <ul className="feed">{data.stock.slice(0, 8).map((r) => (
            <li key={r.name}><span className="feed-ico bad" aria-hidden="true">!</span><div><b>{r.name}</b></div><b className="bad">{r.qty}</b></li>))}</ul>)}
      </section>),
  }
  const label = (id: string) => t(WIDGETS.find((w) => w.id === id)?.label ?? id)

  return (
    <div className="page dash-page">
      <div className="filters-row">
        <div className="seg" role="group" aria-label={t('Period')}>
          {(['today', '7d', '30d', 'month', 'custom'] as Preset[]).map((p) => <button key={p} className={preset === p ? 'on' : ''} onClick={() => setPreset(p)}>{presetName[p]}</button>)}
        </div>
        {preset === 'custom' && <span className="row custom-range">
          <input id="dash-from" type="date" aria-label={t('From')} value={custom.from} max={custom.to} onChange={(e) => setCustom({ ...custom, from: e.target.value })} />
          <span aria-hidden="true">{lang === 'ar' ? '←' : '→'}</span>
          <input id="dash-to" type="date" aria-label={t('To')} value={custom.to} min={custom.from} onChange={(e) => setCustom({ ...custom, to: e.target.value })} /></span>}
        <label className="check"><input id="dash-compare" type="checkbox" checked={compare} onChange={(e) => setCompare(e.target.checked)} />{t('Compare with previous period')}</label>
        {s.can('reports.all') && s.branches.length > 1 && (
          <label className="check"><input id="dash-all" type="checkbox" checked={allBranches} onChange={(e) => setAllBranches(e.target.checked)} />{t('All branches')}</label>)}
        <span className="muted small range-label">{range.from === range.to ? range.from : `${range.from} ${lang === 'ar' ? '←' : '→'} ${range.to}`}</span>
        <button className={`ghost customize-btn ${editing ? 'on' : ''}`} onClick={() => setEditing(!editing)} aria-pressed={editing}><SlidersHorizontal size={16} />{editing ? t('Done') : t('Customize')}</button>
      </div>

      {editing && (
        <div className="dash-tray">
          <span className="muted small">{t('Drag widgets to reorder, or use the arrows. Hidden widgets:')}</span>
          {hidden.length === 0 ? <span className="muted small">{t('none')}</span> : hidden.map((w) => (
            <button key={w} className="chipbtn" onClick={() => saveLayout(order, hidden.filter((x) => x !== w))}><Plus size={14} />{label(w)}</button>))}
          <button className="ghost small" onClick={() => set({ dashboard: undefined })}><RotateCcw size={14} />{t('Reset to the default for my role')}</button>
        </div>)}

      {!data ? <div className="dash-skel" aria-busy="true">{t('Loading…')}</div> : (
        <div className={`dash2 ${editing ? 'editing' : ''}`}>
          {order.filter((w) => !hidden.includes(w) && blocks[w]).map((w, i, list) => (
            <div key={w} className={`widget w-${w} ${dragging === w ? 'dragging' : ''}`} draggable={editing}
              onDragStart={(e) => { setDragging(w); e.dataTransfer.effectAllowed = 'move' }} onDragEnd={() => setDragging(null)}
              onDragOver={(e) => { if (editing && dragging && dragging !== w) e.preventDefault() }}
              onDrop={(e) => { e.preventDefault(); if (dragging && dragging !== w) move(dragging, order.indexOf(w)); setDragging(null) }}>
              {editing && (
                <div className="widget-bar">
                  <GripVertical size={16} aria-hidden="true" /><b>{label(w)}</b>
                  <button className="icon" aria-label={t('Move up')} disabled={i === 0} onClick={() => move(w, order.indexOf(list[i - 1]))}><ArrowUp size={15} /></button>
                  <button className="icon" aria-label={t('Move down')} disabled={i === list.length - 1} onClick={() => move(w, order.indexOf(list[i + 1]) + 1)}><ArrowDown size={15} /></button>
                  <button className="icon" aria-label={t('Hide')} onClick={() => saveLayout(order, [...hidden, w])}><EyeOff size={15} /></button>
                </div>)}
              {blocks[w]}
            </div>))}
        </div>
      )}
    </div>
  )
}

/** What needs attention now, each with a link: stock, expiry, unpaid invoices, online orders, tables, ready jobs, appointments, deliveries. */
function Alerts() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [rows, setRows] = useState<{ key: string; n: number; label: string; to: string; tone: 'bad' | 'warn' | 'info'; amount?: number }[] | null>(null)
  useEffect(() => {
    if (!s.branch) return
    const b = s.branch.id
    const today = new Date().toISOString().slice(0, 10)
    const q = <T,>(on: boolean, f: () => PromiseLike<{ data: T[] | null; count?: number | null }>) => (on ? f() : Promise.resolve({ data: [] as T[], count: 0 }))
    void Promise.all([
      q(true, () => supabase.from('v_inventory').select('item_id, on_hand, reorder_point').eq('branch_id', b)),
      q(s.has('batches'), () => supabase.from('v_batches').select('id, days_left, on_hand').eq('branch_id', b).gt('on_hand', 0).lte('days_left', 7)),
      q(s.can('reports.all') || s.can('payments.receive'), () => supabase.from('sales').select('id, total, paid_total, refunded_total').eq('branch_id', b).eq('doc_type', 'invoice').eq('status', 'completed').limit(1000)),
      q(s.has('qr_ordering'), () => supabase.from('online_orders').select('id', { count: 'exact', head: false }).eq('branch_id', b).eq('status', 'pending')),
      q(s.has('tables'), () => supabase.from('open_orders').select('id').eq('branch_id', b).eq('status', 'open')),
      q(s.has('job_cards') || s.has('preorders'), () => supabase.from('work_orders').select('id, status, due_at').eq('branch_id', b).in('status', ['received', 'in_progress', 'ready'])),
      q(s.has('appointments'), () => supabase.from('appointments').select('id, status').eq('branch_id', b).gte('starts_at', `${today}T00:00:00`).lt('starts_at', `${today}T23:59:59`).in('status', ['booked', 'confirmed', 'arrived'])),
      q(s.has('own_delivery'), () => supabase.from('deliveries').select('id, status').eq('branch_id', b).in('status', ['pending', 'assigned', 'picked_up'])),
    ]).then(([inv, bat, sal, onl, tab, wo, ap, dl]) => {
      const invRows = (inv.data ?? []) as { on_hand: number; reorder_point: number | null }[]
      const unpaid = ((sal.data ?? []) as { total: number; paid_total: number; refunded_total: number }[]).filter((x) => x.total - x.refunded_total - x.paid_total > 0)
      const woRows = (wo.data ?? []) as { status: string; due_at: string | null }[]
      const out = [
        { key: 'out', n: invRows.filter((x) => Number(x.on_hand) <= 0).length, label: t('Out of stock'), to: '/inventory', tone: 'bad' as const },
        { key: 'low', n: invRows.filter((x) => Number(x.on_hand) > 0 && x.reorder_point != null && Number(x.on_hand) <= Number(x.reorder_point)).length, label: t('Below reorder point'), to: '/inventory', tone: 'warn' as const },
        { key: 'exp', n: (bat.data ?? []).length, label: t('Batches expiring within 7 days'), to: '/inventory', tone: 'warn' as const },
        { key: 'unpaid', n: unpaid.length, amount: unpaid.reduce((a, x) => a + x.total - x.refunded_total - x.paid_total, 0), label: t('Unpaid invoices (on account / payment links)'), to: '/sales', tone: 'warn' as const },
        { key: 'online', n: (onl.data ?? []).length, label: t('Online orders waiting'), to: '/pos', tone: 'bad' as const },
        { key: 'tables', n: (tab.data ?? []).length, label: t('Open tables'), to: '/pos', tone: 'info' as const },
        { key: 'ready', n: woRows.filter((x) => x.status === 'ready').length, label: t('Ready, not collected'), to: '/orders', tone: 'info' as const },
        { key: 'late', n: woRows.filter((x) => x.status !== 'ready' && x.due_at && new Date(x.due_at) < new Date()).length, label: t('Late job cards / pre-orders'), to: '/orders', tone: 'bad' as const },
        { key: 'appts', n: (ap.data ?? []).length, label: t('Appointments still to come today'), to: '/calendar', tone: 'info' as const },
        { key: 'deliv', n: (dl.data ?? []).length, label: t('Deliveries in progress'), to: '/deliveries', tone: 'info' as const },
      ]
      setRows(out.filter((x) => x.n > 0))
    })
  }, [s])
  return (
    <section className="panel alerts-panel">
      <header><h2>{t('Needs attention')}</h2>{rows && rows.length > 0 && <span className="badge-count">{rows.reduce((a, r) => a + r.n, 0)}</span>}</header>
      {!rows ? <p className="muted">{t('Loading…')}</p> : rows.length === 0 ? <p className="success">{t('All clear. Nothing needs attention.')}</p> : (
        <ul className="alert-list">{rows.map((r) => (
          <li key={r.key} className={`tone-${r.tone}`}><Link to={r.to}><b>{r.n}</b><span>{r.label}</span>{r.amount != null && <em>{fmt(r.amount, tn, lang)}</em>}<ArrowUpRight size={14} className="flip-rtl" aria-hidden="true" /></Link></li>))}</ul>)}
    </section>
  )
}

async function outOfStock(tenantId: string, branchId: string) {
  const [{ data: items }, { data: lv }] = await Promise.all([
    supabase.from('items').select('id, name, name_ar').eq('tenant_id', tenantId).eq('track_stock', true).eq('is_active', true),
    supabase.from('v_stock_levels').select('item_id, qty').eq('branch_id', branchId),
  ])
  const q = new Map((lv ?? []).map((r) => [r.item_id as string, Number(r.qty)]))
  return (items ?? []).map((i) => ({ name: i.name as string, qty: q.get(i.id as string) ?? 0 })).filter((r) => r.qty <= 0)
}

/** Live kitchen monitor: open orders, the oldest one (ticking), late orders and today's average order time. */
function KitchenNow({ branchId }: { branchId: string }) {
  const { t } = useT()
  const [open, setOpen] = useState<{ created_at: string; status: string; alert_minutes: number }[]>([])
  const [today, setToday] = useState<R.KitchenRow[]>([])
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const load = async () => {
      const day = new Date().toISOString().slice(0, 10)
      const [o, k] = await Promise.all([
        supabase.from('v_kitchen_times').select('created_at, status, alert_minutes').eq('branch_id', branchId).in('status', ['new', 'preparing']),
        R.kitchenTimes({ from: day, to: day, branchId }),
      ])
      setOpen((o.data ?? []) as typeof open); setToday(k)
    }
    void load()
    const a = window.setInterval(() => void load(), 15_000), b = window.setInterval(() => setNow(Date.now()), 1000)
    return () => { clearInterval(a); clearInterval(b) }
  }, [branchId])
  const ages = open.map((x) => (now - Date.parse(x.created_at)) / 1000)
  const oldest = ages.length ? Math.max(...ages) : null
  const lateNow = open.filter((x) => (now - Date.parse(x.created_at)) / 60000 > x.alert_minutes).length
  const sum = R.kitchenSummary(today)[0]
  return (
    <section className="panel shift-panel">
      <header><h2>{t('Kitchen now')}</h2><Link to="/kds" className="link-more">{t('Open kitchen screen')} <ArrowUpRight size={14} /></Link></header>
      <div className="live-kitchen">
        <div><span>{t('Open orders')}</span><b>{open.length}</b></div>
        <div className={oldest != null && lateNow ? 'bad' : ''}><span>{t('Oldest order')}</span><b>{R.mmss(oldest)}</b></div>
        <div className={lateNow ? 'bad' : ''}><span>{t('Late now')}</span><b>{lateNow}</b></div>
        <div><span>{t('Average order time today')}</span><b>{R.mmss(sum?.total)}</b></div>
        <div><span>{t('On time today')}</span><b>{sum?.onTime == null ? '—' : `${sum.onTime}%`}</b></div>
      </div>
    </section>
  )
}

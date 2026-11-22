import { Serials } from './inventory/Serials'
import { AlertTriangle, ClipboardCheck, Download } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Empty, Modal, useApproval } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt, num } from '../lib/money'
import { parseError } from '../lib/supabase'
import { Production, Transfers } from './inventory/Moves'
import { downloadCsv } from '../lib/reports'
import { useSession } from '../lib/session'
import { norm } from '../lib/shift'
import { rpc, supabase } from '../lib/supabase'

interface Row { item_id: string; name: string; name_ar: string | null; sku: string | null; barcode: string | null; item_type: string; unit: string; cost: number; reorder_point: number | null; on_hand: number; value: number; last_movement: string | null; used_30d: number }
interface Batch { id: string; item_id: string; name: string; name_ar: string | null; unit: string; cost: number; batch_no: string; expiry_date: string | null; on_hand: number; days_left: number | null }
interface Move { created_at: string; reason: string; qty: number | null; unit_cost: number | null; balance: number; note: string | null; by_name: string | null }

const REASON: Record<string, string> = { opening: 'Opening balance', sale: 'Sale', refund: 'Refund', adjustment: 'Adjustment', receipt: 'Goods received', count: 'Stock count', transfer_in: 'Transfer in', transfer_out: 'Transfer out' }
const today = () => new Date().toISOString().slice(0, 10)

/** Detailed stock for every item and ingredient: on hand, value, usage, days of cover, stock card and counts. */
export default function Inventory() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [tab, setTab] = useState<'stock' | 'card' | 'count' | 'expiry' | 'transfers' | 'production' | 'serials'>('stock')
  const [batches, setBatches] = useState<Batch[]>([])
  const [writeOff, setWriteOff] = useState<Batch | null>(null)
  const [rows, setRows] = useState<Row[]>([])
  const [q, setQ] = useState('')
  const [onlyLow, setOnlyLow] = useState(false)
  const [cardItem, setCardItem] = useState<string>('')
  const [from, setFrom] = useState(() => { const x = new Date(); x.setDate(x.getDate() - 30); return x.toISOString().slice(0, 10) })
  const [to, setTo] = useState(today())
  const [moves, setMoves] = useState<Move[]>([])
  const [counts, setCounts] = useState<Record<string, string>>({})
  const [note, setNote] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const approval = useApproval()
  const canCost = s.can('reports.costs') || s.can('catalog.manage')
  const name = (r: { name: string; name_ar: string | null }) => (lang === 'ar' && r.name_ar ? r.name_ar : r.name)

  const load = useCallback(async () => {
    if (!s.branch) return
    const { data } = await supabase.from('v_inventory').select('*').eq('branch_id', s.branch.id).order('name')
    setRows(((data ?? []) as Row[]).map((r) => ({ ...r, on_hand: Number(r.on_hand), used_30d: Number(r.used_30d) })))
  }, [s.branch])
  useEffect(() => { void load() }, [load])
  const loadBatches = useCallback(async () => {
    if (!s.branch || !s.has('batches')) return
    const { data } = await supabase.from('v_batches').select('*').eq('branch_id', s.branch.id).gt('on_hand', 0).order('expiry_date', { nullsFirst: false })
    setBatches(((data ?? []) as Batch[]).map((b) => ({ ...b, on_hand: Number(b.on_hand) })))
  }, [s])
  useEffect(() => { if (tab === 'expiry') void loadBatches() }, [tab, loadBatches])
  useEffect(() => {
    if (tab !== 'card' || !cardItem || !s.branch) return
    void rpc<Move[]>('stock_card', { p_item: cardItem, p_branch: s.branch.id, p_from: from, p_to: to }).then(setMoves).catch(() => setMoves([]))
  }, [tab, cardItem, from, to, s.branch])

  const isLow = (r: Row) => (r.reorder_point != null && r.on_hand <= Number(r.reorder_point)) || r.on_hand <= 0
  const shown = useMemo(() => {
    const n = norm(q)
    return rows.filter((r) => (!onlyLow || isLow(r)) && (!n || norm(r.name).includes(n) || norm(r.name_ar ?? '').includes(n) || r.barcode === q || r.sku === q))
  }, [rows, q, onlyLow])
  const total = rows.reduce((a, r) => a + Math.max(0, Number(r.value)), 0)
  const lowCount = rows.filter(isLow).length
  const cover = (r: Row) => (r.used_30d > 0 ? Math.floor(r.on_hand / (r.used_30d / 30)) : null)

  async function postCount() {
    setMsg(null)
    const lines = Object.entries(counts).filter(([, v]) => v.trim() !== '').map(([item_id, v]) => ({ item_id, counted: Number(v) }))
    if (!lines.length) return
    const r = await approval.run(() => rpc<{ adjusted_lines: number; gain: number; loss: number }>('post_stock_count', { p_branch: s.branch!.id, p_lines: lines, p_note: note || 'Stock count' }))
    if (r) { setMsg(t('{n} items adjusted · gain {g} · loss {l}', { n: r.adjusted_lines, g: num(r.gain, d), l: num(r.loss, d) })); setCounts({}); await load() }
  }

  return (
    <div className="page">
      <div className="tabs">
        <button className={tab === 'stock' ? 'on' : ''} onClick={() => setTab('stock')}>{t('Stock on hand')}</button>
        <button className={tab === 'card' ? 'on' : ''} onClick={() => setTab('card')}>{t('Stock card')}</button>
        {s.can('inventory.adjust') && <button className={tab === 'count' ? 'on' : ''} onClick={() => setTab('count')}>{t('Stock count')}</button>}
        {s.has('batches') && <button className={tab === 'expiry' ? 'on' : ''} onClick={() => setTab('expiry')}>{t('Expiry')}</button>}
        {s.has('transfers') && <button className={tab === 'transfers' ? 'on' : ''} onClick={() => setTab('transfers')}>{t('Transfers')}</button>}
        {s.has('production') && s.can('inventory.adjust') && <button className={tab === 'production' ? 'on' : ''} onClick={() => setTab('production')}>{t('Production')}</button>}
        {s.has('serials') && <button className={tab === 'serials' ? 'on' : ''} onClick={() => setTab('serials')}>{t('Serial numbers')}</button>}
      </div>

      {tab === 'stock' && (
        <>
          <div className="kpi-row">
            <div className="kpi2"><span className="kpi2-label">{t('Items tracked')}</span><b className="kpi2-value">{rows.length}</b></div>
            {canCost && <div className="kpi2"><span className="kpi2-label">{t('Stock value')}</span><b className="kpi2-value">{fmt(total, tn, lang)}</b></div>}
            <button className={`kpi2 ${onlyLow ? 'on' : ''}`} onClick={() => setOnlyLow(!onlyLow)}><span className="kpi2-label">{t('Low or out of stock')}</span>
              <b className={`kpi2-value ${lowCount ? 'bad' : ''}`}>{lowCount}</b></button>
          </div>
          <div className="filters">
            <input id="inv-q" className="search grow" placeholder={t('Search name, barcode or SKU')} value={q} onChange={(e) => setQ(e.target.value)} />
            <button onClick={() => downloadCsv(`inventory-${today()}.csv`, shown.map((r) => ({ item: r.name, type: r.item_type, unit: r.unit, on_hand: r.on_hand, reorder_point: r.reorder_point ?? '', unit_cost: num(r.cost, d), value: num(Number(r.value), d), used_30_days: r.used_30d, days_cover: cover(r) ?? '' })))}><Download size={16} />{t('Export CSV')}</button>
          </div>
          {shown.length === 0 ? <Empty title={t('No stock items')} /> : (
            <div className="table-wrap"><table className="list">
              <thead><tr><th>{t('Item')}</th><th>{t('Type')}</th><th className="num">{t('On hand')}</th><th className="num">{t('Reorder at')}</th><th className="num">{t('Used (30 days)')}</th><th className="num">{t('Days of cover')}</th>
                {canCost && <th className="num">{t('Unit cost')}</th>}{canCost && <th className="num">{t('Value')}</th>}<th>{t('Last movement')}</th></tr></thead>
              <tbody>{shown.map((r) => (
                <tr key={r.item_id} tabIndex={0} onClick={() => { setCardItem(r.item_id); setTab('card') }} onKeyDown={(e) => { if (e.key === 'Enter') { setCardItem(r.item_id); setTab('card') } }}>
                  <td>{isLow(r) && <AlertTriangle size={14} className="warn-ico" aria-label={t('Needs attention')} />} {name(r)}</td>
                  <td><span className={`pill type-${r.item_type}`}>{t(r.item_type === 'ingredient' ? 'Ingredient' : 'Product')}</span></td>
                  <td className={`num ${isLow(r) ? 'bad' : ''}`}><b>{Number(r.on_hand.toFixed(3))}</b> {t(r.unit)}</td>
                  <td className="num">{r.reorder_point ?? '—'}</td>
                  <td className="num">{Number(r.used_30d.toFixed(3))}</td>
                  <td className={`num ${cover(r) != null && cover(r)! < 3 ? 'bad' : ''}`}>{cover(r) ?? '—'}</td>
                  {canCost && <td className="num">{num(r.cost, d)}</td>}{canCost && <td className="num">{num(Number(r.value), d)}</td>}
                  <td className="muted small">{r.last_movement ? new Date(r.last_movement).toLocaleDateString() : '—'}</td>
                </tr>))}</tbody>
            </table></div>)}
        </>
      )}

      {tab === 'card' && (
        <>
          <div className="filters">
            <label className="field grow"><span>{t('Item')}</span><select id="card-item" value={cardItem} onChange={(e) => setCardItem(e.target.value)}>
              <option value="">—</option>{rows.map((r) => <option key={r.item_id} value={r.item_id}>{name(r)}</option>)}</select></label>
            <label className="field"><span>{t('From')}</span><input id="card-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
            <label className="field"><span>{t('To')}</span><input id="card-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label>
          </div>
          {!cardItem ? <Empty title={t('Choose an item to see every movement')} /> : (
            <div className="table-wrap"><table className="list">
              <thead><tr><th>{t('Date')}</th><th>{t('Movement')}</th><th>{t('Note')}</th><th>{t('By')}</th><th className="num">{t('In')}</th><th className="num">{t('Out')}</th><th className="num">{t('Balance')}</th></tr></thead>
              <tbody>{moves.map((m, i) => (
                <tr key={i} className={m.reason === 'opening' ? 'st-sec' : ''}><td>{m.reason === 'opening' ? from : new Date(m.created_at).toLocaleString()}</td><td>{t(REASON[m.reason] ?? m.reason)}</td>
                  <td className="muted small">{m.note}</td><td className="muted small">{m.by_name}</td>
                  <td className="num good">{m.qty != null && m.qty > 0 ? Number(Number(m.qty).toFixed(3)) : ''}</td><td className="num bad">{m.qty != null && m.qty < 0 ? Number((-m.qty).toFixed(3)) : ''}</td>
                  <td className="num"><b>{Number(Number(m.balance).toFixed(3))}</b></td></tr>))}</tbody>
            </table></div>)}
        </>
      )}

      {tab === 'count' && (
        <>
          <p className="muted small">{t('Enter what you physically counted. Only the differences are posted, valued at average cost, to stock and to the ledger (inventory adjustments).')}</p>
          <div className="filters">
            <input id="count-q" className="search grow" placeholder={t('Search name, barcode or SKU')} value={q} onChange={(e) => setQ(e.target.value)} />
            <input id="count-note" placeholder={t('Note, e.g. Night count')} value={note} onChange={(e) => setNote(e.target.value)} />
            <button className="primary" disabled={!Object.values(counts).some((v) => v.trim() !== '')} onClick={() => void postCount()}><ClipboardCheck size={16} />{t('Post count')}</button>
          </div>
          {msg && <p className="success">{msg}</p>}
          {approval.error && <p className="error">{approval.error}</p>}
          <div className="table-wrap"><table className="list">
            <thead><tr><th>{t('Item')}</th><th className="num">{t('System')}</th><th>{t('Counted')}</th><th className="num">{t('Difference')}</th>{canCost && <th className="num">{t('Value')}</th>}</tr></thead>
            <tbody>{shown.map((r) => {
              const c = counts[r.item_id]; const diff = c != null && c.trim() !== '' ? Number(c) - r.on_hand : null
              return (
                <tr key={r.item_id}><td>{name(r)} <span className="muted small">{t(r.unit)}</span></td><td className="num">{Number(r.on_hand.toFixed(3))}</td>
                  <td><input id={`cnt-${r.item_id}`} className="qty-in" inputMode="decimal" value={c ?? ''} onChange={(e) => setCounts({ ...counts, [r.item_id]: e.target.value })} /></td>
                  <td className={`num ${diff == null ? '' : diff < 0 ? 'bad' : diff > 0 ? 'good' : ''}`}>{diff == null ? '' : Number(diff.toFixed(3))}</td>
                  {canCost && <td className="num">{diff == null ? '' : num(Math.round(diff * r.cost), d)}</td>}</tr>)
            })}</tbody>
          </table></div>
        </>
      )}
      {tab === 'expiry' && (() => {
        const val = (b: Batch) => Math.round(b.on_hand * b.cost)
        const expired = batches.filter((b) => b.days_left != null && b.days_left < 0), soon = batches.filter((b) => b.days_left != null && b.days_left >= 0 && b.days_left <= 7)
        return (
          <>
            <div className="kpi-row">
              <div className="kpi2"><span className="kpi2-label">{t('Expired')}</span><b className={`kpi2-value ${expired.length ? 'bad' : ''}`}>{expired.length}</b>{canCost && <span className="kpi2-sub">{fmt(expired.reduce((a, b) => a + val(b), 0), tn, lang)}</span>}</div>
              <div className="kpi2"><span className="kpi2-label">{t('Expiring within 7 days')}</span><b className={`kpi2-value ${soon.length ? 'warn' : ''}`}>{soon.length}</b>{canCost && <span className="kpi2-sub">{fmt(soon.reduce((a, b) => a + val(b), 0), tn, lang)}</span>}</div>
              <div className="kpi2"><span className="kpi2-label">{t('Batches in stock')}</span><b className="kpi2-value">{batches.length}</b></div>
            </div>
            <p className="muted small">{t('Sales take stock from the batch that expires first. Write off expired or damaged stock here; it is posted to inventory adjustments.')}</p>
            {batches.length === 0 ? <Empty title={t('No batches yet')} hint={t('Tick “Track batches and expiry dates” on an item, then receive it with a batch number and expiry date.')} /> : (
              <div className="table-wrap"><table className="list">
                <thead><tr><th>{t('Item')}</th><th>{t('Batch')}</th><th>{t('Expiry date')}</th><th className="num">{t('Days left')}</th><th className="num">{t('On hand')}</th>{canCost && <th className="num">{t('Value')}</th>}<th /></tr></thead>
                <tbody>{batches.map((b) => (
                  <tr key={b.id} className={b.days_left != null && b.days_left < 0 ? 'row-bad' : b.days_left != null && b.days_left <= 7 ? 'row-warn' : ''}>
                    <td>{name(b)}</td><td className="mono small">{b.batch_no}</td><td>{b.expiry_date ?? '—'}</td>
                    <td className={`num ${b.days_left != null && b.days_left < 0 ? 'bad' : ''}`}>{b.days_left ?? '—'}</td>
                    <td className="num"><b>{Number(b.on_hand.toFixed(3))}</b> {t(b.unit)}</td>{canCost && <td className="num">{num(val(b), d)}</td>}
                    <td>{s.can('inventory.adjust') && <button className="ghost small" onClick={() => setWriteOff(b)}>{t('Write off')}</button>}</td></tr>))}</tbody>
              </table></div>)}
            {writeOff && <WriteOff b={writeOff} onClose={() => setWriteOff(null)} onDone={async () => { setWriteOff(null); await loadBatches(); await load() }} />}
          </>
        )
      })()}
      {tab === 'transfers' && <Transfers />}
      {tab === 'production' && <Production />}
      {tab === 'serials' && <Serials />}
      {approval.dialog}
    </div>
  )
}

function WriteOff({ b, onClose, onDone }: { b: Batch; onClose: () => void; onDone: () => void }) {
  const { t } = useT()
  const approval = useApproval()
  const [qty, setQty] = useState(String(b.on_hand))
  const [reason, setReason] = useState(b.days_left != null && b.days_left < 0 ? t('Expired') : t('Damaged'))
  const [err, setErr] = useState<string | null>(null)
  async function go() {
    setErr(null)
    try { const r = await approval.run(() => rpc('write_off_batch', { p_batch: b.id, p_qty: Number(qty), p_reason: reason }).then(() => true)); if (r) onDone() }
    catch (e) { const p = parseError(e); setErr(p.kind === 'message' ? t(p.message) : '') }
  }
  return (
    <Modal title={`${t('Write off')} · ${b.name} · ${b.batch_no}`} onClose={onClose}>
      <div className="stack">
        <label className="field"><span>{t('Quantity')}</span><input id="wo-qty" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} /></label>
        <label className="field"><span>{t('Reason')}</span><input id="wo-reason" value={reason} onChange={(e) => setReason(e.target.value)} /></label>
        {(err || approval.error) && <p className="error">{err || approval.error}</p>}
        <div className="row end"><button className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="danger" onClick={() => void go()}>{t('Write off')}</button></div>
      </div>
      {approval.dialog}
    </Modal>
  )
}

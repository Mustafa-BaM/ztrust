import { ArrowRightLeft, Factory, Plus, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Empty } from '../../components/ui'
import { useName, useT } from '../../lib/i18n'
import { num } from '../../lib/money'
import { useSession } from '../../lib/session'
import { parseError, rpc, supabase } from '../../lib/supabase'
import type { Item } from '../../lib/types'

interface Transfer { id: string; number: string; from_branch: string; to_branch: string; status: string; lines: { item_id: string; name: string; qty: number; received_qty?: number }[]; created_at: string; note: string | null }

/** Send stock to another branch (it leaves now, arrives when they confirm); shortfalls are written off as transfer loss. */
export function Transfers() {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const [list, setList] = useState<Transfer[]>([])
  const [items, setItems] = useState<Item[]>([])
  const [to, setTo] = useState('')
  const [lines, setLines] = useState<{ item_id: string; qty: string }[]>([{ item_id: '', qty: '' }])
  const [got, setGot] = useState<Record<string, Record<string, string>>>({})
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const others = s.branches.filter((b) => b.id !== s.branch?.id)
  const bname = (id: string) => { const b = s.branches.find((x) => x.id === id); return b ? nameOf(b) : '…' }
  const load = useCallback(async () => {
    const [tr, it] = await Promise.all([
      supabase.from('stock_transfers').select('*').or(`from_branch.eq.${s.branch!.id},to_branch.eq.${s.branch!.id}`).order('created_at', { ascending: false }).limit(100),
      supabase.from('items').select('*').eq('tenant_id', s.tenant!.id).eq('track_stock', true).eq('is_template', false).order('name'),
    ])
    setList((tr.data ?? []) as Transfer[]); setItems((it.data ?? []) as Item[])
  }, [s.branch, s.tenant])
  useEffect(() => { void load() }, [load])
  const run = async (f: () => Promise<unknown>, ok: string) => { setMsg(null); try { await f(); setMsg({ ok: true, text: ok }); await load() } catch (e) { const p = parseError(e); setMsg({ ok: false, text: p.kind === 'message' ? t(p.message) : t('Not allowed') }) } }
  if (!others.length) return <Empty title={t('Only one branch')} hint={t('Transfers need a second branch. Add branches from Settings.')} />
  const valid = lines.filter((l) => l.item_id && parseFloat(l.qty) > 0)
  return (
    <section className="stack">
      {s.can('inventory.adjust') && (
        <form className="card stack" onSubmit={(e) => { e.preventDefault(); void run(() => rpc('send_transfer', { p: { from_branch: s.branch!.id, to_branch: to, lines: valid.map((l) => ({ item_id: l.item_id, qty: parseFloat(l.qty) })) } }), t('Transfer sent. The other branch confirms on arrival.')).then(() => setLines([{ item_id: '', qty: '' }])) }}>
          <h2><ArrowRightLeft size={18} aria-hidden="true" /> {t('Send to another branch')}</h2>
          <label className="field"><span>{t('To')}</span><select id="tr-to" required value={to} onChange={(e) => setTo(e.target.value)}><option value="">—</option>{others.map((b) => <option key={b.id} value={b.id}>{nameOf(b)}</option>)}</select></label>
          {lines.map((l, i) => (
            <div key={i} className="row">
              <select aria-label={t('Item')} value={l.item_id} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, item_id: e.target.value } : x)))}><option value="">{t('Item')}…</option>{items.map((x) => <option key={x.id} value={x.id}>{nameOf(x)}</option>)}</select>
              <input aria-label={t('Qty')} className="qty-in" inputMode="decimal" value={l.qty} onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} />
              <button type="button" className="icon" aria-label={t('Remove')} onClick={() => setLines(lines.filter((_, j) => j !== i))}><Trash2 size={14} /></button>
            </div>))}
          <div className="row"><button type="button" className="ghost" onClick={() => setLines([...lines, { item_id: '', qty: '' }])}><Plus size={14} />{t('Add line')}</button>
            <button className="primary" disabled={!to || !valid.length}>{t('Send transfer')}</button></div>
        </form>)}
      {msg && <p className={msg.ok ? 'success' : 'error'}>{msg.text}</p>}
      <div className="table-wrap"><table className="list">
        <thead><tr><th>#</th><th>{t('From')}</th><th>{t('To')}</th><th>{t('Items')}</th><th>{t('Status')}</th><th /></tr></thead>
        <tbody>{list.map((x) => (
          <tr key={x.id}><td className="mono">{x.number}</td><td>{bname(x.from_branch)}</td><td>{bname(x.to_branch)}</td>
            <td className="small">{x.lines.map((l) => (
              <div key={l.item_id}>{Number(l.qty)}× {l.name}{x.status === 'received' && l.received_qty != null && Number(l.received_qty) !== Number(l.qty) ? <span className="bad"> ({t('received {n}', { n: Number(l.received_qty) })})</span> : ''}
                {x.status === 'sent' && x.to_branch === s.branch?.id && <input aria-label={t('Received')} className="qty-in" inputMode="decimal" placeholder={String(Number(l.qty))} value={got[x.id]?.[l.item_id] ?? ''} onChange={(e) => setGot({ ...got, [x.id]: { ...(got[x.id] ?? {}), [l.item_id]: e.target.value } })} />}</div>))}</td>
            <td><span className={`pill ${x.status === 'sent' ? 'warn' : ''}`}>{t(x.status === 'sent' ? 'In transit' : x.status === 'received' ? 'Received' : 'Cancelled')}</span></td>
            <td>{x.status === 'sent' && x.to_branch === s.branch?.id && s.can('inventory.receive') &&
              <button className="primary small" onClick={() => void run(() => rpc('receive_transfer', { p_id: x.id, p_received: Object.fromEntries(Object.entries(got[x.id] ?? {}).filter(([, v]) => v !== '').map(([k, v]) => [k, parseFloat(v)])) }), t('Received into stock'))}>{t('Confirm arrival')}</button>}</td></tr>))}</tbody>
      </table></div>
    </section>
  )
}

/** Make stocked items from their recipe in a central kitchen or bakery: ingredients out, finished goods in at their cost. */
export function Production() {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const d = s.tenant!.currency_decimals
  const [items, setItems] = useState<Item[]>([])
  const [item, setItem] = useState('')
  const [qty, setQty] = useState('')
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  useEffect(() => {
    void Promise.all([
      supabase.from('items').select('*').eq('tenant_id', s.tenant!.id).eq('track_stock', true).neq('item_type', 'ingredient').order('name'),
      supabase.from('recipe_lines').select('item_id').eq('tenant_id', s.tenant!.id),
    ]).then(([i, r]) => { const has = new Set((r.data ?? []).map((x) => x.item_id as string)); setItems(((i.data ?? []) as Item[]).filter((x) => has.has(x.id))) })
  }, [s.tenant])
  async function go(e: React.FormEvent) {
    e.preventDefault(); setMsg(null)
    try { const r = await rpc<{ item: string; qty: number; unit_cost: number; total_cost: number }>('produce', { p_branch: s.branch!.id, p_item: item, p_qty: parseFloat(qty) })
      setMsg({ ok: true, text: t('{qty} × {item} produced · cost {c} each', { qty: r.qty, item: r.item, c: num(r.unit_cost, d) }) }); setQty('') }
    catch (x) { const p = parseError(x); setMsg({ ok: false, text: p.kind === 'message' ? t(p.message) : t('Not allowed') }) }
  }
  return (
    <form className="card stack" onSubmit={go}>
      <h2><Factory size={18} aria-hidden="true" /> {t('Production')}</h2>
      <p className="muted small">{t('Items appear here when they track stock and have a recipe (Products → Recipe). Producing takes the ingredients out of stock and puts the finished items in, at the ingredients’ cost.')}</p>
      {items.length === 0 ? <p className="muted">{t('No items with a recipe yet.')}</p> : <>
        <label className="field"><span>{t('Item')}</span><select id="prod-item" value={item} onChange={(e) => setItem(e.target.value)}><option value="">—</option>{items.map((x) => <option key={x.id} value={x.id}>{nameOf(x)}</option>)}</select></label>
        <label className="field"><span>{t('Quantity made')}</span><input id="prod-qty" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} /></label>
        <div><button className="primary" disabled={!item || !(parseFloat(qty) > 0)}>{t('Record production')}</button></div></>}
      {msg && <p className={msg.ok ? 'success' : 'error'}>{msg.text}</p>}
    </form>
  )
}

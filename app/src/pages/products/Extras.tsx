import { Plus, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../../components/ui'
import { useT } from '../../lib/i18n'
import { num, toMinor } from '../../lib/money'
import { useSession } from '../../lib/session'
import { parseError, rpc, supabase } from '../../lib/supabase'
import type { Item, ModifierGroup, ModifierOption } from '../../lib/types'

/** Size × colour (or any attributes) → one sellable item per combination, each with its own barcode and stock. */
export function VariantDialog({ item, decimals, onClose, onDone }: { item: Item; decimals: number; onClose: () => void; onDone: () => void }) {
  const { t } = useT()
  const [rows, setRows] = useState([{ name: t('Size'), values: 'S, M, L, XL' }, { name: t('Colour'), values: '' }])
  const [price, setPrice] = useState(num(item.price, decimals))
  const [err, setErr] = useState<string | null>(null)
  const attrs = Object.fromEntries(rows.filter((r) => r.name.trim() && r.values.trim()).map((r) => [r.name.trim(), r.values.split(/[,،]/).map((v) => v.trim()).filter(Boolean)]))
  const count = Object.values(attrs).reduce((a, v) => a * v.length, Object.keys(attrs).length ? 1 : 0)
  async function go(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try { await rpc('generate_variants', { p: { template_id: item.id, attrs, price: toMinor(price, decimals) } }); onDone() }
    catch (x) { const p = parseError(x); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) }
  }
  return (
    <Modal title={t('Variants of {name}', { name: item.name })} onClose={onClose} wide>
      <form className="stack" onSubmit={go}>
        <p className="muted small">{t('Write the values separated by commas. Each combination becomes its own item with its own barcode and stock. Existing combinations are kept.')}</p>
        {rows.map((r, i) => (
          <div key={i} className="grid2">
            <label className="field"><span>{t('Attribute')}</span><input id={`var-name-${i}`} value={r.name} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)))} /></label>
            <label className="field"><span>{t('Values')}</span><input id={`var-values-${i}`} value={r.values} placeholder="S, M, L" onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, values: e.target.value } : x)))} /></label>
          </div>))}
        <div className="row"><button type="button" className="ghost" onClick={() => setRows([...rows, { name: '', values: '' }])}><Plus size={15} />{t('Add attribute')}</button></div>
        <label className="field"><span>{t('Price of each variant')}</span><input id="var-price" inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} /></label>
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button>
          <button className="primary" disabled={count === 0}>{t('Create {n} variants', { n: count })}</button></div>
      </form>
    </Modal>
  )
}

/** Add-on groups (Size, Milk, Extras, Gift wrap) with their options; each item picks the groups it offers. */
export function ModifierManager({ items, decimals, onClose }: { items: Item[]; decimals: number; onClose: () => void }) {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [groups, setGroups] = useState<ModifierGroup[]>([])
  const [opts, setOpts] = useState<ModifierOption[]>([])
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => {
    const [g, o] = await Promise.all([
      supabase.from('modifier_groups').select('*').eq('tenant_id', tn.id).order('sort'),
      supabase.from('modifier_options').select('*').eq('tenant_id', tn.id).order('sort'),
    ])
    setGroups((g.data ?? []) as ModifierGroup[]); setOpts((o.data ?? []) as ModifierOption[])
  }, [tn.id])
  useEffect(() => { void load() }, [load])
  const ok = async (q: PromiseLike<{ error: { message: string } | null }>) => { const r = await q; setErr(r.error?.message ?? null); await load() }
  const stockItems = items.filter((i) => i.track_stock && !i.is_template)
  return (
    <Modal title={t('Add-ons')} onClose={onClose} wide>
      <div className="stack">
        <p className="muted small">{t('Example: “Size” (choose exactly 1: Small, Large +0.500), “Milk” (optional: Oat milk +0.250, uses 0.2 l of oat milk from stock), “Gift wrap”.')}</p>
        {groups.map((g) => (
          <div key={g.id} className="card mod-group">
            <div className="row wrap">
              <input aria-label={t('Group name')} defaultValue={g.name} onBlur={(e) => void ok(supabase.from('modifier_groups').update({ name: e.target.value }).eq('id', g.id))} />
              <input aria-label={t('Arabic name')} dir="rtl" defaultValue={g.name_ar ?? ''} placeholder={t('Arabic name')} onBlur={(e) => void ok(supabase.from('modifier_groups').update({ name_ar: e.target.value || null }).eq('id', g.id))} />
              <label className="field inline"><span>{t('Min')}</span><input className="qty-in" type="number" min={0} defaultValue={g.min_select} onBlur={(e) => void ok(supabase.from('modifier_groups').update({ min_select: Number(e.target.value) }).eq('id', g.id))} /></label>
              <label className="field inline"><span>{t('Max')}</span><input className="qty-in" type="number" min={1} defaultValue={g.max_select} onBlur={(e) => void ok(supabase.from('modifier_groups').update({ max_select: Number(e.target.value) }).eq('id', g.id))} /></label>
              <button className="ghost small danger" aria-label={t('Delete')} onClick={() => void ok(supabase.from('modifier_groups').delete().eq('id', g.id))}><Trash2 size={14} /></button>
            </div>
            <table className="list compact">
              <thead><tr><th>{t('Option')}</th><th>{t('Arabic name')}</th><th className="num">{t('Extra price')}</th><th>{t('Uses from stock')}</th><th className="num">{t('Qty')}</th><th /></tr></thead>
              <tbody>{opts.filter((o) => o.group_id === g.id).map((o) => (
                <tr key={o.id}>
                  <td><input defaultValue={o.name} onBlur={(e) => void ok(supabase.from('modifier_options').update({ name: e.target.value }).eq('id', o.id))} /></td>
                  <td><input dir="rtl" defaultValue={o.name_ar ?? ''} onBlur={(e) => void ok(supabase.from('modifier_options').update({ name_ar: e.target.value || null }).eq('id', o.id))} /></td>
                  <td><input className="qty-in" inputMode="decimal" defaultValue={num(o.price, decimals)} onBlur={(e) => void ok(supabase.from('modifier_options').update({ price: toMinor(e.target.value || '0', decimals) }).eq('id', o.id))} /></td>
                  <td><select defaultValue={o.item_id ?? ''} onChange={(e) => void ok(supabase.from('modifier_options').update({ item_id: e.target.value || null }).eq('id', o.id))}>
                    <option value="">—</option>{stockItems.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}</select></td>
                  <td><input className="qty-in" inputMode="decimal" defaultValue={String(o.qty)} onBlur={(e) => void ok(supabase.from('modifier_options').update({ qty: Number(e.target.value) || 0 }).eq('id', o.id))} /></td>
                  <td><button className="ghost small danger" aria-label={t('Delete')} onClick={() => void ok(supabase.from('modifier_options').delete().eq('id', o.id))}><Trash2 size={14} /></button></td>
                </tr>))}</tbody>
            </table>
            <AddOption onAdd={(name, price) => void ok(supabase.from('modifier_options').insert({ tenant_id: tn.id, group_id: g.id, name, price: toMinor(price || '0', decimals), sort: opts.filter((o) => o.group_id === g.id).length }))} />
          </div>
        ))}
        <AddGroup onAdd={(name, min, max) => void ok(supabase.from('modifier_groups').insert({ tenant_id: tn.id, name, min_select: min, max_select: max, sort: groups.length }))} />
        {err && <p className="error">{t(err)}</p>}
        <div className="row end"><button className="primary" onClick={onClose}>{t('Done')}</button></div>
      </div>
    </Modal>
  )
}

function AddOption({ onAdd }: { onAdd: (name: string, price: string) => void }) {
  const { t } = useT()
  const [n, setN] = useState(''); const [p, setP] = useState('')
  return (
    <form className="row" onSubmit={(e) => { e.preventDefault(); if (n.trim()) { onAdd(n.trim(), p); setN(''); setP('') } }}>
      <input aria-label={t('New option')} placeholder={t('New option, e.g. Large')} value={n} onChange={(e) => setN(e.target.value)} />
      <input aria-label={t('Extra price')} className="qty-in" inputMode="decimal" placeholder="0.000" value={p} onChange={(e) => setP(e.target.value)} />
      <button className="ghost small"><Plus size={14} />{t('Add')}</button>
    </form>
  )
}
function AddGroup({ onAdd }: { onAdd: (name: string, min: number, max: number) => void }) {
  const { t } = useT()
  const [n, setN] = useState(''); const [req, setReq] = useState(true); const [multi, setMulti] = useState(false)
  return (
    <form className="row wrap card" onSubmit={(e) => { e.preventDefault(); if (n.trim()) { onAdd(n.trim(), req ? 1 : 0, multi ? 10 : 1); setN('') } }}>
      <input id="mod-group-name" placeholder={t('New group, e.g. Size')} value={n} onChange={(e) => setN(e.target.value)} />
      <label className="check"><input type="checkbox" checked={req} onChange={(e) => setReq(e.target.checked)} />{t('Required')}</label>
      <label className="check"><input type="checkbox" checked={multi} onChange={(e) => setMulti(e.target.checked)} />{t('Several allowed')}</label>
      <button className="primary small"><Plus size={14} />{t('Add group')}</button>
    </form>
  )
}

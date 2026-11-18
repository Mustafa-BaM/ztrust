import { useCallback, useEffect, useMemo, useState } from 'react'
import { Empty, Modal } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { norm } from '../lib/shift'
import { rpc, supabase } from '../lib/supabase'
import type { Category, Item } from '../lib/types'

/** Minimal CSV parser (quoted fields, commas, newlines). */
function parseCsv(text: string): string[][] {
  const rows: string[][] = []; let row: string[] = []; let cell = ''; let q = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (q) { if (c === '"' && text[i + 1] === '"') { cell += '"'; i++ } else if (c === '"') q = false; else cell += c }
    else if (c === '"') q = true
    else if (c === ',' || c === ';' || c === '\t') { row.push(cell); cell = '' }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = '' }
    else cell += c
  }
  if (cell || row.length) { row.push(cell); rows.push(row) }
  return rows.filter((r) => r.some((x) => x.trim()))
}

export default function Products() {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const tenant = s.tenant!
  const d = tenant.currency_decimals
  const canEdit = s.can('catalog.manage')
  const canCost = s.can('reports.costs') || s.can('catalog.manage')
  const [items, setItems] = useState<Item[]>([])
  const [cats, setCats] = useState<Category[]>([])
  const [stock, setStock] = useState<Record<string, number>>({})
  const [q, setQ] = useState('')
  const [edit, setEdit] = useState<Partial<Item> | null>(null)
  const [stockFor, setStockFor] = useState<Item | null>(null)
  const [importMsg, setImportMsg] = useState<string | null>(null)

  const load = useCallback(async () => {
    const [i, c, st] = await Promise.all([
      supabase.from('items').select('*').eq('tenant_id', tenant.id).order('name'),
      supabase.from('categories').select('*').eq('tenant_id', tenant.id).order('sort'),
      s.branch ? supabase.from('v_stock_levels').select('item_id, qty').eq('branch_id', s.branch.id) : Promise.resolve({ data: [] }),
    ])
    setItems((i.data ?? []) as Item[]); setCats((c.data ?? []) as Category[])
    const m: Record<string, number> = {}; for (const r of (st.data ?? []) as { item_id: string; qty: number }[]) m[r.item_id] = Number(r.qty)
    setStock(m)
  }, [tenant.id, s.branch])
  useEffect(() => { void load() }, [load])

  const shown = useMemo(() => { const n = norm(q); return items.filter((i) => !n || norm(i.name).includes(n) || norm(i.name_ar ?? '').includes(n) || i.barcode === q) }, [items, q])

  async function importFile(f: File) {
    setImportMsg(null)
    const rows = parseCsv(await f.text())
    const head = rows.shift()?.map((h) => norm(h)) ?? []
    const col = (...names: string[]) => head.findIndex((h) => names.includes(h))
    const ci = { name: col('name', 'الاسم'), name_ar: col('name_ar', 'arabic name', 'الاسم بالعربي'), price: col('price', 'السعر'), cost: col('cost', 'التكلفه'),
      barcode: col('barcode', 'الباركود'), sku: col('sku'), category: col('category', 'التصنيف') }
    if (ci.name < 0 || ci.price < 0) { setImportMsg(t('The file needs at least "name" and "price" columns.')); return }
    const catByName = new Map(cats.map((c) => [norm(c.name), c.id]))
    for (const r of rows) {
      const cn = ci.category >= 0 ? r[ci.category]?.trim() : ''
      if (cn && !catByName.has(norm(cn))) {
        const { data } = await supabase.from('categories').insert({ tenant_id: tenant.id, name: cn }).select().single()
        if (data) catByName.set(norm(cn), data.id)
      }
    }
    const payload = rows.map((r) => ({
      tenant_id: tenant.id, name: r[ci.name]?.trim(), name_ar: ci.name_ar >= 0 ? r[ci.name_ar]?.trim() || null : null,
      price: toMinor(r[ci.price] ?? '0', d), cost: ci.cost >= 0 ? toMinor(r[ci.cost] || '0', d) : 0,
      barcode: ci.barcode >= 0 ? r[ci.barcode]?.trim() || null : null, sku: ci.sku >= 0 ? r[ci.sku]?.trim() || null : null,
      category_id: ci.category >= 0 && r[ci.category]?.trim() ? catByName.get(norm(r[ci.category])) ?? null : null,
    })).filter((x) => x.name && Number.isFinite(x.price))
    const { error } = await supabase.from('items').insert(payload)
    setImportMsg(error ? error.message : t('{n} products imported', { n: payload.length }))
    await load()
  }

  return (
    <div className="page">
      <div className="row between wrap"><h1>{t('Products')}</h1>
        {canEdit && <div className="row">
          <label className="button">{t('Import CSV / Excel export')}<input id="import-file" type="file" accept=".csv,.txt" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) void importFile(f); e.target.value = '' }} /></label>
          <button className="primary" onClick={() => setEdit({ price: 0, cost: 0, track_stock: true, is_active: true })}>{t('Add product')}</button>
        </div>}
      </div>
      {importMsg && <p className="muted">{importMsg}</p>}
      <input id="products-q" className="search" placeholder={t('Search name or barcode')} value={q} onChange={(e) => setQ(e.target.value)} />
      {shown.length === 0 ? <Empty title={t('No products yet.')} hint={t('Add products one by one or import a CSV with columns name, name_ar, price, cost, barcode, sku, category.')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>{t('Category')}</th><th>{t('Barcode')}</th><th className="num">{t('Price')}</th>{canCost && <th className="num">{t('Cost')}</th>}<th className="num">{t('Stock')}</th><th /></tr></thead>
          <tbody>{shown.map((i) => (
            <tr key={i.id} className={i.is_active ? '' : 'dim'}>
              <td>{nameOf(i)}</td><td>{nameOf(cats.find((c) => c.id === i.category_id))}</td><td className="mono">{i.barcode}</td>
              <td className="num">{num(i.price, d)}</td>{canCost && <td className="num">{num(i.cost, d)}</td>}
              <td className={`num ${(stock[i.id] ?? 0) <= 0 && i.track_stock ? 'bad' : ''}`}>{i.track_stock ? stock[i.id] ?? 0 : '—'}</td>
              <td className="row end">{canEdit && <button className="ghost small" onClick={() => setEdit(i)}>{t('Edit')}</button>}
                {i.track_stock && s.can('inventory.adjust') && <button className="ghost small" onClick={() => setStockFor(i)}>{t('Stock')}</button>}</td>
            </tr>))}</tbody>
        </table></div>
      )}
      {edit && <ItemForm item={edit} cats={cats} decimals={d} canCost={canCost} onClose={() => setEdit(null)} onSaved={async () => { setEdit(null); await load() }} />}
      {stockFor && <StockForm item={stockFor} decimals={d} onClose={() => setStockFor(null)} onSaved={async () => { setStockFor(null); await load() }} />}
    </div>
  )
}

function ItemForm({ item, cats, decimals, canCost, onClose, onSaved }: { item: Partial<Item>; cats: Category[]; decimals: number; canCost: boolean; onClose: () => void; onSaved: () => void }) {
  const { t } = useT()
  const s = useSession()
  const [f, setF] = useState({
    name: item.name ?? '', name_ar: item.name_ar ?? '', barcode: item.barcode ?? '', sku: item.sku ?? '',
    price: num(item.price ?? 0, decimals), cost: num(item.cost ?? 0, decimals), category_id: item.category_id ?? '',
    tax_rate: item.tax_rate == null ? '' : String(item.tax_rate), track_stock: item.track_stock ?? true, is_active: item.is_active ?? true, newCat: '',
  })
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    let category_id = f.category_id || null
    if (f.newCat.trim()) {
      const { data, error } = await supabase.from('categories').insert({ tenant_id: s.tenant!.id, name: f.newCat.trim() }).select().single()
      if (error) return setErr(error.message)
      category_id = data.id
    }
    const row = { tenant_id: s.tenant!.id, name: f.name.trim(), name_ar: f.name_ar.trim() || null, barcode: f.barcode.trim() || null, sku: f.sku.trim() || null,
      price: toMinor(f.price, decimals), ...(canCost ? { cost: toMinor(f.cost || '0', decimals) } : {}), category_id,
      tax_rate: f.tax_rate === '' ? null : Number(f.tax_rate), track_stock: f.track_stock, is_active: f.is_active }
    if (!Number.isFinite(row.price)) return setErr(t('Enter a valid price'))
    const r = item.id ? await supabase.from('items').update(row).eq('id', item.id) : await supabase.from('items').insert(row)
    if (r.error) setErr(r.error.message); else onSaved()
  }
  const set = (k: keyof typeof f, v: string | boolean) => setF({ ...f, [k]: v })
  return (
    <Modal title={item.id ? t('Edit product') : t('Add product')} onClose={onClose} wide>
      <form className="grid2" onSubmit={save}>
        <label className="field"><span>{t('Name (English)')}</span><input id="item-name" required value={f.name} onChange={(e) => set('name', e.target.value)} /></label>
        <label className="field"><span>{t('Name (Arabic)')}</span><input id="item-name-ar" dir="rtl" value={f.name_ar} onChange={(e) => set('name_ar', e.target.value)} /></label>
        <label className="field"><span>{t('Price')}</span><input id="item-price" inputMode="decimal" required value={f.price} onChange={(e) => set('price', e.target.value)} /></label>
        {canCost && <label className="field"><span>{t('Cost')}</span><input id="item-cost" inputMode="decimal" value={f.cost} onChange={(e) => set('cost', e.target.value)} /></label>}
        <label className="field"><span>{t('Barcode')}</span><input id="item-barcode" value={f.barcode} onChange={(e) => set('barcode', e.target.value)} /></label>
        <label className="field"><span>SKU</span><input id="item-sku" value={f.sku} onChange={(e) => set('sku', e.target.value)} /></label>
        <label className="field"><span>{t('Category')}</span>
          <select id="item-cat" value={f.category_id} onChange={(e) => set('category_id', e.target.value)}>
            <option value="">—</option>{cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select></label>
        <label className="field"><span>{t('Or new category')}</span><input id="item-newcat" value={f.newCat} onChange={(e) => set('newCat', e.target.value)} /></label>
        <label className="field"><span>{t('VAT % (blank = business default)')}</span><input id="item-tax" inputMode="decimal" value={f.tax_rate} onChange={(e) => set('tax_rate', e.target.value)} /></label>
        <div className="stack">
          <label className="check"><input id="item-track" type="checkbox" checked={f.track_stock} onChange={(e) => set('track_stock', e.target.checked)} />{t('Track stock')}</label>
          <label className="check"><input id="item-active" type="checkbox" checked={f.is_active} onChange={(e) => set('is_active', e.target.checked)} />{t('Active (shown on POS)')}</label>
        </div>
        {err && <p className="error span2">{err}</p>}
        <div className="row end span2"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

function StockForm({ item, decimals, onClose, onSaved }: { item: Item; decimals: number; onClose: () => void; onSaved: () => void }) {
  const { t } = useT()
  const s = useSession()
  const [kind, setKind] = useState<'receive' | 'adjust'>('receive')
  const [qty, setQty] = useState('')
  const [cost, setCost] = useState(num(item.cost, decimals))
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try {
      if (kind === 'receive') await rpc('receive_stock', { p_branch: s.branch!.id, p_item: item.id, p_qty: Number(qty), p_unit_cost: toMinor(cost, decimals), p_note: note || null })
      else await rpc('adjust_stock', { p_branch: s.branch!.id, p_item: item.id, p_qty: Number(qty), p_note: note || null })
      onSaved()
    } catch (x) { setErr((x as Error).message) }
  }
  return (
    <Modal title={`${t('Stock')} · ${item.name}`} onClose={onClose}>
      <form className="stack" onSubmit={save}>
        <div className="seg"><button type="button" className={kind === 'receive' ? 'on' : ''} onClick={() => setKind('receive')}>{t('Receive from supplier')}</button>
          <button type="button" className={kind === 'adjust' ? 'on' : ''} onClick={() => setKind('adjust')}>{t('Adjust (+/−)')}</button></div>
        <label className="field"><span>{t('Quantity')}</span><input id="stock-qty" inputMode="decimal" required value={qty} onChange={(e) => setQty(e.target.value)} /></label>
        {kind === 'receive' && <label className="field"><span>{t('Unit cost')}</span><input id="stock-cost" inputMode="decimal" value={cost} onChange={(e) => setCost(e.target.value)} /></label>}
        <label className="field"><span>{t('Note')}</span><input id="stock-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder={kind === 'adjust' ? t('e.g. damaged, count correction') : t('Supplier invoice number')} /></label>
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

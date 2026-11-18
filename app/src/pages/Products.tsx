import { ChefHat, ImagePlus, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Empty, Modal } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { norm } from '../lib/shift'
import { supabase, uuid } from '../lib/supabase'
import type { Category, Item } from '../lib/types'

const UNITS = ['pcs', 'kg', 'g', 'l', 'ml', 'box', 'pack']
type Kind = 'all' | 'standard' | 'recipe' | 'ingredient'

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

/** Resizes a photo to max 512 px WebP (≈20–60 KB) so the POS stays fast and images cache offline. */
async function compress(file: File): Promise<Blob> {
  const bmp = await createImageBitmap(file)
  const scale = Math.min(1, 512 / Math.max(bmp.width, bmp.height))
  const c = document.createElement('canvas'); c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale)
  c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height)
  return new Promise((res, rej) => c.toBlob((b) => (b ? res(b) : rej(new Error('image'))), 'image/webp', 0.82))
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
  const [rcost, setRcost] = useState<Record<string, number>>({})
  const [q, setQ] = useState('')
  const [kind, setKind] = useState<Kind>('all')
  const [edit, setEdit] = useState<Partial<Item> | null>(null)
  const [recipeFor, setRecipeFor] = useState<Item | null>(null)
  const [importMsg, setImportMsg] = useState<string | null>(null)

  const load = useCallback(async () => {
    const [i, c, st, rl] = await Promise.all([
      supabase.from('items').select('*').eq('tenant_id', tenant.id).order('name'),
      supabase.from('categories').select('*').eq('tenant_id', tenant.id).order('sort'),
      s.branch ? supabase.from('v_stock_levels').select('item_id, qty').eq('branch_id', s.branch.id) : Promise.resolve({ data: [] }),
      supabase.from('recipe_lines').select('item_id, qty, ingredient_id').eq('tenant_id', tenant.id),
    ])
    const list = (i.data ?? []) as Item[]
    setItems(list); setCats((c.data ?? []) as Category[])
    const m: Record<string, number> = {}; for (const r of (st.data ?? []) as { item_id: string; qty: number }[]) m[r.item_id] = Number(r.qty)
    setStock(m)
    const costOf = new Map(list.map((x) => [x.id, x.cost]))
    const rc: Record<string, number> = {}
    for (const r of (rl.data ?? []) as { item_id: string; qty: number; ingredient_id: string }[]) rc[r.item_id] = (rc[r.item_id] ?? 0) + Math.round(Number(r.qty) * (costOf.get(r.ingredient_id) ?? 0))
    setRcost(rc)
  }, [tenant.id, s.branch])
  useEffect(() => { void load() }, [load])

  const shown = useMemo(() => {
    const n = norm(q)
    return items.filter((i) => (kind === 'all' || (i.item_type ?? 'standard') === kind) && (!n || norm(i.name).includes(n) || norm(i.name_ar ?? '').includes(n) || i.barcode === q))
  }, [items, q, kind])

  async function importFile(f: File) {
    setImportMsg(null)
    const rows = parseCsv(await f.text())
    const head = rows.shift()?.map((h) => norm(h)) ?? []
    const col = (...names: string[]) => head.findIndex((h) => names.includes(h))
    const ci = { name: col('name', 'الاسم'), name_ar: col('name_ar', 'arabic name', 'الاسم بالعربي'), price: col('price', 'السعر'), cost: col('cost', 'التكلفه'),
      barcode: col('barcode', 'الباركود'), sku: col('sku'), category: col('category', 'التصنيف'), type: col('type', 'item_type', 'النوع'), unit: col('unit', 'الوحده') }
    if (ci.name < 0 || ci.price < 0) { setImportMsg(t('The file needs at least "name" and "price" columns.')); return }
    const catByName = new Map(cats.map((c) => [norm(c.name), c.id]))
    for (const r of rows) {
      const cn = ci.category >= 0 ? r[ci.category]?.trim() : ''
      if (cn && !catByName.has(norm(cn))) { const { data } = await supabase.from('categories').insert({ tenant_id: tenant.id, name: cn }).select().single(); if (data) catByName.set(norm(cn), data.id) }
    }
    const payload = rows.map((r) => ({
      tenant_id: tenant.id, name: r[ci.name]?.trim(), name_ar: ci.name_ar >= 0 ? r[ci.name_ar]?.trim() || null : null,
      price: toMinor(r[ci.price] ?? '0', d), cost: ci.cost >= 0 ? toMinor(r[ci.cost] || '0', d) : 0,
      barcode: ci.barcode >= 0 ? r[ci.barcode]?.trim() || null : null, sku: ci.sku >= 0 ? r[ci.sku]?.trim() || null : null,
      category_id: ci.category >= 0 && r[ci.category]?.trim() ? catByName.get(norm(r[ci.category])) ?? null : null,
      item_type: ci.type >= 0 && ['standard', 'ingredient', 'recipe'].includes(r[ci.type]?.trim()) ? r[ci.type].trim() : 'standard',
      unit: ci.unit >= 0 && UNITS.includes(r[ci.unit]?.trim()) ? r[ci.unit].trim() : 'pcs',
    })).filter((x) => x.name && Number.isFinite(x.price))
    const { error } = await supabase.from('items').insert(payload)
    setImportMsg(error ? error.message : t('{n} products imported', { n: payload.length }))
    await load()
  }

  const typeLabel = { standard: 'Product', recipe: 'Recipe', ingredient: 'Ingredient' } as const
  return (
    <div className="page">
      <div className="row between wrap"><h1>{t('Products')}</h1>
        <div className="seg">{(['all', 'standard', 'recipe', 'ingredient'] as Kind[]).map((k) => (
          <button key={k} className={kind === k ? 'on' : ''} onClick={() => setKind(k)}>{t({ all: 'All', standard: 'Products', recipe: 'Recipes', ingredient: 'Ingredients' }[k])}</button>))}</div>
        {canEdit && <div className="row">
          <label className="button">{t('Import CSV / Excel export')}<input id="import-file" type="file" accept=".csv,.txt" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) void importFile(f); e.target.value = '' }} /></label>
          <button className="primary" onClick={() => setEdit({ price: 0, cost: 0, track_stock: true, is_active: true, item_type: kind === 'all' ? 'standard' : kind, unit: kind === 'ingredient' ? 'kg' : 'pcs' })}>{t('Add item')}</button>
        </div>}
      </div>
      {importMsg && <p className="muted">{importMsg}</p>}
      <input id="products-q" className="search" placeholder={t('Search name or barcode')} value={q} onChange={(e) => setQ(e.target.value)} />
      {shown.length === 0 ? <Empty title={t('No products yet.')} hint={t('Add items one by one or import a CSV with columns name, name_ar, price, cost, barcode, sku, category, type, unit.')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th /><th>{t('Name')}</th><th>{t('Type')}</th><th>{t('Category')}</th><th className="num">{t('Price')}</th>{canCost && <th className="num">{t('Cost')}</th>}{canCost && <th className="num">{t('Margin')}</th>}<th className="num">{t('Stock')}</th><th /></tr></thead>
          <tbody>{shown.map((i) => {
            const type = i.item_type ?? 'standard'
            const cost = type === 'recipe' ? rcost[i.id] ?? 0 : i.cost
            const margin = i.price > 0 && type !== 'ingredient' ? Math.round(((i.price - cost) / i.price) * 1000) / 10 : null
            const low = i.track_stock && i.reorder_point != null && (stock[i.id] ?? 0) <= Number(i.reorder_point)
            return (
              <tr key={i.id} className={i.is_active ? '' : 'dim'}>
                <td className="thumb-cell">{i.image_url ? <img className="thumb" src={i.image_url} alt="" loading="lazy" /> : <span className="thumb mono-thumb">{nameOf(i).charAt(0)}</span>}</td>
                <td>{nameOf(i)}{i.barcode && <div className="muted small mono">{i.barcode}</div>}</td>
                <td><span className={`pill type-${type}`}>{t(typeLabel[type])}</span></td>
                <td>{nameOf(cats.find((c) => c.id === i.category_id))}</td>
                <td className="num">{type === 'ingredient' ? '—' : num(i.price, d)}</td>
                {canCost && <td className="num">{num(cost, d)}{type !== 'recipe' && <span className="muted small"> /{t(i.unit ?? 'pcs')}</span>}</td>}
                {canCost && <td className={`num ${margin != null && margin < 50 ? 'bad' : ''}`}>{margin == null ? '—' : `${margin}%`}</td>}
                <td className={`num ${low || ((stock[i.id] ?? 0) <= 0 && i.track_stock) ? 'bad' : ''}`}>{i.track_stock ? `${stock[i.id] ?? 0} ${t(i.unit ?? 'pcs')}` : '—'}</td>
                <td className="row end">
                  {type === 'recipe' && canEdit && <button className="ghost small" onClick={() => setRecipeFor(i)}><ChefHat size={15} />{t('Recipe')}</button>}
                  {canEdit && <button className="ghost small" onClick={() => setEdit(i)}>{t('Edit')}</button>}
                </td>
              </tr>)
          })}</tbody>
        </table></div>
      )}
      {edit && <ItemForm item={edit} cats={cats} decimals={d} canCost={canCost} onClose={() => setEdit(null)}
        onSaved={async (saved) => { setEdit(null); await load(); if (saved?.item_type === 'recipe' && !edit.id) setRecipeFor(saved) }} />}
      {recipeFor && <RecipeEditor item={recipeFor} items={items} decimals={d} onClose={() => setRecipeFor(null)} onSaved={async () => { setRecipeFor(null); await load() }} />}
    </div>
  )
}

function ItemForm({ item, cats, decimals, canCost, onClose, onSaved }: { item: Partial<Item>; cats: Category[]; decimals: number; canCost: boolean; onClose: () => void; onSaved: (i: Item | null) => void }) {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [f, setF] = useState({
    name: item.name ?? '', name_ar: item.name_ar ?? '', barcode: item.barcode ?? '', sku: item.sku ?? '',
    price: num(item.price ?? 0, decimals), cost: num(item.cost ?? 0, decimals), category_id: item.category_id ?? '',
    tax_rate: item.tax_rate == null ? '' : String(item.tax_rate), track_stock: item.track_stock ?? true, is_active: item.is_active ?? true, newCat: '',
    item_type: item.item_type ?? 'standard', unit: item.unit ?? 'pcs', reorder_point: item.reorder_point == null ? '' : String(item.reorder_point),
    image_url: item.image_url ?? null as string | null,
  })
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const set = (k: keyof typeof f, v: string | boolean | null) => setF({ ...f, [k]: v })
  const isIng = f.item_type === 'ingredient', isRecipe = f.item_type === 'recipe'

  async function upload(file: File) {
    setBusy(true); setErr(null)
    try {
      const blob = await compress(file)
      const path = `${tn.id}/${uuid()}.webp`
      const { error } = await supabase.storage.from('item-images').upload(path, blob, { contentType: 'image/webp', cacheControl: '31536000' })
      if (error) throw error
      set('image_url', supabase.storage.from('item-images').getPublicUrl(path).data.publicUrl)
    } catch (x) { setErr((x as Error).message) } finally { setBusy(false) }
  }

  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    let category_id = f.category_id || null
    if (f.newCat.trim()) {
      const { data, error } = await supabase.from('categories').insert({ tenant_id: tn.id, name: f.newCat.trim() }).select().single()
      if (error) return setErr(error.message)
      category_id = data.id
    }
    const row = { tenant_id: tn.id, name: f.name.trim(), name_ar: f.name_ar.trim() || null, barcode: f.barcode.trim() || null, sku: f.sku.trim() || null,
      price: isIng ? 0 : toMinor(f.price, decimals), ...(canCost && !isRecipe ? { cost: toMinor(f.cost || '0', decimals) } : {}), category_id,
      tax_rate: f.tax_rate === '' ? null : Number(f.tax_rate), track_stock: isRecipe ? false : isIng ? true : f.track_stock, is_active: f.is_active,
      item_type: f.item_type, unit: f.unit, reorder_point: f.reorder_point === '' ? null : Number(f.reorder_point), image_url: f.image_url }
    if (!Number.isFinite(row.price)) return setErr(t('Enter a valid price'))
    const r = item.id ? await supabase.from('items').update(row).eq('id', item.id).select().single() : await supabase.from('items').insert(row).select().single()
    if (r.error) setErr(r.error.message); else onSaved(r.data as Item)
  }
  return (
    <Modal title={item.id ? t('Edit item') : t('Add item')} onClose={onClose} wide>
      <form className="grid2" onSubmit={save}>
        <div className="span2 seg type-seg">{(['standard', 'recipe', 'ingredient'] as const).map((k) => (
          <button type="button" key={k} className={f.item_type === k ? 'on' : ''} onClick={() => setF({ ...f, item_type: k, unit: k === 'ingredient' && f.unit === 'pcs' ? 'kg' : f.unit })}>
            {t({ standard: 'Product (sold and stocked)', recipe: 'Recipe (sold, uses ingredients)', ingredient: 'Ingredient (stocked, not sold)' }[k])}</button>))}</div>
        <div className="img-field span2">
          {f.image_url ? <img src={f.image_url} alt="" className="img-preview" /> : <div className="img-preview empty"><ImagePlus size={28} /></div>}
          <div className="stack">
            <label className="button">{busy ? t('Please wait…') : f.image_url ? t('Change photo') : t('Add photo')}
              <input id="item-image" type="file" accept="image/*" hidden onChange={(e) => { const x = e.target.files?.[0]; if (x) void upload(x); e.target.value = '' }} /></label>
            {f.image_url && <button type="button" className="ghost small" onClick={() => set('image_url', null)}><Trash2 size={14} />{t('Remove photo')}</button>}
            <span className="muted small">{t('Optional. Shown on the POS when "Show product photos" is on in Settings.')}</span>
          </div>
        </div>
        <label className="field"><span>{t('Name (English)')}</span><input id="item-name" required value={f.name} onChange={(e) => set('name', e.target.value)} /></label>
        <label className="field"><span>{t('Name (Arabic)')}</span><input id="item-name-ar" dir="rtl" value={f.name_ar} onChange={(e) => set('name_ar', e.target.value)} /></label>
        {!isIng && <label className="field"><span>{t('Price')}</span><input id="item-price" inputMode="decimal" required value={f.price} onChange={(e) => set('price', e.target.value)} /></label>}
        {canCost && !isRecipe && <label className="field"><span>{isIng ? t('Cost per unit') : t('Cost')}</span><input id="item-cost" inputMode="decimal" value={f.cost} onChange={(e) => set('cost', e.target.value)} /></label>}
        {isRecipe && <p className="muted small span2">{t('Recipe cost is calculated from its ingredients. Save, then add the ingredients.')}</p>}
        <label className="field"><span>{t('Unit')}</span><select id="item-unit" value={f.unit} onChange={(e) => set('unit', e.target.value)}>{UNITS.map((u) => <option key={u} value={u}>{t(u)}</option>)}</select></label>
        {!isRecipe && <label className="field"><span>{t('Reorder when stock falls to')}</span><input id="item-reorder" inputMode="decimal" value={f.reorder_point} onChange={(e) => set('reorder_point', e.target.value)} /></label>}
        <label className="field"><span>{t('Barcode')}</span><input id="item-barcode" value={f.barcode} onChange={(e) => set('barcode', e.target.value)} /></label>
        <label className="field"><span>SKU</span><input id="item-sku" value={f.sku} onChange={(e) => set('sku', e.target.value)} /></label>
        <label className="field"><span>{t('Category')}</span>
          <select id="item-cat" value={f.category_id} onChange={(e) => set('category_id', e.target.value)}><option value="">—</option>{cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
        <label className="field"><span>{t('Or new category')}</span><input id="item-newcat" value={f.newCat} onChange={(e) => set('newCat', e.target.value)} /></label>
        {!isIng && <label className="field"><span>{t('VAT % (blank = business default)')}</span><input id="item-tax" inputMode="decimal" value={f.tax_rate} onChange={(e) => set('tax_rate', e.target.value)} /></label>}
        <div className="stack">
          {f.item_type === 'standard' && <label className="check"><input id="item-track" type="checkbox" checked={f.track_stock} onChange={(e) => set('track_stock', e.target.checked)} />{t('Track stock')}</label>}
          <label className="check"><input id="item-active" type="checkbox" checked={f.is_active} onChange={(e) => set('is_active', e.target.checked)} />{isIng ? t('Active') : t('Active (shown on POS)')}</label>
        </div>
        {err && <p className="error span2">{err}</p>}
        <div className="row end span2"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={busy}>{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

/** Ingredients per one sold item; the cost and margin update as you type. */
function RecipeEditor({ item, items, decimals, onClose, onSaved }: { item: Item; items: Item[]; decimals: number; onClose: () => void; onSaved: () => void }) {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const ingredients = items.filter((x) => x.id !== item.id && (x.item_type === 'ingredient' || (x.item_type ?? 'standard') === 'standard') && x.track_stock)
  const [lines, setLines] = useState<{ ingredient_id: string; qty: string }[]>([])
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => {
    void supabase.from('recipe_lines').select('ingredient_id, qty').eq('item_id', item.id).then(({ data }) =>
      setLines((data ?? []).map((r) => ({ ingredient_id: r.ingredient_id as string, qty: String(r.qty) })).concat([{ ingredient_id: '', qty: '' }])))
  }, [item.id])
  const ing = (id: string) => items.find((x) => x.id === id)
  const cost = lines.reduce((a, l) => a + Math.round((parseFloat(l.qty) || 0) * (ing(l.ingredient_id)?.cost ?? 0)), 0)
  const margin = item.price ? Math.round(((item.price - cost) / item.price) * 1000) / 10 : 0
  const set = (i: number, p: Partial<(typeof lines)[number]>) => setLines(lines.map((l, j) => (j === i ? { ...l, ...p } : l)))
  async function save() {
    setErr(null)
    const rows = lines.filter((l) => l.ingredient_id && parseFloat(l.qty) > 0).map((l) => ({ tenant_id: s.tenant!.id, item_id: item.id, ingredient_id: l.ingredient_id, qty: parseFloat(l.qty) }))
    const del = await supabase.from('recipe_lines').delete().eq('item_id', item.id)
    if (del.error) return setErr(del.error.message)
    if (rows.length) { const r = await supabase.from('recipe_lines').insert(rows); if (r.error) return setErr(r.error.message) }
    onSaved()
  }
  return (
    <Modal title={`${t('Recipe')} · ${nameOf(item)}`} onClose={onClose} wide>
      <div className="stack">
        <p className="muted small">{t('Quantities are for ONE sold item, in each ingredient\'s unit. Every sale deducts them from stock automatically.')}</p>
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Ingredient')}</th><th className="num">{t('Quantity')}</th><th>{t('Unit')}</th><th className="num">{t('Cost')}</th><th /></tr></thead>
          <tbody>{lines.map((l, i) => (
            <tr key={i}>
              <td><select id={`rc-ing-${i}`} value={l.ingredient_id} onChange={(e) => { set(i, { ingredient_id: e.target.value }); if (i === lines.length - 1 && e.target.value) setLines((cur) => [...cur.map((x, j) => (j === i ? { ...x, ingredient_id: e.target.value } : x)), { ingredient_id: '', qty: '' }]) }}>
                <option value="">—</option>{ingredients.map((x) => <option key={x.id} value={x.id}>{nameOf(x)}</option>)}</select></td>
              <td><input id={`rc-qty-${i}`} className="qty-in" inputMode="decimal" value={l.qty} onChange={(e) => set(i, { qty: e.target.value })} /></td>
              <td className="muted">{t(ing(l.ingredient_id)?.unit ?? '')}</td>
              <td className="num">{num(Math.round((parseFloat(l.qty) || 0) * (ing(l.ingredient_id)?.cost ?? 0)), decimals)}</td>
              <td>{l.ingredient_id && <button className="icon" aria-label={t('Remove')} onClick={() => setLines(lines.filter((_, j) => j !== i))}>✕</button>}</td>
            </tr>))}</tbody>
        </table></div>
        <div className="recipe-sum">
          <div><span>{t('Recipe cost')}</span><b>{num(cost, decimals)}</b></div>
          <div><span>{t('Price')}</span><b>{num(item.price, decimals)}</b></div>
          <div className={margin < 50 ? 'bad' : 'good'}><span>{t('Margin')}</span><b>{margin}%</b></div>
        </div>
        {err && <p className="error">{err}</p>}
        <div className="row end"><button className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" onClick={() => void save()}>{t('Save recipe')}</button></div>
      </div>
    </Modal>
  )
}



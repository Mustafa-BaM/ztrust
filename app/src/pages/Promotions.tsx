import { LoyaltySetup } from './promotions/Loyalty'
import { Plus, Tag, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Empty, Modal } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { parseError, supabase } from '../lib/supabase'
import type { Category, Item, Promotion } from '../lib/types'

const KINDS: { id: Promotion['kind']; label: string; hint: string }[] = [
  { id: 'percent', label: '% off', hint: 'e.g. 20% off all abayas, 10% off coffee before 10 am' },
  { id: 'bxgy', label: 'Buy X get Y', hint: 'e.g. pens 3 for 2, second drink half price' },
  { id: 'qty_tier', label: 'Quantity tiers', hint: 'e.g. 3+ pieces 10% off, 6+ pieces 20% off' },
  { id: 'threshold', label: 'Spend thresholds', hint: 'e.g. spend 20 get 5% off, spend 50 get 15% off' },
  { id: 'bundle', label: 'Bundle at a fixed price', hint: 'e.g. school kit, meal deal (burger + fries + drink)' },
  { id: 'amount', label: 'Amount off the bill', hint: 'e.g. 5 off when the bill is 30 or more, with a coupon code' },
]
const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

/** Promotions apply automatically at the till; the server checks every discount the till claims. */
export default function Promotions() {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [list, setList] = useState<Promotion[]>([])
  const [items, setItems] = useState<Item[]>([])
  const [cats, setCats] = useState<Category[]>([])
  const [edit, setEdit] = useState<Partial<Promotion> | null>(null)
  const load = useCallback(async () => {
    const [p, i, c] = await Promise.all([
      supabase.from('promotions').select('*').eq('tenant_id', tn.id).order('created_at', { ascending: false }),
      supabase.from('items').select('*').eq('tenant_id', tn.id).eq('is_active', true).neq('item_type', 'ingredient').order('name'),
      supabase.from('categories').select('*').eq('tenant_id', tn.id).order('sort'),
    ])
    setList((p.data ?? []) as Promotion[]); setItems((i.data ?? []) as Item[]); setCats((c.data ?? []) as Category[])
  }, [tn.id])
  useEffect(() => { void load() }, [load])
  const describe = (p: Promotion) => {
    const scope = p.item_ids?.length ? p.item_ids.map((id) => nameOf(items.find((i) => i.id === id))).join(', ') : p.category_ids?.length ? p.category_ids.map((id) => nameOf(cats.find((c) => c.id === id))).join(', ') : t('Everything')
    if (p.kind === 'percent') return `${p.params.percent}% · ${scope}`
    if (p.kind === 'bxgy') return `${t('Buy {b} get {g}', { b: p.params.buy ?? 1, g: p.params.get ?? 1 })}${p.params.percent !== 100 ? ` (${p.params.percent}%)` : ` ${t('free')}`} · ${scope}`
    if (p.kind === 'qty_tier') return `${(p.params.tiers ?? []).map((x) => `${x.qty}+ → ${x.percent}%`).join(' · ')} · ${scope}`
    if (p.kind === 'threshold') return (p.params.tiers ?? []).map((x) => `${num(x.min ?? 0, d)}+ → ${x.percent != null ? `${x.percent}%` : `−${num(x.amount ?? 0, d)}`}`).join(' · ')
    if (p.kind === 'bundle') return `${(p.params.components ?? []).map((c) => `${c.qty}× ${nameOf(items.find((i) => i.id === c.item_id))}`).join(' + ')} = ${num(p.params.price ?? 0, d)}`
    return `−${num(p.params.amount ?? 0, d)}${p.params.min_amount ? ` · ${t('bill from {v}', { v: num(p.params.min_amount, d) })}` : ''}`
  }
  const when = (p: Promotion) => [p.starts_on || p.ends_on ? `${p.starts_on ?? '…'} → ${p.ends_on ?? '…'}` : '', p.weekdays?.length ? p.weekdays.map((w) => t(DAYS[w - 1])).join(' ') : '',
    p.time_from || p.time_to ? `${(p.time_from ?? '00:00').slice(0, 5)}–${(p.time_to ?? '24:00').slice(0, 5)}` : ''].filter(Boolean).join(' · ') || t('Always')
  return (
    <div className="page">
      <div className="row between wrap"><h1>{t('Promotions')}</h1>
        {s.can('catalog.manage') && <button className="primary" onClick={() => setEdit({ kind: 'percent', params: { percent: 10 }, min_qty: 0, is_active: true })}><Plus size={16} />{t('New promotion')}</button>}</div>
      <p className="muted small">{t('Promotions apply by themselves at the till, need no manager PIN, and show on the receipt. If several fit one item, the customer gets the best one.')}</p>
      {list.length === 0 ? <Empty title={t('No promotions yet')} hint={t('Create a percentage, a buy X get Y, a bundle or a coupon.')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>{t('Rule')}</th><th>{t('When')}</th><th>{t('Coupon')}</th><th>{t('Status')}</th><th /></tr></thead>
          <tbody>{list.map((p) => (
            <tr key={p.id} className={p.is_active ? '' : 'dim'}>
              <td><Tag size={14} aria-hidden="true" /> <b>{nameOf(p)}</b></td><td className="small">{describe(p)}</td><td className="small">{when(p)}</td>
              <td className="mono small">{p.coupon_code ?? '—'}</td>
              <td><button role="switch" aria-checked={p.is_active} aria-label={t('Active')} className={`switch ${p.is_active ? 'on' : ''}`}
                onClick={() => void supabase.from('promotions').update({ is_active: !p.is_active }).eq('id', p.id).then(load)}><i /></button></td>
              <td><div className="row end"><button className="ghost small" onClick={() => setEdit(p)}>{t('Edit')}</button>
                <button className="ghost small danger" aria-label={t('Delete')} onClick={() => void supabase.from('promotions').delete().eq('id', p.id).then(load)}><Trash2 size={14} /></button></div></td>
            </tr>))}</tbody>
        </table></div>)}
      {s.can('catalog.manage') && <LoyaltySetup items={items} cats={cats} />}
      {edit && <PromoForm promo={edit} items={items} cats={cats} decimals={d} onClose={() => setEdit(null)} onSaved={async () => { setEdit(null); await load() }} />}
    </div>
  )
}

function PromoForm({ promo, items, cats, decimals, onClose, onSaved }: { promo: Partial<Promotion>; items: Item[]; cats: Category[]; decimals: number; onClose: () => void; onSaved: () => void }) {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const sellable = items.filter((i) => !i.parent_id || true)
  const [f, setF] = useState({
    name: promo.name ?? '', name_ar: promo.name_ar ?? '', kind: promo.kind ?? 'percent' as Promotion['kind'],
    percent: String(promo.params?.percent ?? (promo.kind === 'bxgy' ? 100 : 10)), amount: num(promo.params?.amount ?? 0, decimals), min_amount: num(promo.params?.min_amount ?? 0, decimals),
    buy: String(promo.params?.buy ?? 2), get: String(promo.params?.get ?? 1), price: num(promo.params?.price ?? 0, decimals),
    components: (promo.params?.components ?? []) as { item_id: string; qty: number }[],
    tiers: (promo.params?.tiers ?? (promo.kind === 'threshold' ? [{ min: 10 ** decimals * 20, percent: 5 }] : [{ qty: 3, percent: 10 }]))
      .map((x) => ({ at: x.qty != null ? String(x.qty) : num(x.min ?? 0, decimals), percent: x.percent != null ? String(x.percent) : '', amount: x.amount != null ? num(x.amount, decimals) : '' })),
    scope: promo.item_ids?.length ? 'items' : promo.category_ids?.length ? 'cats' : 'all', item_ids: promo.item_ids ?? [], category_ids: promo.category_ids ?? [],
    min_qty: String(promo.min_qty ?? 0), coupon_code: promo.coupon_code ?? '', starts_on: promo.starts_on ?? '', ends_on: promo.ends_on ?? '',
    weekdays: promo.weekdays ?? [], time_from: (promo.time_from ?? '').slice(0, 5), time_to: (promo.time_to ?? '').slice(0, 5),
  })
  const [pick, setPick] = useState('')
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    const params = f.kind === 'percent' ? { percent: Number(f.percent) } : f.kind === 'amount' ? { amount: toMinor(f.amount, decimals), min_amount: toMinor(f.min_amount || '0', decimals) }
      : f.kind === 'bxgy' ? { buy: Number(f.buy), get: Number(f.get), percent: Number(f.percent) }
      : f.kind === 'qty_tier' ? { tiers: f.tiers.filter((x) => x.at).map((x) => ({ qty: Number(x.at), percent: Number(x.percent || 0) })) }
      : f.kind === 'threshold' ? { tiers: f.tiers.filter((x) => x.at).map((x) => (x.percent ? { min: toMinor(x.at, decimals), percent: Number(x.percent) } : { min: toMinor(x.at, decimals), amount: toMinor(x.amount || '0', decimals) })) }
      : { price: toMinor(f.price, decimals), components: f.components }
    if (f.kind === 'bundle' && f.components.length < 2) return setErr(t('A bundle needs at least two items'))
    const row = { tenant_id: s.tenant!.id, name: f.name.trim(), name_ar: f.name_ar.trim() || null, kind: f.kind, params,
      item_ids: f.kind !== 'bundle' && f.scope === 'items' ? f.item_ids : null, category_ids: f.kind !== 'bundle' && f.scope === 'cats' ? f.category_ids : null,
      min_qty: Number(f.min_qty) || 0, coupon_code: f.coupon_code.trim().toUpperCase() || null, starts_on: f.starts_on || null, ends_on: f.ends_on || null,
      weekdays: f.weekdays.length ? f.weekdays : null, time_from: f.time_from || null, time_to: f.time_to || null }
    const r = promo.id ? await supabase.from('promotions').update(row).eq('id', promo.id) : await supabase.from('promotions').insert(row)
    if (r.error) { const p = parseError(r.error); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) } else onSaved()
  }
  const toggle = (arr: string[], v: string) => (arr.includes(v) ? arr.filter((x) => x !== v) : [...arr, v])
  return (
    <Modal title={promo.id ? t('Edit promotion') : t('New promotion')} onClose={onClose} wide>
      <form className="grid2" onSubmit={save}>
        <div className="span2 kind-grid">{KINDS.map((k) => (
          <button type="button" key={k.id} className={`choice ${f.kind === k.id ? 'on' : ''}`} aria-pressed={f.kind === k.id}
            onClick={() => setF({ ...f, kind: k.id, percent: k.id === 'bxgy' ? '100' : f.percent })}><b>{t(k.label)}</b><span>{t(k.hint)}</span></button>))}</div>
        <label className="field"><span>{t('Name (shown on the receipt)')}</span><input id="promo-name" required value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>{t('Name (Arabic)')}</span><input id="promo-name-ar" dir="rtl" value={f.name_ar} onChange={(e) => setF({ ...f, name_ar: e.target.value })} /></label>
        {f.kind === 'percent' && <label className="field"><span>{t('Percent off')}</span><input id="promo-percent" type="number" min={1} max={100} value={f.percent} onChange={(e) => setF({ ...f, percent: e.target.value })} /></label>}
        {f.kind === 'bxgy' && <>
          <label className="field"><span>{t('Buy')}</span><input id="promo-buy" type="number" min={1} value={f.buy} onChange={(e) => setF({ ...f, buy: e.target.value })} /></label>
          <label className="field"><span>{t('Get')}</span><input id="promo-get" type="number" min={1} value={f.get} onChange={(e) => setF({ ...f, get: e.target.value })} /></label>
          <label className="field"><span>{t('At % off (100 = free)')}</span><input id="promo-percent" type="number" min={1} max={100} value={f.percent} onChange={(e) => setF({ ...f, percent: e.target.value })} /></label>
        </>}
        {(f.kind === 'qty_tier' || f.kind === 'threshold') && <div className="span2 stack">
          {f.tiers.map((x, i) => <div key={i} className="row wrap">
            <label className="field"><span>{f.kind === 'qty_tier' ? t('From quantity') : t('When the bill reaches')}</span><input id={`tier-at-${i}`} inputMode="decimal" value={x.at} onChange={(e) => setF({ ...f, tiers: f.tiers.map((y, j) => (j === i ? { ...y, at: e.target.value } : y)) })} /></label>
            <label className="field"><span>{t('Percent off')}</span><input id={`tier-pct-${i}`} inputMode="decimal" value={x.percent} onChange={(e) => setF({ ...f, tiers: f.tiers.map((y, j) => (j === i ? { ...y, percent: e.target.value } : y)) })} /></label>
            {f.kind === 'threshold' && <label className="field"><span>{t('or amount off')}</span><input id={`tier-amt-${i}`} inputMode="decimal" value={x.amount} onChange={(e) => setF({ ...f, tiers: f.tiers.map((y, j) => (j === i ? { ...y, amount: e.target.value } : y)) })} /></label>}
            <button type="button" className="ghost small danger" aria-label={t('Remove')} onClick={() => setF({ ...f, tiers: f.tiers.filter((_, j) => j !== i) })}><Trash2 size={14} /></button></div>)}
          <button type="button" className="ghost" onClick={() => setF({ ...f, tiers: [...f.tiers, { at: '', percent: '', amount: '' }] })}><Plus size={14} />{t('Add tier')}</button>
          <p className="muted small">{t('The highest tier reached applies. Quantities and amounts count all the qualifying items together.')}</p>
        </div>}
        {f.kind === 'amount' && <>
          <label className="field"><span>{t('Amount off')}</span><input id="promo-amount" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></label>
          <label className="field"><span>{t('When the bill reaches')}</span><input id="promo-min" inputMode="decimal" value={f.min_amount} onChange={(e) => setF({ ...f, min_amount: e.target.value })} /></label>
        </>}
        {f.kind === 'bundle' ? (
          <div className="span2 stack">
            <label className="field"><span>{t('Bundle price')}</span><input id="promo-price" inputMode="decimal" value={f.price} onChange={(e) => setF({ ...f, price: e.target.value })} /></label>
            <ul className="mod-list">{f.components.map((c, i) => (
              <li key={i}><span>{nameOf(items.find((x) => x.id === c.item_id))}</span>
                <span className="row"><input className="qty-in" type="number" min={1} value={c.qty} aria-label={t('Qty')} onChange={(e) => setF({ ...f, components: f.components.map((x, j) => (j === i ? { ...x, qty: Number(e.target.value) || 1 } : x)) })} />
                  <button type="button" className="ghost small danger" aria-label={t('Remove')} onClick={() => setF({ ...f, components: f.components.filter((_, j) => j !== i) })}><Trash2 size={14} /></button></span></li>))}</ul>
            <div className="row"><select id="promo-component" value={pick} onChange={(e) => setPick(e.target.value)}><option value="">{t('Add an item to the bundle…')}</option>
              {sellable.filter((i) => !i.is_template).map((i) => <option key={i.id} value={i.id}>{nameOf(i)} · {num(i.price, decimals)}</option>)}</select>
              <button type="button" className="ghost" disabled={!pick} onClick={() => { setF({ ...f, components: [...f.components, { item_id: pick, qty: 1 }] }); setPick('') }}><Plus size={14} />{t('Add')}</button></div>
          </div>
        ) : (
          <div className="span2 stack">
            <div className="seg">{(['all', 'items', 'cats'] as const).map((k) => <button type="button" key={k} className={f.scope === k ? 'on' : ''} onClick={() => setF({ ...f, scope: k })}>{t({ all: 'Everything', items: 'Chosen items', cats: 'Categories' }[k])}</button>)}</div>
            {f.scope === 'items' && <div className="pick-box">{sellable.filter((i) => !i.parent_id).map((i) => <label key={i.id} className="check"><input type="checkbox" checked={f.item_ids.includes(i.id)} onChange={() => setF({ ...f, item_ids: toggle(f.item_ids, i.id) })} />{nameOf(i)}{i.is_template ? ` (${t('all variants')})` : ''}</label>)}</div>}
            {f.scope === 'cats' && <div className="pick-box">{cats.map((c) => <label key={c.id} className="check"><input type="checkbox" checked={f.category_ids.includes(c.id)} onChange={() => setF({ ...f, category_ids: toggle(f.category_ids, c.id) })} />{nameOf(c)}</label>)}</div>}
            {f.kind === 'percent' && <label className="field"><span>{t('Minimum quantity (0 = any)')}</span><input id="promo-minqty" type="number" min={0} value={f.min_qty} onChange={(e) => setF({ ...f, min_qty: e.target.value })} /></label>}
          </div>
        )}
        <h3 className="span2 sub-h">{t('When')}</h3>
        <label className="field"><span>{t('From date')}</span><input id="promo-from" type="date" value={f.starts_on} onChange={(e) => setF({ ...f, starts_on: e.target.value })} /></label>
        <label className="field"><span>{t('To date')}</span><input id="promo-to" type="date" value={f.ends_on} onChange={(e) => setF({ ...f, ends_on: e.target.value })} /></label>
        <div className="span2 row wrap">{DAYS.map((x, i) => <label key={x} className="check"><input type="checkbox" checked={f.weekdays.includes(i + 1)} onChange={() => setF({ ...f, weekdays: f.weekdays.includes(i + 1) ? f.weekdays.filter((w) => w !== i + 1) : [...f.weekdays, i + 1].sort() })} />{t(x)}</label>)}
          <span className="muted small">{t('none ticked = every day')}</span></div>
        <label className="field"><span>{t('From time (happy hour)')}</span><input id="promo-tfrom" type="time" value={f.time_from} onChange={(e) => setF({ ...f, time_from: e.target.value })} /></label>
        <label className="field"><span>{t('To time')}</span><input id="promo-tto" type="time" value={f.time_to} onChange={(e) => setF({ ...f, time_to: e.target.value })} /></label>
        <label className="field"><span>{t('Coupon code (optional)')}</span><input id="promo-coupon" value={f.coupon_code} onChange={(e) => setF({ ...f, coupon_code: e.target.value.toUpperCase() })} placeholder="RAMADAN10" /></label>
        {err && <p className="error span2">{err}</p>}
        <div className="row end span2"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

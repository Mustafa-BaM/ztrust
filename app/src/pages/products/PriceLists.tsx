import { useCallback, useEffect, useState } from 'react'
import { Modal, useApproval } from '../../components/ui'
import { useName, useT } from '../../lib/i18n'
import { num, toMinor } from '../../lib/money'
import { useSession } from '../../lib/session'
import { rpc, supabase } from '../../lib/supabase'
import type { Item } from '../../lib/types'

interface PL { id: string; name: string; name_ar: string | null; discount_pct: number; is_active: boolean }

/** Wholesale, VIP or corporate prices: a % off everything, plus fixed prices for chosen items. Assign a list to a customer on their card. */
export function PriceLists({ items, onClose }: { items: Item[]; onClose: () => void }) {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const approval = useApproval()
  const [lists, setLists] = useState<PL[]>([])
  const [edit, setEdit] = useState<null | { id?: string; name: string; name_ar: string; pct: string; active: boolean; prices: Record<string, string> }>(null)
  const [q, setQ] = useState('')
  const load = useCallback(async () => { const { data } = await supabase.from('price_lists').select('*').eq('tenant_id', tn.id).order('name'); setLists((data ?? []) as PL[]) }, [tn.id])
  useEffect(() => { void load() }, [load])
  async function open(l?: PL) {
    if (!l) return setEdit({ name: '', name_ar: '', pct: '0', active: true, prices: {} })
    const { data } = await supabase.from('price_list_items').select('item_id, price').eq('list_id', l.id)
    setEdit({ id: l.id, name: l.name, name_ar: l.name_ar ?? '', pct: String(l.discount_pct), active: l.is_active,
      prices: Object.fromEntries(((data ?? []) as { item_id: string; price: number }[]).map((x) => [x.item_id, num(x.price, d)])) })
  }
  async function save() {
    if (!edit) return
    const r = await approval.run(() => rpc('save_price_list', { p: { id: edit.id ?? null, tenant_id: tn.id, name: edit.name, name_ar: edit.name_ar, discount_pct: Number(edit.pct || 0), is_active: edit.active,
      items: Object.entries(edit.prices).filter(([, v]) => v.trim() !== '').map(([item_id, v]) => ({ item_id, price: toMinor(v, d) })) } }))
    if (r) { setEdit(null); await load() }
  }
  const sellable = items.filter((i) => ['standard', 'recipe', 'service'].includes(i.item_type ?? 'standard') && !i.is_template)
  return (
    <Modal title={t('Price lists')} onClose={onClose} wide>
      {!edit ? (
        <div className="stack">
          <div className="row end"><button className="primary" onClick={() => void open()}>{t('New price list')}</button></div>
          {lists.length === 0 ? <p className="muted">{t('No price lists yet. Create one for wholesale, VIP or corporate customers.')}</p> : (
            <ul className="mod-list">{lists.map((l) => <li key={l.id}><div><b>{l.name}</b><p className="muted small">{Number(l.discount_pct) > 0 ? t('{p}% off other items', { p: Number(l.discount_pct) }) : t('Catalogue price for other items')}{l.is_active ? '' : ` · ${t('Inactive')}`}</p></div>
              <button className="ghost small" onClick={() => void open(l)}>{t('Edit')}</button></li>)}</ul>)}
        </div>
      ) : (
        <form className="stack" onSubmit={(e) => { e.preventDefault(); void save() }}>
          <div className="grid2">
            <label className="field"><span>{t('Name')}</span><input id="pl-name" value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} placeholder={t('e.g. Wholesale')} /></label>
            <label className="field"><span>{t('Name (Arabic)')}</span><input id="pl-name-ar" dir="rtl" value={edit.name_ar} onChange={(e) => setEdit({ ...edit, name_ar: e.target.value })} /></label>
            <label className="field"><span>{t('% off items without their own price')}</span><input id="pl-pct" inputMode="decimal" value={edit.pct} onChange={(e) => setEdit({ ...edit, pct: e.target.value })} /></label>
            <label className="check"><input id="pl-active" type="checkbox" checked={edit.active} onChange={(e) => setEdit({ ...edit, active: e.target.checked })} />{t('Active')}</label>
          </div>
          <input id="pl-q" className="search" placeholder={t('Search name or barcode')} value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="table-wrap tall"><table className="list compact">
            <thead><tr><th>{t('Item')}</th><th className="num">{t('Catalogue price')}</th><th className="num">{t('List price')}</th></tr></thead>
            <tbody>{sellable.filter((i) => !q || [i.name, i.name_ar, i.barcode].some((x) => x?.toLowerCase().includes(q.toLowerCase()))).slice(0, 300).map((i) => (
              <tr key={i.id}><td>{nameOf(i)}</td><td className="num">{num(i.price, d)}</td>
                <td className="num"><input className="qty-in" aria-label={t('List price')} inputMode="decimal" placeholder={Number(edit.pct) > 0 ? num(Math.round((i.price * (100 - Number(edit.pct))) / 100), d) : ''}
                  value={edit.prices[i.id] ?? ''} onChange={(e) => setEdit({ ...edit, prices: { ...edit.prices, [i.id]: e.target.value } })} /></td></tr>))}</tbody>
          </table></div>
          {approval.error && <p className="error">{approval.error}</p>}
          <div className="row end"><button type="button" className="ghost" onClick={() => setEdit(null)}>{t('Back')}</button><button className="primary" disabled={!edit.name.trim()}>{t('Save')}</button></div>
        </form>)}
      {approval.dialog}
    </Modal>
  )
}

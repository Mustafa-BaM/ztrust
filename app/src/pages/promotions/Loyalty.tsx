import { Plus, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Empty } from '../../components/ui'
import { useName, useT } from '../../lib/i18n'
import { num, toMinor } from '../../lib/money'
import { useSession } from '../../lib/session'
import { supabase } from '../../lib/supabase'
import type { Category, Item } from '../../lib/types'

/** Loyalty tiers (silver, gold…: points multiplier by spend in the last 12 months) and punch cards ("buy 9, the 10th is free"). */
export function LoyaltySetup({ items, cats }: { items: Item[]; cats: Category[] }) {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [tiers, setTiers] = useState<{ id: string; name: string; name_ar: string | null; min_spend: number; earn_multiplier: number }[]>([])
  const [cards, setCards] = useState<{ id: string; name: string; name_ar: string | null; item_ids: string[] | null; category_ids: string[] | null; punches_needed: number; reward_item_id: string; is_active: boolean }[]>([])
  const [nt, setNt] = useState({ name: '', name_ar: '', min: '', mult: '1.5' })
  const [nc, setNc] = useState({ name: '', name_ar: '', scope: '', needed: '10', reward: '' })
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => {
    const [a, b] = await Promise.all([supabase.from('loyalty_tiers').select('*').eq('tenant_id', tn.id).order('min_spend'), supabase.from('punch_programs').select('*').eq('tenant_id', tn.id).order('name')])
    setTiers(a.data ?? []); setCards(b.data ?? [])
  }, [tn.id])
  useEffect(() => { void load() }, [load])
  const done = (e: { error: { message: string } | null }) => { if (e.error) setErr(e.error.message); else { setErr(null); void load() } }
  const sellable = items.filter((i) => !i.is_template && ['standard', 'recipe', 'service'].includes(i.item_type ?? 'standard'))
  const scopeName = (c: (typeof cards)[number]) => [...(c.item_ids ?? []).map((id) => nameOf(items.find((i) => i.id === id))), ...(c.category_ids ?? []).map((id) => nameOf(cats.find((x) => x.id === id)))].join(', ')
  return (
    <div className="grid2">
      <section className="panel">
        <header><h2>{t('Loyalty tiers')}</h2></header>
        <p className="muted small">{t('Customers move up by what they spent in the last 12 months; a higher tier earns more points per purchase.')}</p>
        {tiers.length === 0 ? <Empty title={t('No tiers yet')} /> : <ul className="mod-list">{tiers.map((x) => <li key={x.id}><div><b>{lang === 'ar' && x.name_ar ? x.name_ar : x.name}</b><p className="muted small">{t('from {v}', { v: num(x.min_spend, d) })} · {t('points ×{m}', { m: Number(x.earn_multiplier) })}</p></div>
          <button className="ghost small danger" aria-label={t('Remove')} onClick={async () => done(await supabase.from('loyalty_tiers').delete().eq('id', x.id))}><Trash2 size={14} /></button></li>)}</ul>}
        <form className="row wrap" onSubmit={async (e) => { e.preventDefault(); done(await supabase.from('loyalty_tiers').insert({ tenant_id: tn.id, name: nt.name, name_ar: nt.name_ar || null, min_spend: toMinor(nt.min || '0', d), earn_multiplier: Number(nt.mult) })); setNt({ name: '', name_ar: '', min: '', mult: '1.5' }) }}>
          <input id="tier-name" aria-label={t('Name')} placeholder={t('e.g. Gold')} value={nt.name} onChange={(e) => setNt({ ...nt, name: e.target.value })} />
          <input id="tier-name-ar" aria-label={t('Name (Arabic)')} dir="rtl" placeholder="ذهبي" value={nt.name_ar} onChange={(e) => setNt({ ...nt, name_ar: e.target.value })} />
          <input id="tier-min" className="qty-in" aria-label={t('Spend from')} placeholder={t('Spend from')} inputMode="decimal" value={nt.min} onChange={(e) => setNt({ ...nt, min: e.target.value })} />
          <input id="tier-mult" className="qty-in" aria-label={t('Points multiplier')} inputMode="decimal" value={nt.mult} onChange={(e) => setNt({ ...nt, mult: e.target.value })} />
          <button className="primary" disabled={!nt.name.trim()}><Plus size={14} />{t('Add tier')}</button></form>
      </section>
      <section className="panel">
        <header><h2>{t('Punch cards')}</h2></header>
        <p className="muted small">{t('Each unit bought adds a punch; when the card is full the reward is free at the till.')}</p>
        {cards.length === 0 ? <Empty title={t('No punch cards yet')} /> : <ul className="mod-list">{cards.map((c) => <li key={c.id}><div><b>{lang === 'ar' && c.name_ar ? c.name_ar : c.name}</b>
          <p className="muted small">{t('{n} punches', { n: c.punches_needed })} · {scopeName(c)} → {nameOf(items.find((i) => i.id === c.reward_item_id))}</p></div>
          <label className="check"><input type="checkbox" checked={c.is_active} onChange={async (e) => done(await supabase.from('punch_programs').update({ is_active: e.target.checked }).eq('id', c.id))} />{t('Active')}</label></li>)}</ul>}
        <form className="stack" onSubmit={async (e) => { e.preventDefault(); const [k, id] = nc.scope.split(':')
          done(await supabase.from('punch_programs').insert({ tenant_id: tn.id, name: nc.name, name_ar: nc.name_ar || null, punches_needed: Number(nc.needed), reward_item_id: nc.reward,
            item_ids: k === 'i' ? [id] : null, category_ids: k === 'c' ? [id] : null })); setNc({ name: '', name_ar: '', scope: '', needed: '10', reward: '' }) }}>
          <div className="row wrap"><input id="pc-name" aria-label={t('Name')} placeholder={t('e.g. Coffee card')} value={nc.name} onChange={(e) => setNc({ ...nc, name: e.target.value })} />
            <input id="pc-name-ar" aria-label={t('Name (Arabic)')} dir="rtl" placeholder="بطاقة القهوة" value={nc.name_ar} onChange={(e) => setNc({ ...nc, name_ar: e.target.value })} />
            <input id="pc-needed" className="qty-in" aria-label={t('Punches needed')} inputMode="numeric" value={nc.needed} onChange={(e) => setNc({ ...nc, needed: e.target.value })} /></div>
          <div className="row wrap"><select id="pc-scope" aria-label={t('What earns a punch')} value={nc.scope} onChange={(e) => setNc({ ...nc, scope: e.target.value })}><option value="">{t('What earns a punch')}</option>
            <optgroup label={t('Categories')}>{cats.map((c) => <option key={c.id} value={`c:${c.id}`}>{nameOf(c)}</option>)}</optgroup>
            <optgroup label={t('Items')}>{sellable.map((i) => <option key={i.id} value={`i:${i.id}`}>{nameOf(i)}</option>)}</optgroup></select>
            <select id="pc-reward" aria-label={t('Free reward')} value={nc.reward} onChange={(e) => setNc({ ...nc, reward: e.target.value })}><option value="">{t('Free reward')}</option>{sellable.map((i) => <option key={i.id} value={i.id}>{nameOf(i)}</option>)}</select>
            <button className="primary" disabled={!nc.name.trim() || !nc.scope || !nc.reward}><Plus size={14} />{t('Add punch card')}</button></div>
        </form>
      </section>
      {err && <p className="error span2">{err}</p>}
    </div>
  )
}

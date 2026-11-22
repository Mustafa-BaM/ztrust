import { Plus } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { useT } from '../../lib/i18n'
import { num, toMinor } from '../../lib/money'
import { useSession } from '../../lib/session'
import { supabase } from '../../lib/supabase'

/** Delivery zones: a fee and a minimum order per area, optionally per branch. Store checklists: opening, closing, custom. */
export function ZonesAndChecklists() {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [zones, setZones] = useState<{ id: string; name: string; fee: number; min_order: number; eta_min: number | null; branch_id: string | null; is_active: boolean }[]>([])
  const [lists, setLists] = useState<{ id: string; name: string; items: string[]; is_active: boolean }[]>([])
  const [z, setZ] = useState({ name: '', fee: '', min: '', eta: '', branch_id: '' })
  const [c, setC] = useState({ name: '', items: '' })
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => {
    const [a, b] = await Promise.all([supabase.from('delivery_zones').select('*').eq('tenant_id', tn.id).order('name'), supabase.from('checklists').select('*').eq('tenant_id', tn.id).order('name')])
    setZones(a.data ?? []); setLists(b.data ?? [])
  }, [tn.id])
  useEffect(() => { void load() }, [load])
  const done = (e: { error: { message: string } | null }) => { if (e.error) setErr(e.error.message); else { setErr(null); void load() } }
  return (
    <div className="grid2">
      {s.has('own_delivery') && <section className="card stack">
        <h2>{t('Delivery zones')}</h2>
        <ul className="mod-list">{zones.map((x) => <li key={x.id}><div><b>{x.name}</b><p className="muted small">{t('fee')} {num(x.fee, d)} · {t('min.')} {num(x.min_order, d)}{x.eta_min ? ` · ${x.eta_min} ${t('min')}` : ''}{x.branch_id ? ` · ${s.branches.find((b) => b.id === x.branch_id)?.name ?? ''}` : ''}</p></div>
          <label className="check"><input type="checkbox" checked={x.is_active} onChange={async (e) => done(await supabase.from('delivery_zones').update({ is_active: e.target.checked }).eq('id', x.id))} />{t('Active')}</label></li>)}</ul>
        <form className="row wrap" onSubmit={async (e) => { e.preventDefault(); done(await supabase.from('delivery_zones').insert({ tenant_id: tn.id, name: z.name, fee: toMinor(z.fee || '0', d), min_order: toMinor(z.min || '0', d), eta_min: z.eta ? Number(z.eta) : null, branch_id: z.branch_id || null })); setZ({ name: '', fee: '', min: '', eta: '', branch_id: '' }) }}>
          <input id="zone-name" aria-label={t('Area')} placeholder={t('e.g. Salmiya')} value={z.name} onChange={(e) => setZ({ ...z, name: e.target.value })} />
          <input id="zone-fee" className="qty-in" aria-label={t('Delivery fee')} placeholder={t('Fee')} inputMode="decimal" value={z.fee} onChange={(e) => setZ({ ...z, fee: e.target.value })} />
          <input id="zone-min" className="qty-in" aria-label={t('Minimum order')} placeholder={t('Min. order')} inputMode="decimal" value={z.min} onChange={(e) => setZ({ ...z, min: e.target.value })} />
          <input id="zone-eta" className="qty-in" aria-label={t('Minutes')} placeholder={t('Minutes')} inputMode="numeric" value={z.eta} onChange={(e) => setZ({ ...z, eta: e.target.value })} />
          {s.branches.length > 1 && <select id="zone-branch" aria-label={t('Branch')} value={z.branch_id} onChange={(e) => setZ({ ...z, branch_id: e.target.value })}><option value="">{t('All branches')}</option>{s.branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select>}
          <button className="primary" disabled={!z.name.trim()}><Plus size={14} />{t('Add zone')}</button></form>
      </section>}
      <section className="card stack">
        <h2>{t('Store checklists')}</h2>
        <p className="muted small">{t('Opening and closing tasks staff tick on the Shift screen every day, with who and when.')}</p>
        <ul className="mod-list">{lists.map((x) => <li key={x.id}><div><b>{x.name}</b><p className="muted small">{x.items.join(' · ')}</p></div>
          <label className="check"><input type="checkbox" checked={x.is_active} onChange={async (e) => done(await supabase.from('checklists').update({ is_active: e.target.checked }).eq('id', x.id))} />{t('Active')}</label></li>)}</ul>
        <form className="stack" onSubmit={async (e) => { e.preventDefault(); done(await supabase.from('checklists').insert({ tenant_id: tn.id, name: c.name, items: c.items.split('\n').map((x) => x.trim()).filter(Boolean) })); setC({ name: '', items: '' }) }}>
          <input id="ck-name" aria-label={t('Name')} placeholder={t('e.g. Opening checklist')} value={c.name} onChange={(e) => setC({ ...c, name: e.target.value })} />
          <textarea id="ck-items" rows={4} placeholder={t('One task per line')} value={c.items} onChange={(e) => setC({ ...c, items: e.target.value })} />
          <button className="primary" disabled={!c.name.trim() || !c.items.trim()}><Plus size={14} />{t('Add checklist')}</button></form>
      </section>
      {err && <p className="error span2">{err}</p>}
    </div>
  )
}

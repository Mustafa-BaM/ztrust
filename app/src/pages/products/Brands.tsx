import { Plus } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../../components/ui'
import { useT } from '../../lib/i18n'
import { useSession } from '../../lib/session'
import { supabase } from '../../lib/supabase'

/** Brands for multi-brand / cloud kitchens: each item belongs to a brand; reports split sales by brand. */
export function Brands({ onClose }: { onClose: () => void }) {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [rows, setRows] = useState<{ id: string; name: string; name_ar: string | null; is_active: boolean }[]>([])
  const [f, setF] = useState({ name: '', name_ar: '' })
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => { const { data } = await supabase.from('brands').select('*').eq('tenant_id', tn.id).order('name'); setRows(data ?? []) }, [tn.id])
  useEffect(() => { void load() }, [load])
  return (
    <Modal title={t('Brands')} onClose={onClose}>
      <div className="stack">
        <p className="muted small">{t('Run several brands from one kitchen: choose the brand on each item; reports show sales per brand.')}</p>
        <ul className="mod-list">{rows.map((b) => <li key={b.id}><b>{b.name}{b.name_ar ? ` · ${b.name_ar}` : ''}</b>
          <label className="check"><input type="checkbox" checked={b.is_active} onChange={async (e) => { await supabase.from('brands').update({ is_active: e.target.checked }).eq('id', b.id); void load() }} />{t('Active')}</label></li>)}</ul>
        <form className="row wrap" onSubmit={async (e) => { e.preventDefault(); const r = await supabase.from('brands').insert({ tenant_id: tn.id, name: f.name.trim(), name_ar: f.name_ar || null }); if (r.error) setErr(r.error.message); else { setF({ name: '', name_ar: '' }); void load() } }}>
          <input id="brand-name" aria-label={t('Name')} placeholder={t('Brand name')} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
          <input id="brand-name-ar" aria-label={t('Name (Arabic)')} dir="rtl" value={f.name_ar} onChange={(e) => setF({ ...f, name_ar: e.target.value })} />
          <button className="primary" disabled={!f.name.trim()}><Plus size={14} />{t('Add brand')}</button></form>
        {err && <p className="error">{err}</p>}
      </div>
    </Modal>
  )
}

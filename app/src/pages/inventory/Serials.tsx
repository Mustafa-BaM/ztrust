import { useCallback, useEffect, useState } from 'react'
import { Empty, useApproval } from '../../components/ui'
import { useName, useT } from '../../lib/i18n'
import { useSession } from '../../lib/session'
import { rpc, supabase } from '../../lib/supabase'
import type { Item } from '../../lib/types'

interface Ser { id: string; item_id: string; serial: string; status: string; source: string | null; sold_at: string | null; warranty_until: string | null; sale_id: string | null }
const ST: Record<string, string> = { in_stock: 'In stock', sold: 'Sold', returned: 'Returned to supplier' }

/** Find any serial / IMEI (where it is, who bought it, warranty) and register numbers already on the shelf. */
export function Serials() {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const approval = useApproval()
  const [items, setItems] = useState<Item[]>([])
  const [q, setQ] = useState('')
  const [rows, setRows] = useState<Ser[]>([])
  const [reg, setReg] = useState({ item_id: '', text: '' })
  const [msg, setMsg] = useState<string | null>(null)
  useEffect(() => { void supabase.from('items').select('*').eq('tenant_id', tn.id).eq('track_serial', true).order('name').then(({ data }) => setItems((data ?? []) as Item[])) }, [tn.id])
  const load = useCallback(async () => {
    let qy = supabase.from('item_serials').select('*').eq('tenant_id', tn.id).order('created_at', { ascending: false }).limit(200)
    if (q.trim()) qy = qy.ilike('serial', `%${q.trim().replace(/[%,()]/g, '')}%`)
    const { data } = await qy; setRows((data ?? []) as Ser[])
  }, [tn.id, q])
  useEffect(() => { const id = window.setTimeout(() => void load(), 200); return () => clearTimeout(id) }, [load])
  async function register() {
    const list = reg.text.split(/[\s,;]+/).map((x) => x.trim().toUpperCase()).filter(Boolean)
    const n = await approval.run(() => rpc<number>('register_serials', { p_item: reg.item_id, p_branch: s.branch!.id, p_serials: list }))
    if (n !== null) { setMsg(t('{n} serial numbers registered', { n })); setReg({ ...reg, text: '' }); await load() }
  }
  const name = (id: string) => nameOf(items.find((i) => i.id === id)) || '…'
  return (
    <section className="stack">
      <input id="ser-q" className="search" placeholder={t('Search a serial / IMEI')} value={q} onChange={(e) => setQ(e.target.value)} />
      {rows.length === 0 ? <Empty title={t('No serial numbers yet')} hint={t('They are registered when goods are received, or below for stock already on the shelf.')} /> : (
        <div className="table-wrap"><table className="list compact">
          <thead><tr><th>{t('Serial / IMEI')}</th><th>{t('Item')}</th><th>{t('Status')}</th><th>{t('Source')}</th><th>{t('Sold')}</th><th>{t('Warranty until')}</th></tr></thead>
          <tbody>{rows.map((r) => <tr key={r.id}><td className="mono">{r.serial}</td><td>{name(r.item_id)}</td><td>{t(ST[r.status] ?? r.status)}</td><td>{r.source ?? ''}</td>
            <td>{r.sold_at?.slice(0, 10) ?? ''}</td><td className={r.warranty_until && r.warranty_until < new Date().toISOString().slice(0, 10) ? 'muted' : ''}>{r.warranty_until ?? ''}</td></tr>)}</tbody>
        </table></div>)}
      {s.can('inventory.adjust') && items.length > 0 && <form className="card stack" onSubmit={(e) => { e.preventDefault(); void register() }}>
        <h2>{t('Register serial numbers on the shelf')}</h2>
        <select id="ser-item" value={reg.item_id} onChange={(e) => setReg({ ...reg, item_id: e.target.value })}><option value="">—</option>{items.map((i) => <option key={i.id} value={i.id}>{nameOf(i)}</option>)}</select>
        <textarea id="ser-text" rows={4} placeholder={t('Scan one per line')} value={reg.text} onChange={(e) => setReg({ ...reg, text: e.target.value })} />
        <div className="row end">{msg && <span className="muted">{msg}</span>}<button className="primary" disabled={!reg.item_id || !reg.text.trim()}>{t('Register')}</button></div>
      </form>}
      {approval.error && <p className="error">{approval.error}</p>}
      {approval.dialog}
    </section>
  )
}

import { useCallback, useEffect, useState } from 'react'
import { Empty, Modal } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt, num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { rpc, supabase } from '../lib/supabase'
import type { Customer } from '../lib/types'

export default function Customers() {
  const { t, lang } = useT()
  const s = useSession()
  const tenant = s.tenant!
  const [rows, setRows] = useState<Customer[]>([])
  const [bal, setBal] = useState<Record<string, number>>({})
  const [q, setQ] = useState('')
  const [edit, setEdit] = useState<Partial<Customer> | null>(null)

  const load = useCallback(async () => {
    let query = supabase.from('customers').select('*').eq('tenant_id', tenant.id).order('name').limit(300)
    if (q) query = query.or(`name.ilike.%${q.replace(/[%,()]/g, '')}%,phone.ilike.%${q.replace(/[%,()]/g, '')}%`)
    const { data } = await query
    const list = (data ?? []) as Customer[]
    setRows(list)
    const b: Record<string, number> = {}
    await Promise.all(list.filter((c) => c.credit_limit > 0).map(async (c) => { b[c.id] = await rpc<number>('customer_balance', { p_customer: c.id }) }))
    setBal(b)
  }, [tenant.id, q])
  useEffect(() => { void load() }, [load])

  return (
    <div className="page">
      <div className="row between"><h1>{t('Customers')}</h1><button className="primary" onClick={() => setEdit({ credit_limit: 0 })}>{t('Add customer')}</button></div>
      <input id="customers-q" className="search" placeholder={t('Search by name or phone')} value={q} onChange={(e) => setQ(e.target.value)} />
      {rows.length === 0 ? <Empty title={t('No customers yet.')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>{t('Phone')}</th><th className="num">{t('Credit limit')}</th><th className="num">{t('Balance owed')}</th><th /></tr></thead>
          <tbody>{rows.map((c) => (
            <tr key={c.id}><td>{c.name}</td><td className="mono">{c.phone}</td><td className="num">{c.credit_limit ? fmt(c.credit_limit, tenant, lang) : '—'}</td>
              <td className={`num ${(bal[c.id] ?? 0) > 0 ? 'bad' : ''}`}>{bal[c.id] != null ? fmt(bal[c.id], tenant, lang) : '—'}</td>
              <td>{s.can('customers.manage') && <button className="ghost small" onClick={() => setEdit(c)}>{t('Edit')}</button>}</td></tr>))}</tbody>
        </table></div>
      )}
      {edit && <CustomerForm c={edit} onClose={() => setEdit(null)} onSaved={async () => { setEdit(null); await load() }} />}
    </div>
  )
}

function CustomerForm({ c, onClose, onSaved }: { c: Partial<Customer>; onClose: () => void; onSaved: () => void }) {
  const { t } = useT()
  const s = useSession()
  const d = s.tenant!.currency_decimals
  const [f, setF] = useState({ name: c.name ?? '', phone: c.phone ?? '', email: c.email ?? '', credit_limit: num(c.credit_limit ?? 0, d) })
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault()
    const row = { tenant_id: s.tenant!.id, name: f.name.trim(), phone: f.phone.trim() || null, email: f.email.trim() || null,
      ...(s.can('customers.manage') ? { credit_limit: toMinor(f.credit_limit || '0', d) } : {}) }
    const r = c.id ? await supabase.from('customers').update(row).eq('id', c.id) : await supabase.from('customers').insert(row)
    if (r.error) setErr(r.error.message); else onSaved()
  }
  return (
    <Modal title={c.id ? t('Edit customer') : t('Add customer')} onClose={onClose}>
      <form className="stack" onSubmit={save}>
        <label className="field"><span>{t('Name')}</span><input id="c-name" required value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>{t('Phone')}</span><input id="c-phone" inputMode="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} placeholder="+965…" /></label>
        <label className="field"><span>{t('E-mail')}</span><input id="c-email" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></label>
        {s.can('customers.manage') && <label className="field"><span>{t('Credit limit (0 = no credit sales)')}</span><input id="c-limit" inputMode="decimal" value={f.credit_limit} onChange={(e) => setF({ ...f, credit_limit: e.target.value })} /></label>}
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

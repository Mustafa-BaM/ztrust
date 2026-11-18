import { useMemo, useState } from 'react'
import { useT } from '../lib/i18n'
import { supabase } from '../lib/supabase'
import type { Customer } from '../lib/types'
import { Modal } from './ui'

export function CustomerPicker({ tenantId, customers, online, onPick, onClose, onCreated }: {
  tenantId: string; customers: Customer[]; online: boolean
  onPick: (c: Customer | null) => void; onClose: () => void; onCreated: (c: Customer) => void
}) {
  const { t } = useT()
  const [q, setQ] = useState('')
  const [name, setName] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const list = useMemo(() => {
    const s = q.trim().toLowerCase()
    return (s ? customers.filter((c) => c.name.toLowerCase().includes(s) || (c.phone ?? '').includes(s)) : customers).slice(0, 30)
  }, [q, customers])

  async function create() {
    setErr(null)
    const { data, error } = await supabase.from('customers').insert({ tenant_id: tenantId, name: name.trim(), phone: q.trim() || null }).select().single()
    if (error) { setErr(error.message); return }
    onCreated(data as Customer); onPick(data as Customer)
  }

  return (
    <Modal title={t('Customer')} onClose={onClose}>
      <div className="stack">
        <input id="cust-search" autoFocus placeholder={t('Search by name or phone')} value={q} onChange={(e) => setQ(e.target.value)} />
        <ul className="pick-list">
          <li><button onClick={() => onPick(null)}>{t('Walk-in customer')}</button></li>
          {list.map((c) => <li key={c.id}><button onClick={() => onPick(c)}><b>{c.name}</b><span>{c.phone}</span></button></li>)}
        </ul>
        {online && (
          <div className="row">
            <input id="cust-new-name" placeholder={t('New customer name')} value={name} onChange={(e) => setName(e.target.value)} />
            <button className="primary" disabled={name.trim().length < 2} onClick={create}>{t('Add')}</button>
          </div>
        )}
        {online && <p className="muted small">{t('Type the phone number in the search box first to save it with the new customer.')}</p>}
        {err && <p className="error">{err}</p>}
      </div>
    </Modal>
  )
}

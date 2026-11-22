import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { Receipt, type ReceiptData } from '../components/Receipt'
import { useT } from '../lib/i18n'
import { rpc } from '../lib/supabase'
import type { Branch, Tenant } from '../lib/types'

/** Public digital receipt (from the link or QR the cashier shares). No login. */
export default function ReceiptLink() {
  const { token } = useParams()
  const { t } = useT()
  const [r, setR] = useState<(ReceiptData & { tenant: Tenant; branch: Branch }) | null | undefined>(undefined)
  useEffect(() => { rpc<(ReceiptData & { tenant: Tenant; branch: Branch }) | null>('receipt_public', { p_token: token }).then(setR).catch(() => setR(null)) }, [token])
  if (r === undefined) return <div className="page center-card"><p className="muted">{t('Loading…')}</p></div>
  if (!r) return <div className="page center-card"><h1>{t('Receipt not found')}</h1></div>
  return (
    <div className="page center-card public-receipt">
      <div className="receipt-preview"><Receipt data={{ ...r, payments: r.payments ?? [] }} tenant={r.tenant} branch={r.branch} /></div>
      <button className="ghost" onClick={() => window.print()}>{t('Print')}</button>
    </div>
  )
}

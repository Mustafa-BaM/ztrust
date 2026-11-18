import { useEffect, useMemo, useRef, useState } from 'react'
import { useT } from '../lib/i18n'
import { fmt, num, toMinor } from '../lib/money'
import type { Customer, Tenant, Tender, TenderEntry } from '../lib/types'
import { tenderLabel } from './Receipt'
import { Modal } from './ui'

const TENDERS: Tender[] = ['cash', 'card', 'on_account', 'payment_link', 'bank_transfer', 'store_credit']

/** Suggests the next banknotes above the amount due. */
function quickCash(due: number, decimals: number): number[] {
  const unit = 10 ** decimals
  const notes = decimals === 3 ? [0.25, 0.5, 1, 5, 10, 20] : [1, 5, 10, 20, 50, 100, 200, 500]
  const out = new Set<number>([due])
  for (const n of notes) { const v = Math.ceil(due / (n * unit)) * n * unit; if (v >= due) out.add(v) }
  return [...out].sort((a, b) => a - b).slice(0, 5)
}

/**
 * Split payment: any number of tenders until the remaining amount is zero.
 * Cash may be over-tendered; the difference is change. On account, payment link and store credit need a customer.
 */
export function PayDialog({ total, tenant, customer, online, channels = [], onClose, onConfirm, onPickCustomer }: {
  total: number; tenant: Tenant; customer: Customer | null; online: boolean; channels?: { id: string; display_name: string }[]
  onClose: () => void; onConfirm: (t: TenderEntry[], change: number) => void; onPickCustomer: () => void
}) {
  const { t, lang } = useT()
  const d = tenant.currency_decimals
  const [entries, setEntries] = useState<TenderEntry[]>([])
  const [tender, setTender] = useState<Tender>('cash')
  const [change, setChange] = useState(0)
  const paid = entries.reduce((a, e) => a + e.amount, 0)
  const remaining = total - paid
  const [amount, setAmount] = useState(num(total, d))
  const [ref, setRef] = useState('')
  const [channel, setChannel] = useState(channels[0]?.id ?? '')
  const input = useRef<HTMLInputElement>(null)

  useEffect(() => { setAmount(num(Math.max(remaining, 0), d)); input.current?.select() }, [remaining, d])
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Enter' && remaining === 0) { e.preventDefault(); onConfirm(entries, change) } }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [remaining, entries, change, onConfirm])

  const needsCustomer = (x: Tender) => x === 'on_account' || x === 'payment_link' || x === 'store_credit'
  const disabled = (x: Tender) => (needsCustomer(x) && !customer) || (x === 'payment_link' && !online)
  const suggestions = useMemo(() => quickCash(Math.max(remaining, 0), d), [remaining, d])

  function add(value?: number) {
    const v = value ?? toMinor(amount, d)
    if (!Number.isFinite(v) || v <= 0 || remaining <= 0 || disabled(tender)) return
    if (tender === 'cash' && v > remaining) {
      setChange(v - remaining)
      setEntries([...entries, { tender: 'cash', amount: remaining }])
    } else {
      if (tender === 'platform' && !channel) return
      setEntries([...entries, { tender, amount: Math.min(v, remaining), reference: ref || undefined, channel_id: tender === 'platform' ? channel : undefined }])
    }
    setRef('')
  }

  return (
    <Modal title={t('Payment')} onClose={onClose} wide>
      <div className="pay">
        <div className="pay-total">
          <span>{t('Total')}</span><b>{fmt(total, tenant, lang)}</b>
          <span>{t('Remaining')}</span><b className={remaining === 0 ? 'ok' : ''}>{fmt(Math.max(remaining, 0), tenant, lang)}</b>
          {change > 0 && <><span>{t('Change')}</span><b className="amber">{fmt(change, tenant, lang)}</b></>}
        </div>

        <div className="tender-row" role="radiogroup" aria-label={t('Payment method')}>
          {[...TENDERS, ...(channels.length ? (['platform'] as Tender[]) : [])].map((x) => (
            <button key={x} role="radio" aria-checked={tender === x} className={`tender ${tender === x ? 'on' : ''}`}
                    disabled={disabled(x)} onClick={() => setTender(x)} title={disabled(x) ? (x === 'payment_link' && !online ? t('Needs internet') : t('Choose a customer first')) : ''}>
              {tenderLabel(x, lang)}
            </button>
          ))}
        </div>
        {!customer && <button className="link" onClick={onPickCustomer}>{t('Add a customer to use on account, payment link or store credit')}</button>}

        {remaining > 0 && (
          <form className="pay-entry" onSubmit={(e) => { e.preventDefault(); add() }}>
            <label className="field"><span>{tender === 'cash' ? t('Cash received') : t('Amount')}</span>
              <input id="pay-amount" ref={input} inputMode="decimal" autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
            {tender === 'platform' && (
              <label className="field"><span>{t('Platform')}</span>
                <select id="pay-channel" value={channel} onChange={(e) => setChannel(e.target.value)}>{channels.map((c) => <option key={c.id} value={c.id}>{c.display_name}</option>)}</select></label>
            )}
            {tender === 'platform' && (
              <label className="field"><span>{t('Platform order number')}</span><input id="pay-ext" value={ref} onChange={(e) => setRef(e.target.value)} /></label>
            )}
            {(tender === 'card' || tender === 'bank_transfer') && (
              <label className="field"><span>{t('Reference (approval code)')}</span><input id="pay-ref" value={ref} onChange={(e) => setRef(e.target.value)} /></label>
            )}
            <button className="primary" type="submit">{t('Add payment')}</button>
          </form>
        )}
        {remaining > 0 && tender === 'cash' && (
          <div className="quick">{suggestions.map((v) => <button key={v} className="chipbtn" onClick={() => add(v)}>{num(v, d)}</button>)}</div>
        )}

        {entries.length > 0 && (
          <ul className="entries">
            {entries.map((e, i) => (
              <li key={i}><span>{e.tender === 'platform' ? channels.find((c) => c.id === e.channel_id)?.display_name : tenderLabel(e.tender, lang)}{e.reference ? ` · ${e.reference}` : ''}</span><b>{fmt(e.amount, tenant, lang)}</b>
                <button className="icon" aria-label={t('Remove')} onClick={() => { setEntries(entries.filter((_, j) => j !== i)); if (e.tender === 'cash') setChange(0) }}>✕</button></li>
            ))}
          </ul>
        )}

        <div className="row end">
          <button className="ghost" onClick={onClose}>{t('Back to cart')}</button>
          <button className="primary big" disabled={remaining !== 0} onClick={() => onConfirm(entries, change)}>{t('Complete sale')} <kbd>Enter</kbd></button>
        </div>
      </div>
    </Modal>
  )
}

import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useT } from '../lib/i18n'
import { parseError } from '../lib/supabase'

/** The Z Trust mark: one stroke that reads as Latin "Z" and Arabic "ز" (the curve is the ر, the amber dot makes it zay). */
export function Logo({ size = 32, tile = false }: { size?: number; tile?: boolean }) {
  return (
    <svg width={size} height={size} viewBox="0 0 120 120" role="img" aria-label="Z Trust" className={`logo ${tile ? "logo-tiled" : ""}`}>
      {tile && <rect x="4" y="4" width="112" height="112" rx="30" className="logo-tile" />}
      <path d="M28 40 H82 C 91 40, 92 48, 87 55 C 75 72, 56 82, 32 86 H92" fill="none" className="logo-stroke"
            strokeWidth="12" strokeLinecap="round" strokeLinejoin="round" />
      <circle cx="76" cy="22" r="7.5" fill="var(--amber)" />
    </svg>
  )
}

export function Modal({ title, onClose, children, wide }: { title: string; onClose: () => void; children: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [onClose])
  return (
    <div className="modal-back" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className={`modal ${wide ? 'wide' : ''}`} role="dialog" aria-modal="true" aria-label={title}>
        <header><h2>{title}</h2><button className="icon" onClick={onClose} aria-label="Close">✕</button></header>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  )
}

const PERM_LABEL: Record<string, string> = {
  'sale.discount': 'Discount above your limit',
  'sale.refund': 'Refund above your limit',
  'sale.cancel': 'Cancel a paid invoice',
  'sale.over_credit': 'Sale above the customer credit limit',
  'drawer.no_sale': 'Open the drawer without a sale',
}

/** Asks a supervisor or manager for their PIN, then retries the action with it. */
export function ApprovalDialog({ perm, denied, onSubmit, onCancel }: {
  perm: string; denied?: boolean; onSubmit: (pin: string) => void; onCancel: () => void
}) {
  const { t } = useT()
  const [pin, setPin] = useState('')
  const ref = useRef<HTMLInputElement>(null)
  useEffect(() => { ref.current?.focus() }, [])
  return (
    <Modal title={t('Manager approval')} onClose={onCancel}>
      <p className="muted">{t(PERM_LABEL[perm] ?? perm)}</p>
      {denied && <p className="error">{t('That PIN cannot approve this. Try another manager.')}</p>}
      <form onSubmit={(e) => { e.preventDefault(); if (pin.length >= 4) onSubmit(pin) }} className="stack">
        <label className="field"><span>{t('Approver PIN')}</span>
          <input id="approver-pin" ref={ref} type="password" inputMode="numeric" autoComplete="off" maxLength={6}
                 value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))} className="pin" />
        </label>
        <div className="row end">
          <button type="button" className="ghost" onClick={onCancel}>{t('Cancel')}</button>
          <button type="submit" className="primary" disabled={pin.length < 4}>{t('Approve')}</button>
        </div>
      </form>
    </Modal>
  )
}

/**
 * Runs a server action; if the database answers APPROVAL_REQUIRED it shows the PIN dialog and retries.
 * Usage: const { run, dialog } = useApproval(); run((pin) => rpc(..., { approver_pin: pin }))
 */
export function useApproval() {
  const { t } = useT()
  const [state, setState] = useState<null | { perm: string; denied: boolean; retry: (pin: string) => void; cancel: () => void }>(null)
  const [error, setError] = useState<string | null>(null)

  function run<T>(action: (pin?: string) => Promise<T>): Promise<T | null> {
    setError(null)
    return new Promise((resolve) => {
      const attempt = async (pin?: string) => {
        try {
          const r = await action(pin)
          setState(null); resolve(r)
        } catch (e) {
          const pe = parseError(e)
          if (pe.kind === 'approval' || pe.kind === 'denied') {
            setState({ perm: pe.perm, denied: pe.kind === 'denied', retry: (p) => void attempt(p), cancel: () => { setState(null); resolve(null) } })
          } else {
            setState(null); setError(t(pe.kind === 'message' ? pe.message : pe.perm)); resolve(null)
          }
        }
      }
      void attempt()
    })
  }
  const dialog = state ? <ApprovalDialog perm={state.perm} denied={state.denied} onSubmit={state.retry} onCancel={state.cancel} /> : null
  return { run, dialog, error, setError }
}

export function Empty({ title, hint }: { title: string; hint?: string }) {
  return <div className="empty"><strong>{title}</strong>{hint && <span>{hint}</span>}</div>
}

export function Kpi({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return <div className="kpi"><span className="kpi-label">{label}</span><b>{value}</b>{sub && <span className="kpi-sub">{sub}</span>}</div>
}

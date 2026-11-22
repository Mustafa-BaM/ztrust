import { useEffect, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

/** Prints any document (X/Z report, statement, payslip, quotation) on 80 mm, 58 mm or A4 paper, then calls onDone. */
export function PrintDoc({ paper = 'a4', onDone, children }: { paper?: '80' | '58' | 'a4'; onDone: () => void; children: ReactNode }) {
  useEffect(() => {
    const prev = document.documentElement.dataset.paper
    document.documentElement.dataset.paper = paper
    const style = document.createElement('style')
    style.textContent = paper === 'a4' ? '@page { size: A4; margin: 12mm }' : `@page { size: ${paper}mm auto; margin: 0 }`
    document.head.appendChild(style)
    const after = () => onDone()
    window.addEventListener('afterprint', after)
    const id = window.setTimeout(() => window.print(), 250)
    return () => { clearTimeout(id); window.removeEventListener('afterprint', after); style.remove(); if (prev) document.documentElement.dataset.paper = prev }
  }, [onDone, paper])
  return createPortal(<div id="print-root" className={`doc paper-${paper}`}>{children}</div>, document.body)
}

/** Paper picker used next to Print buttons; remembers the last choice on this device. */
export function usePaper(key = 'zt.docpaper', fallback: '80' | 'a4' = 'a4') {
  let v = fallback
  try { v = (localStorage.getItem(key) as '80' | 'a4') || fallback } catch { /* private mode */ }
  return { paper: v, setPaper: (p: '80' | '58' | 'a4') => { try { localStorage.setItem(key, p) } catch { /* ignore */ } } }
}

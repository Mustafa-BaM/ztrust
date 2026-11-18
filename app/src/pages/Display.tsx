import { useEffect, useState } from 'react'
import { Logo } from '../components/ui'

interface Msg { business: string; logo: string | null; currency: string; decimals: number; lang: string
  lines: { name: string; qty: number; total: number; promo: string | null }[]; promo: number; tax: number; total: number; due: number; customer: string | null; points: number | null }

/** Customer-facing screen. Open it on the second screen of the till (the POS button opens it); it follows the cart live. */
export default function Display() {
  const [m, setM] = useState<Msg | null>(null)
  useEffect(() => {
    if (typeof BroadcastChannel === 'undefined') return
    // the till posts to a channel per business; listen to all of this browser's channels
    const tid = (() => { try { return localStorage.getItem('zt.tenant') } catch { return null } })()
    const ch = new BroadcastChannel(`zt-display-${tid}`)
    ch.onmessage = (e) => { if (e.data?.type === 'cart') setM(e.data as Msg) }
    return () => ch.close()
  }, [])
  const money = (v: number) => (m ? new Intl.NumberFormat(m.lang === 'ar' ? 'ar-u-nu-latn' : 'en', { style: 'currency', currency: m.currency, minimumFractionDigits: m.decimals, maximumFractionDigits: m.decimals }).format(v / 10 ** m.decimals) : '')
  const ar = m?.lang === 'ar'
  return (
    <div className="display" dir={ar ? 'rtl' : 'ltr'}>
      <header>{m?.logo ? <img src={m.logo} alt="" /> : <Logo size={44} tile />}<h1>{m?.business ?? 'Z Trust'}</h1></header>
      {!m || m.lines.length === 0 ? <p className="display-welcome">{ar ? 'أهلاً وسهلاً' : 'Welcome'}</p> : (
        <div className="display-body">
          <ul>{m.lines.map((l, i) => <li key={i}><span>{l.qty}× {l.name}{l.promo && <em> · {l.promo}</em>}</span><b>{money(l.total)}</b></li>)}</ul>
          <div className="display-totals">
            {m.promo > 0 && <div className="save"><span>{ar ? 'وفّرت' : 'You save'}</span><span>{money(m.promo)}</span></div>}
            <div><span>{ar ? 'الضريبة' : 'VAT'}</span><span>{money(m.tax)}</span></div>
            <div className="grand"><span>{ar ? 'المطلوب' : 'To pay'}</span><span>{money(m.due)}</span></div>
            {m.customer && <p>{m.customer}{m.points != null ? ` · ${m.points} ${ar ? 'نقطة' : 'points'}` : ''}</p>}
          </div>
        </div>)}
    </div>
  )
}

import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { Logo } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt } from '../lib/money'
import { rpc } from '../lib/supabase'

interface Info { amount: number; status: string; expires_at: string; currency: string; decimals: number; business: string; business_ar: string | null; number: string; brand_color: string | null; logo_url?: string | null }

/**
 * Public page a customer opens from the WhatsApp/SMS link.
 * The "Pay now" button hands off to the payment gateway chosen per country (Tap, Checkout.com, MyFatoorah…);
 * the gateway webhook then calls mark_payment_link_paid. Gateway checkout is the next integration step.
 */
export default function PayLink() {
  const { token } = useParams()
  const { t, lang, setLang } = useT()
  const [info, setInfo] = useState<Info | null | undefined>(undefined)
  useEffect(() => { if (token) rpc<Info | null>('payment_link_info', { p_token: token }).then(setInfo).catch(() => setInfo(null)) }, [token])
  const expired = info && new Date(info.expires_at) < new Date()
  return (
    <div className="auth">
      <div className="auth-card" style={info?.brand_color ? { borderTopColor: info.brand_color } : undefined}>
        {info === undefined ? <p className="muted">{t('Loading…')}</p> : !info ? <p className="error">{t('This payment link is not valid.')}</p> : (
          <div className="stack center">
            {info.logo_url && <img className="paylink-logo" src={info.logo_url} alt="" />}
            <h1>{lang === 'ar' && info.business_ar ? info.business_ar : info.business}</h1>
            <p className="muted">{t('Invoice')} {info.number}</p>
            <div className="paylink-amount">{fmt(info.amount, { currency: info.currency, currency_decimals: info.decimals }, lang)}</div>
            {info.status === 'paid' ? <p className="success">{t('Paid. Thank you.')}</p>
              : expired || info.status !== 'pending' ? <p className="error">{t('This link has expired. Ask the shop for a new one.')}</p>
              : <button className="primary big" disabled title={t('Payment gateway not connected yet')}>{t('Pay now')}</button>}
          </div>
        )}
        <div className="row between"><span className="row muted small"><Logo size={18} /> Z Trust</span>
          <button className="ghost small" onClick={() => setLang(lang === 'ar' ? 'en' : 'ar')}>{lang === 'ar' ? 'English' : 'العربية'}</button></div>
      </div>
    </div>
  )
}

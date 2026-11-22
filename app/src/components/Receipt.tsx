import QRCode from 'qrcode'
import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { useT } from '../lib/i18n'
import { num } from '../lib/money'
import type { Branch, Tenant, Tender } from '../lib/types'

export interface ReceiptData {
  number: string
  doc_type: 'invoice' | 'credit_note'
  created_at: string
  lines: { name: string; qty: number; line_total: number; promo?: string }[]
  subtotal: number; tax_total: number; total: number; discount_total: number
  payments: { tender: Tender; amount: number; status?: string; method?: string }[]
  change?: number
  note?: string | null
  customer?: { name: string; phone?: string | null } | null
  cashier?: string
  offline?: boolean
  copy?: boolean
  links?: { token: string; amount: number }[]
  original_number?: string
  reason?: string | null
  /** paper chosen at print time; default = this device's setting */
  paper?: '80' | '58' | 'a4'
}

/** ZATCA simplified-invoice QR payload (TLV, base64): seller, VAT no., timestamp, total, VAT. Phase 2 signing is server-side and not in this MVP. */
function zatcaTlv(seller: string, vatNo: string, iso: string, total: string, vat: string) {
  const enc = new TextEncoder()
  const parts = [seller, vatNo, iso, total, vat].map((v, i) => {
    const b = enc.encode(v)
    return Uint8Array.from([i + 1, b.length, ...b])
  })
  const all = Uint8Array.from(parts.flatMap((p) => [...p]))
  return btoa(String.fromCharCode(...all))
}

const TENDER_AR: Record<string, string> = { gift_card: 'بطاقة هدية', cod: 'الدفع عند الاستلام', loyalty: 'نقاط الولاء', package: 'من الباقة', deposit: 'العربون', platform: 'منصة توصيل', cash: 'نقدي', card: 'بطاقة', on_account: 'آجل', payment_link: 'رابط دفع', bank_transfer: 'تحويل', store_credit: 'رصيد', other: 'أخرى' }
const TENDER_EN: Record<string, string> = { gift_card: 'Gift card', cod: 'Cash on delivery', loyalty: 'Loyalty points', package: 'From package', deposit: 'Deposit', platform: 'Delivery platform', cash: 'Cash', card: 'Card', on_account: 'On account', payment_link: 'Payment link', bank_transfer: 'Bank transfer', store_credit: 'Store credit', other: 'Other' }

/** Bilingual thermal receipt (58/80 mm). Printing goes through the OS print dialog, so any installed printer works. */
export function Receipt({ data, tenant, branch }: { data: ReceiptData; tenant: Tenant; branch: Branch | null }) {
  const d = tenant.currency_decimals
  const st = tenant.settings ?? {}
  const [qr, setQr] = useState<string | null>(null)
  useEffect(() => {
    if (tenant.country_code !== 'SA' || !tenant.tax_number || data.offline) { setQr(null); return }
    const payload = zatcaTlv(tenant.name_ar || tenant.name, tenant.tax_number, new Date(data.created_at).toISOString(), num(data.total, d), num(data.tax_total, d))
    QRCode.toDataURL(payload, { margin: 0, width: 160 }).then(setQr).catch(() => setQr(null))
  }, [tenant, data, d])
  const isCn = data.doc_type === 'credit_note'
  if (data.paper === 'a4') return <A4Invoice data={data} tenant={tenant} branch={branch} qr={qr} />
  return (
    <div className={`receipt rf-${st.receipt_font_size ?? 'm'}`} style={{ fontFamily: fontStack(st.receipt_font) }}>
      <div className="r-center">
        {st.logo_show !== false && (st.logo_mono_url || tenant.logo_url) && (
          <img className={`r-logo r-logo-${st.logo_size ?? 'm'}`} src={st.logo_mono_url || tenant.logo_url!} alt="" />
        )}
        <strong className="r-big">{tenant.name_ar || tenant.name}</strong>
        {tenant.name_ar && <div>{tenant.name}</div>}
        {branch && <div>{branch.name_ar || branch.name}</div>}
        {st.receipt_address && <div className="r-pre">{st.receipt_address}</div>}
        {st.receipt_phones && <div>☎ {st.receipt_phones}</div>}
        {st.receipt_cr && <div>CR / س.ت: {st.receipt_cr}</div>}
        {tenant.tax_number && <div>VAT / الرقم الضريبي: {tenant.tax_number}</div>}
        {st.receipt_header && <div className="r-pre">{st.receipt_header}</div>}
        <div className="r-big">{isCn ? 'CREDIT NOTE · إشعار دائن' : tenant.tax_number ? 'TAX INVOICE · فاتورة ضريبية مبسطة' : 'RECEIPT · إيصال'}</div>
        {data.copy && <div className="r-big">*** COPY · نسخة ***</div>}
        {data.offline && <div>OFFLINE · بانتظار المزامنة</div>}
      </div>
      <div className="r-row"><span>{data.number}</span><span>{new Date(data.created_at).toLocaleString('en-GB')}</span></div>
      {data.original_number && <div className="r-row"><span>Ref / مرجع</span><span>{data.original_number}</span></div>}
      {data.reason && <div className="r-row"><span>Reason / السبب</span><span>{data.reason}</span></div>}
      {data.customer && <div className="r-row"><span>{data.customer.name}</span><span>{data.customer.phone}</span></div>}
      {data.cashier && <div className="r-row"><span>Cashier / الكاشير</span><span>{data.cashier}</span></div>}
      {data.note && <div className="r-note">{data.note}</div>}
      <hr />
      {data.lines.map((l, i) => (
        <div key={i} className="r-line"><span>{l.name}{l.promo && <small className="r-promo"> · {l.promo}</small>}</span><span>{Number(l.qty)} ×</span><span>{num(l.line_total, d)}</span></div>
      ))}
      <hr />
      {data.discount_total > 0 && <div className="r-row"><span>Discount / الخصم</span><span>{num(data.discount_total, d)}</span></div>}
      <div className="r-row"><span>Subtotal excl. VAT / المجموع قبل الضريبة</span><span>{num(data.subtotal, d)}</span></div>
      <div className="r-row"><span>VAT / الضريبة</span><span>{num(data.tax_total, d)}</span></div>
      <div className="r-row r-big"><span>TOTAL / الإجمالي {tenant.currency}</span><span>{num(data.total, d)}</span></div>
      <hr />
      {data.payments.map((p, i) => (
        <div key={i} className="r-row"><span>{p.method ? p.method : `${TENDER_EN[p.tender]} / ${TENDER_AR[p.tender]}`}{p.status === 'pending' ? ' (pending)' : ''}</span><span>{num(Math.abs(p.amount), d)}</span></div>
      ))}
      {!!data.change && data.change > 0 && <div className="r-row r-big"><span>Change / الباقي</span><span>{num(data.change, d)}</span></div>}
      {qr && <div className="r-center"><img src={qr} alt="ZATCA QR" width={140} height={140} /></div>}
      {st.receipt_terms && <><hr /><div className="r-pre r-terms">{st.receipt_terms}</div></>}
      <div className="r-center small r-pre">{st.receipt_footer || 'شكراً لزيارتكم · Thank you'}</div>
      {st.receipt_website && <div className="r-center small">{st.receipt_website}</div>}
    </div>
  )
}

/** Prints a receipt by rendering it into the print-only container and opening the system print dialog. */
export function PrintReceipt({ data, tenant, branch, onDone }: { data: ReceiptData; tenant: Tenant; branch: Branch | null; onDone: () => void }) {
  const { t } = useT()
  const [width] = useState(() => data.paper ?? (() => { try { return localStorage.getItem('zt.paper') || '80' } catch { return '80' } })())
  useEffect(() => {
    document.documentElement.dataset.paper = width
    // the page size follows the chosen paper (Chrome, Edge and Firefox use it; Safari prints with its own page setup)
    const style = document.createElement('style')
    style.textContent = width === 'a4' ? '@page { size: A4; margin: 12mm }' : `@page { size: ${width}mm auto; margin: 0 }`
    document.head.appendChild(style)
    const after = () => onDone()
    window.addEventListener('afterprint', after)
    const id = window.setTimeout(() => window.print(), 250)
    return () => { clearTimeout(id); window.removeEventListener('afterprint', after); style.remove() }
  }, [onDone, width])
  return createPortal(<div id="print-root" aria-label={t('Receipt')}><Receipt data={data} tenant={tenant} branch={branch} /></div>, document.body)
}

export const tenderLabel = (tender: string, lang: string) => (lang === 'ar' ? TENDER_AR[tender] : TENDER_EN[tender]) ?? tender

/** Receipt fonts. Arabic-capable families are loaded from Google Fonts (and cached for offline use by the app). */
export const RECEIPT_FONTS: { key: string; label: string; stack: string }[] = [
  { key: 'plex-mono', label: 'IBM Plex Mono', stack: '"IBM Plex Mono", "IBM Plex Sans Arabic", ui-monospace, monospace' },
  { key: 'plex-arabic', label: 'IBM Plex Sans Arabic', stack: '"IBM Plex Sans Arabic", system-ui, sans-serif' },
  { key: 'cairo', label: 'Cairo', stack: 'Cairo, "IBM Plex Sans Arabic", system-ui, sans-serif' },
  { key: 'tajawal', label: 'Tajawal', stack: 'Tajawal, "IBM Plex Sans Arabic", system-ui, sans-serif' },
  { key: 'naskh', label: 'Noto Naskh Arabic', stack: '"Noto Naskh Arabic", "IBM Plex Sans Arabic", serif' },
  { key: 'courier', label: 'Courier (printer style)', stack: '"Courier New", Courier, "IBM Plex Sans Arabic", monospace' },
]
export const fontStack = (key?: string) => (RECEIPT_FONTS.find((f) => f.key === key) ?? RECEIPT_FONTS[0]).stack

/** A4 tax invoice: the same document as the thermal receipt, laid out for a laser printer or a PDF. */
function A4Invoice({ data, tenant, branch, qr }: { data: ReceiptData; tenant: Tenant; branch: Branch | null; qr: string | null }) {
  const d = tenant.currency_decimals
  const st = tenant.settings ?? {}
  const isCn = data.doc_type === 'credit_note'
  return (
    <div className="a4" style={{ fontFamily: fontStack(!st.receipt_font || st.receipt_font === 'plex-mono' || st.receipt_font === 'courier' ? 'plex-arabic' : st.receipt_font) }}>
      <header className="a4-head">
        <div className="a4-from">
          {st.logo_show !== false && tenant.logo_url && <img className="a4-logo" src={tenant.logo_url} alt="" />}
          <div><strong>{tenant.name}</strong>{tenant.name_ar && <div dir="rtl">{tenant.name_ar}</div>}
            {branch && <div>{branch.name}</div>}{st.receipt_address && <div className="r-pre">{st.receipt_address}</div>}
            {st.receipt_phones && <div>☎ {st.receipt_phones}</div>}{st.receipt_cr && <div>CR / س.ت: {st.receipt_cr}</div>}
            {tenant.tax_number && <div>VAT / الرقم الضريبي: {tenant.tax_number}</div>}</div>
        </div>
        <div className="a4-title">
          <h1>{isCn ? 'CREDIT NOTE · إشعار دائن' : tenant.tax_number ? 'TAX INVOICE · فاتورة ضريبية' : 'INVOICE · فاتورة'}</h1>
          <table><tbody>
            <tr><th>No. / الرقم</th><td>{data.number}</td></tr>
            <tr><th>Date / التاريخ</th><td>{new Date(data.created_at).toLocaleString('en-GB')}</td></tr>
            {data.original_number && <tr><th>Ref / مرجع</th><td>{data.original_number}</td></tr>}
            {data.cashier && <tr><th>Cashier / الكاشير</th><td>{data.cashier}</td></tr>}
          </tbody></table>
        </div>
      </header>
      {data.note && <p className="a4-note">{data.note}</p>}
      {data.customer && <section className="a4-to"><b>Bill to / العميل</b><div>{data.customer.name}</div>{data.customer.phone && <div>{data.customer.phone}</div>}</section>}
      <table className="a4-lines">
        <thead><tr><th>#</th><th>Item / الصنف</th><th className="num">Qty / الكمية</th><th className="num">Amount / المبلغ ({tenant.currency})</th></tr></thead>
        <tbody>{data.lines.map((l, i) => <tr key={i}><td>{i + 1}</td><td>{l.name}{l.promo && <small className="r-promo"> · {l.promo}</small>}</td><td className="num">{Number(l.qty)}</td><td className="num">{num(l.line_total, d)}</td></tr>)}</tbody>
      </table>
      <div className="a4-bottom">
        <div>{qr && <img src={qr} alt="ZATCA QR" width={120} height={120} />}
          {data.payments.map((p, i) => <div key={i} className="small">{p.method ? p.method : `${TENDER_EN[p.tender]} / ${TENDER_AR[p.tender]}`}: {num(Math.abs(p.amount), d)}</div>)}</div>
        <table className="a4-totals"><tbody>
          {data.discount_total > 0 && <tr><th>Discount / الخصم</th><td>{num(data.discount_total, d)}</td></tr>}
          <tr><th>Subtotal excl. VAT / المجموع قبل الضريبة</th><td>{num(data.subtotal, d)}</td></tr>
          <tr><th>VAT / الضريبة</th><td>{num(data.tax_total, d)}</td></tr>
          <tr className="grand"><th>TOTAL / الإجمالي {tenant.currency}</th><td>{num(data.total, d)}</td></tr>
        </tbody></table>
      </div>
      {st.receipt_terms && <footer className="a4-terms r-pre">{st.receipt_terms}</footer>}
      <p className="a4-thanks">{st.receipt_footer || 'شكراً لزيارتكم · Thank you'}{st.receipt_website ? ` · ${st.receipt_website}` : ''}</p>
    </div>
  )
}

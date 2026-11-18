import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Banknote, CreditCard, Hand, Keyboard, Minus, PauseCircle, Plus, ScanLine, Search, UserRound, X } from 'lucide-react'
import { Link } from 'react-router-dom'
import { CustomerPicker } from '../components/CustomerPicker'
import { PayDialog } from '../components/PayDialog'
import { PrintReceipt, Receipt, type ReceiptData } from '../components/Receipt'
import { ApprovalDialog, Modal, useApproval } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { calcCart, calcLine, fmt, num, toMinor } from '../lib/money'
import { hubConnected, hubSend, useHub } from '../lib/hub'
import { enqueueSale, loadCatalog, saveCatalog, useOnline, type Catalog } from '../lib/offline'
import { useSession } from '../lib/session'
import { getShift, norm } from '../lib/shift'
import { publicAppUrl, rpc, supabase, uuid } from '../lib/supabase'
import type { CartLine, Customer, Item, Sale, TenderEntry } from '../lib/types'

type Mode = 'touch' | 'keys'
type Held = { id: string; at: string; lines: CartLine[]; customer: Customer | null }
const ls = {
  get<T>(k: string, d: T): T { try { const v = localStorage.getItem(k); return v ? (JSON.parse(v) as T) : d } catch { return d } },
  set(k: string, v: unknown) { try { localStorage.setItem(k, JSON.stringify(v)) } catch { /* ignore */ } },
}

export default function Pos() {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const online = useOnline()
  const tenant = s.tenant!
  const d = tenant.currency_decimals
  const shiftId = getShift(s.branch?.id, s.session?.user.id)

  const [catalog, setCatalog] = useState<Catalog | null>(null)
  const [mode, setMode] = useState<Mode>(() => ls.get<Mode>('zt.posmode', matchMedia('(pointer: coarse)').matches ? 'touch' : 'keys'))
  const [q, setQ] = useState('')
  const [cat, setCat] = useState<string | null>(null)
  const [lines, setLines] = useState<CartLine[]>([])
  const [sel, setSel] = useState(0)
  const [customer, setCustomer] = useState<Customer | null>(null)
  const [dialog, setDialog] = useState<null | 'pay' | 'customer' | 'qty' | 'discount' | 'held'>(null)
  const [held, setHeld] = useState<Held[]>(() => ls.get<Held[]>('zt.held', []))
  const [done, setDone] = useState<null | { receipt: ReceiptData; links: { token: string; amount: number }[] }>(null)
  const [printing, setPrinting] = useState<ReceiptData | null>(null)
  const [preApproval, setPreApproval] = useState<null | ((pin: string) => void)>(null)
  const [busy, setBusy] = useState(false)
  const [orderType, setOrderType] = useState<'takeaway' | 'dine_in' | 'delivery'>('takeaway')
  const [table, setTable] = useState('')
  const [noteFor, setNoteFor] = useState<number | null>(null)
  const approval = useApproval()
  const search = useRef<HTMLInputElement>(null)

  // ---- catalog: cached copy first, then refresh when online
  useEffect(() => {
    let live = true
    void loadCatalog(tenant.id).then((c) => { if (live && c) setCatalog(c) })
    if (online) {
      void Promise.all([
        supabase.from('items').select('*').eq('tenant_id', tenant.id).eq('is_active', true).neq('item_type', 'ingredient').order('name').limit(5000),
        supabase.from('categories').select('*').eq('tenant_id', tenant.id).order('sort'),
        supabase.from('customers').select('*').eq('tenant_id', tenant.id).order('name').limit(2000),
        s.branch ? supabase.from('kitchen_stations').select('id, name, is_default, sort').eq('branch_id', s.branch.id).eq('is_active', true) : Promise.resolve({ data: [] }),
        s.branch && s.has('delivery') ? supabase.from('delivery_channels').select('id, display_name, platform').eq('branch_id', s.branch.id).eq('is_active', true) : Promise.resolve({ data: [] }),
      ]).then(([i, c, cu, ks, dc]) => {
        if (i.error || !live) return
        const next = { items: (i.data ?? []) as Item[], categories: c.data ?? [], customers: (cu.data ?? []) as Customer[], stations: (ks.data ?? []).length, stationList: (ks.data ?? []) as Catalog['stationList'], channels: (dc.data ?? []) as Catalog['channels'] }
        setCatalog({ ...next, savedAt: new Date().toISOString() })
        void saveCatalog(tenant.id, next)
      })
    }
    return () => { live = false }
  }, [tenant.id, online, s.branch])

  useEffect(() => ls.set('zt.posmode', mode), [mode])
  useEffect(() => ls.set('zt.held', held), [held])

  const items = catalog?.items ?? []
  const filtered = useMemo(() => {
    const n = norm(q)
    return items.filter((i) => (!cat || i.category_id === cat) &&
      (!n || norm(i.name).includes(n) || norm(i.name_ar ?? '').includes(n) || i.barcode === q.trim() || (i.sku ?? '').toLowerCase() === n))
  }, [items, q, cat])

  const totals = useMemo(() => calcCart(lines, tenant.prices_include_tax), [lines, tenant.prices_include_tax])

  const add = useCallback((i: Item, qty = 1) => {
    setLines((cur) => {
      const idx = cur.findIndex((l) => l.item_id === i.id && l.discount === 0 && l.unit_price === i.price && !l.note)
      if (idx >= 0) { const next = [...cur]; next[idx] = { ...next[idx], qty: next[idx].qty + qty }; setSel(idx); return next }
      setSel(cur.length)
      return [...cur, { key: uuid(), item_id: i.id, name: i.name, name_ar: i.name_ar, qty, unit_price: i.price, list_price: i.price,
                        discount: 0, tax_rate: i.tax_rate ?? tenant.vat_rate }]
    })
  }, [tenant.vat_rate])

  // "3*" then scan/enter = quantity 3
  function submitSearch() {
    const raw = q.trim()
    const m = raw.match(/^(\d+(?:\.\d+)?)\*(.*)$/)
    const qty = m ? parseFloat(m[1]) : 1
    const code = m ? m[2].trim() : raw
    const exact = items.find((i) => i.barcode === code || (i.sku && i.sku.toLowerCase() === code.toLowerCase()))
    const pick = exact ?? (filtered.length === 1 ? filtered[0] : null)
    if (pick) { add(pick, qty); setQ('') }
  }

  const setQty = (idx: number, qty: number) => setLines((cur) => qty <= 0 ? cur.filter((_, i) => i !== idx) : cur.map((l, i) => (i === idx ? { ...l, qty } : l)))
  const clear = () => { setLines([]); setCustomer(null); setSel(0); setTable('') }
  const hasKitchen = s.has('kitchen') && (catalog?.stations ?? 0) > 0
  const hub = useHub()
  const showImages = Boolean(tenant.settings?.pos_show_images)

  // ---- keyboard mode shortcuts
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (dialog || done || approval.dialog || preApproval || noteFor !== null) return
      const map: Record<string, () => void> = {
        F2: () => search.current?.focus(),
        F3: () => setDialog('customer'),
        F4: () => lines.length && setDialog('qty'),
        F6: () => lines.length && setDialog('discount'),
        F7: () => lines.length && setNoteFor(sel),
        F8: () => lines.length && setDialog('pay'),
        F9: () => setDialog('held'),
        ArrowDown: () => setSel((x) => Math.min(x + 1, lines.length - 1)),
        ArrowUp: () => setSel((x) => Math.max(x - 1, 0)),
        Delete: () => lines.length && setQty(sel, 0),
      }
      const fn = map[e.key]
      if (fn) { e.preventDefault(); fn() }
      else if ((e.key === '+' || e.key === '-') && document.activeElement !== search.current && lines[sel]) {
        e.preventDefault(); setQty(sel, lines[sel].qty + (e.key === '+' ? 1 : -1))
      }
    }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [dialog, done, lines, sel, approval.dialog, preApproval, noteFor])

  // ---- completing the sale
  function buildPayload(tenders: TenderEntry[], pin?: string) {
    return {
      tenant_id: tenant.id, branch_id: s.branch!.id, shift_id: shiftId, client_id: uuid(), customer_id: customer?.id ?? null,
      device_created_at: new Date().toISOString(), approver_pin: pin ?? null,
      lines: lines.map((l) => ({ item_id: l.item_id, name: l.name, qty: l.qty, unit_price: l.unit_price, discount: l.discount, note: l.note ?? null })),
      kitchen: hasKitchen ? { order_type: tenders.some((x) => x.tender === 'platform') ? 'delivery' : orderType, table_no: orderType === 'dine_in' ? table : null, hub: hubConnected() } : null,
      payments: tenders.map((x) => ({ tender: x.tender, amount: x.amount, reference: x.reference ?? null })),
      channel_id: tenders.find((x) => x.tender === 'platform')?.channel_id ?? null,
      external_ref: tenders.find((x) => x.tender === 'platform')?.reference ?? null,
    }
  }

  function receiptFromCart(tenders: TenderEntry[], change: number, number: string, offline: boolean): ReceiptData {
    return {
      number, doc_type: 'invoice', created_at: new Date().toISOString(), offline,
      lines: lines.map((l) => ({ name: nameOf(l) || l.name, qty: l.qty, line_total: calcLine(l, tenant.prices_include_tax).total })),
      subtotal: totals.net, tax_total: totals.tax, total: totals.total, discount_total: totals.discount,
      payments: tenders.map((x) => ({ tender: x.tender, amount: x.amount, status: x.tender === 'payment_link' ? 'pending' : 'captured' })),
      change, customer, cashier: s.member?.display_name,
    }
  }

  /** Builds one kitchen ticket per station from the cart (same routing as the cloud) and sends it to the branch hub. */
  function sendToHub(clientId: string, ref: string) {
    if (!hasKitchen || !hubConnected() || !catalog) return
    const stations = catalog.stationList ?? []
    const fallback = [...stations].sort((a, b) => Number(b.is_default) - Number(a.is_default) || a.sort - b.sort)[0]
    if (!fallback) return
    const routeOf = (itemId: string | null) => {
      const it = items.find((x) => x.id === itemId); const cat = catalog.categories.find((c) => c.id === it?.category_id)
      return stations.some((x) => x.id === cat?.station_id) ? cat!.station_id! : fallback.id
    }
    const groups = new Map<string, CartLine[]>()
    for (const l of lines) { const st = routeOf(l.item_id); groups.set(st, [...(groups.get(st) ?? []), l]) }
    const tickets = [...groups.entries()].map(([station_id, ls]) => ({
      id: uuid(), station_id, sale_client_id: clientId, order_ref: ref, order_type: orderType, table_no: orderType === 'dine_in' ? table || null : null,
      customer_name: customer?.name ?? null, created_at: new Date().toISOString(),
      items: ls.map((l) => ({ id: uuid(), name: l.name, name_ar: l.name_ar, qty: l.qty, note: l.note ?? null })),
    }))
    hubSend({ type: 'ticket.new', tickets })
  }

  async function finish(tenders: TenderEntry[], change: number, pin?: string) {
    setDialog(null)
    // discount above my own limit: ask for a PIN before sending (works offline too; the server re-checks it)
    const lim = s.limit('sale.discount')
    if (!pin && totals.discount > 0 && s.role !== 'owner' && (!s.can('sale.discount') || (lim !== null && totals.discountPct > lim))) {
      setPreApproval(() => (p: string) => { setPreApproval(null); void finish(tenders, change, p) })
      return
    }
    setBusy(true)
    const payload = buildPayload(tenders, pin)
    const offlineSale = async () => {
      if (tenders.some((x) => x.tender === 'payment_link')) { approval.setError(t('Payment links need internet.')); return }
      await enqueueSale(payload)
      const ref = `OFF-${String(payload.client_id).slice(0, 8).toUpperCase()}`
      sendToHub(String(payload.client_id), ref)
      setDone({ receipt: receiptFromCart(tenders, change, ref, true), links: [] })
      clear()
    }
    try {
      if (!navigator.onLine) { await offlineSale(); return }
      // Wi-Fi up but internet down looks "online" to the browser: a failed request falls back to the offline queue
      let networkDown = false
      const sale = await approval.run(async (p) => {
        try { return await rpc<Sale>('complete_sale', { p: { ...payload, approver_pin: p ?? payload.approver_pin } }) }
        catch (e) { if (/Failed to fetch|NetworkError|fetch failed|Load failed|network/i.test((e as Error).message ?? '')) { networkDown = true; return null } throw e }
      }).catch(() => null)
      if (networkDown) { await offlineSale(); return }
      if (sale) {
        sendToHub(String(payload.client_id), sale.number)
        setDone({ receipt: { ...receiptFromCart(tenders, change, sale.number, false), created_at: sale.created_at, subtotal: sale.subtotal, tax_total: sale.tax_total, total: sale.total }, links: sale.links ?? [] })
        clear()
      } else if (!navigator.onLine) {
        await offlineSale()
      }
    } finally { setBusy(false) }
  }

  if (!s.branch) return <div className="page"><p>{t('No branch available.')}</p></div>
  if (!shiftId) {
    return (
      <div className="page center-card">
        <h1 className="keep">{t('Open a shift to start selling')}</h1>
        <p className="muted">{t('Count the opening cash float, then start the shift.')}</p>
        <Link className="button primary big" to="/shift">{t('Open shift')}</Link>
      </div>
    )
  }

  const line = lines[sel]
  return (
    <div className={`pos ${mode} ${showImages ? 'with-images' : ''}`}>
      <section className="pos-left">
        <div className="pos-search">
          <label className="search-box">
            <Search size={18} aria-hidden="true" />
            <input id="pos-search" ref={search} autoFocus={mode === 'keys'} placeholder={t('Scan barcode or search (F2)')}
                   value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); submitSearch() } }} />
            {q && <button className="icon" aria-label={t('Clear')} onClick={() => setQ('')}><X size={16} /></button>}
          </label>
          <div className="seg" role="group" aria-label={t('Input mode')}>
            <button className={mode === 'touch' ? 'on' : ''} onClick={() => setMode('touch')}><Hand size={16} aria-hidden="true" />{t('Touch')}</button>
            <button className={mode === 'keys' ? 'on' : ''} onClick={() => setMode('keys')}><Keyboard size={16} aria-hidden="true" />{t('Keyboard')}</button>
          </div>
        </div>
        <div className="cats">
          <button className={!cat ? 'on' : ''} onClick={() => setCat(null)} style={{ ['--cat' as string]: 'var(--ink)' }}>{t('All')}<em>{items.length}</em></button>
          {(catalog?.categories ?? []).map((c, idx) => (
            <button key={c.id} className={cat === c.id ? 'on' : ''} onClick={() => setCat(c.id)} style={{ ['--cat' as string]: `var(--c${(idx % 8) + 1})` }}>
              <i className="cat-dot" aria-hidden="true" />{nameOf(c)}<em>{items.filter((x) => x.category_id === c.id).length}</em>
            </button>))}
        </div>
        {mode === 'touch' ? (
          <div className="tiles">
            {filtered.slice(0, 200).map((i) => {
              const inCart = lines.filter((l) => l.item_id === i.id).reduce((a, l) => a + l.qty, 0)
              const idx = (catalog?.categories ?? []).findIndex((c) => c.id === i.category_id)
              const label = nameOf(i)
              return (
                <button key={i.id} className={`tile ${inCart ? 'in' : ''}`} onClick={() => add(i)} style={{ ['--cat' as string]: idx >= 0 ? `var(--c${(idx % 8) + 1})` : 'var(--muted)' }}>
                  {showImages && i.image_url
                    ? <img className="tile-img" src={i.image_url} alt="" loading="lazy" />
                    : <span className="tile-mono" aria-hidden="true">{label.trim().charAt(0)}</span>}
                  <span className="tile-name">{label}</span>
                  <span className="tile-price">{num(i.price, d)}</span>
                  {inCart > 0 && <span className="tile-qty" aria-label={t('In cart')}>{inCart}</span>}
                </button>
              )
            })}
            {items.length === 0 && <p className="muted">{t('No products yet.')} <Link to="/products">{t('Add products')}</Link></p>}
          </div>
        ) : (
          <table className="list keys">
            <thead><tr><th>{t('Item')}</th><th>{t('Barcode')}</th><th className="num">{t('Price')}</th></tr></thead>
            <tbody>{filtered.slice(0, 100).map((i) => (
              <tr key={i.id} tabIndex={0} onClick={() => add(i)} onKeyDown={(e) => { if (e.key === 'Enter') add(i) }}>
                <td>{nameOf(i)}</td><td className="mono">{i.barcode}</td><td className="num">{num(i.price, d)}</td></tr>
            ))}</tbody>
          </table>
        )}
      </section>

      <section className="pos-cart">
        {hasKitchen && (
          <div className="order-bar">
            <div className="seg" role="group" aria-label={t('Order type')}>
              {(['takeaway', 'dine_in', 'delivery'] as const).map((x) => (
                <button key={x} className={orderType === x ? 'on' : ''} onClick={() => setOrderType(x)}>{t({ takeaway: 'Takeaway', dine_in: 'Dine-in', delivery: 'Delivery' }[x])}</button>))}
            </div>
            {orderType === 'dine_in' && <input id="pos-table" className="table-in" placeholder={t('Table')} value={table} onChange={(e) => setTable(e.target.value)} />}
            {hub.status !== 'off' && <span className={`hub-badge ${hub.status}`} title={t('Branch hub')}>{hub.status === 'connected' ? t('Kitchen via hub') : t('Hub reconnecting…')}</span>}
          </div>
        )}
        <header className="cart-head">
          <button className="ghost" onClick={() => setDialog('customer')}><UserRound size={16} aria-hidden="true" />{customer ? customer.name : t('Walk-in customer')} <kbd>F3</kbd></button>
          <button className="ghost" onClick={() => setDialog('held')}><PauseCircle size={16} aria-hidden="true" />{t('Hold / recall')} <kbd>F9</kbd>{held.length > 0 && <em className="badge">{held.length}</em>}</button>
        </header>
        <div className="paper">
          <div className="paper-head"><span>{t('Ticket')}</span><span>{lines.reduce((a, l) => a + l.qty, 0)} {t('items')}</span></div>
          <ul className="cart-lines">
            {lines.map((l, i) => {
              const c = calcLine(l, tenant.prices_include_tax)
              return (
                <li key={l.key} className={i === sel ? 'sel' : ''} onClick={() => setSel(i)}>
                  <div className="cl-main">
                    <span className="cl-q">{l.qty}×</span>
                    <span className="cl-name">{nameOf(l)}</span>
                    <span className="cl-lead" aria-hidden="true" />
                    <span className="cl-total">{num(c.total, d)}</span>
                  </div>
                  {(l.note || l.discount > 0 || l.unit_price !== l.list_price) && (
                    <div className="cl-sub">
                      {(l.discount > 0 || l.unit_price !== l.list_price) && <span className="tag">{t('Discount')} −{num(l.discount + Math.max(0, Math.round(l.qty * (l.list_price - l.unit_price))), d)}</span>}
                      {l.note && <span className="cl-note">» {l.note}</span>}
                    </div>)}
                  {i === sel && (
                    <div className="cl-qty">
                      <button className="icon" aria-label="-" onClick={(e) => { e.stopPropagation(); setQty(i, l.qty - 1) }}><Minus size={16} /></button>
                      <span>{l.qty}</span>
                      <button className="icon" aria-label="+" onClick={(e) => { e.stopPropagation(); setQty(i, l.qty + 1) }}><Plus size={16} /></button>
                      <span className="cl-unit muted">@ {num(l.unit_price, d)}</span>
                    </div>)}
                </li>
              )
            })}
            {lines.length === 0 && <li className="empty-cart"><ScanLine size={28} aria-hidden="true" />{t('Scan or tap a product to start a sale')}</li>}
          </ul>
          <div className="paper-totals">
            {totals.discount > 0 && <div><span>{t('Discount')}</span><span>−{num(totals.discount, d)} ({totals.discountPct}%)</span></div>}
            <div><span>{t('VAT')}</span><span>{num(totals.tax, d)}</span></div>
            <div className="grand"><span>{t('Total')}</span><span>{fmt(totals.total, tenant, lang)}</span></div>
          </div>
        </div>
        <div className="cart-actions">
          <button disabled={!line} onClick={() => setDialog('qty')}>{t('Qty')} <kbd>F4</kbd></button>
          <button disabled={!line} onClick={() => setDialog('discount')}>{t('Discount')} <kbd>F6</kbd></button>
          {hasKitchen && <button disabled={!line} onClick={() => setNoteFor(sel)}>{t('Note')} <kbd>F7</kbd></button>}
          <button disabled={!line} onClick={() => setQty(sel, 0)}>{t('Remove')} <kbd>Del</kbd></button>
          <button disabled={!lines.length} onClick={clear}>{t('Clear')}</button>
        </div>
        {approval.error && <p className="error">{approval.error}</p>}
        <div className="pay-row">
          <button className="quick" disabled={!lines.length || busy} onClick={() => void finish([{ tender: 'cash', amount: totals.total }], 0)} title={t('Customer pays the exact amount in cash')}>
            <Banknote size={18} aria-hidden="true" />{t('Exact cash')}</button>
          <button className="quick" disabled={!lines.length || busy} onClick={() => void finish([{ tender: 'card', amount: totals.total }], 0)} title={t('Paid in full by card')}>
            <CreditCard size={18} aria-hidden="true" />{t('Card')}</button>
          <button className="primary pay-btn" disabled={!lines.length || busy} onClick={() => setDialog('pay')}>
            <span>{busy ? t('Please wait…') : t('Pay')}</span><b>{fmt(totals.total, tenant, lang)}</b><kbd>F8</kbd>
          </button>
        </div>
      </section>

      {dialog === 'pay' && (
        <PayDialog total={totals.total} tenant={tenant} customer={customer} online={online} channels={catalog?.channels ?? []}
                   onClose={() => setDialog(null)} onConfirm={(tn, ch) => void finish(tn, ch)} onPickCustomer={() => setDialog('customer')} />
      )}
      {dialog === 'customer' && catalog && (
        <CustomerPicker tenantId={tenant.id} customers={catalog.customers} online={online}
          onPick={(c) => { setCustomer(c); setDialog(null) }} onClose={() => setDialog(null)}
          onCreated={(c) => setCatalog({ ...catalog, customers: [...catalog.customers, c] })} />
      )}
      {dialog === 'qty' && line && (
        <NumberDialog title={t('Quantity')} initial={String(line.qty)} onClose={() => setDialog(null)}
          onSave={(v) => { const n = parseFloat(v); if (n >= 0) setQty(sel, n); setDialog(null) }} />
      )}
      {dialog === 'discount' && line && (
        <DiscountDialog lineTotal={Math.round(line.qty * line.unit_price)} decimals={d} onClose={() => setDialog(null)}
          onSave={(minor) => { setLines(lines.map((l, i) => (i === sel ? { ...l, discount: minor } : l))); setDialog(null) }} />
      )}
      {dialog === 'held' && (
        <Modal title={t('Held sales')} onClose={() => setDialog(null)}>
          <div className="stack">
            <button className="primary" disabled={!lines.length} onClick={() => { setHeld([...held, { id: uuid(), at: new Date().toISOString(), lines, customer }]); clear(); setDialog(null) }}>{t('Hold current sale')}</button>
            <ul className="pick-list">{held.map((h) => (
              <li key={h.id}><button onClick={() => { setLines(h.lines); setCustomer(h.customer); setHeld(held.filter((x) => x.id !== h.id)); setDialog(null) }}>
                <b>{new Date(h.at).toLocaleTimeString()}</b><span>{h.lines.length} {t('items')} · {fmt(calcCart(h.lines, tenant.prices_include_tax).total, tenant, lang)}</span></button></li>
            ))}</ul>
          </div>
        </Modal>
      )}
      {noteFor !== null && lines[noteFor] && (
        <TextDialog title={t('Kitchen note')} initial={lines[noteFor].note ?? ''} suggestions={[t('No onion'), t('Extra hot'), t('No sugar'), t('Oat milk'), t('Well done')]}
          onClose={() => setNoteFor(null)} onSave={(v) => { setLines(lines.map((l, i) => (i === noteFor ? { ...l, note: v.trim() || undefined } : l))); setNoteFor(null) }} />
      )}
      {preApproval && <ApprovalDialog perm="sale.discount" onSubmit={preApproval} onCancel={() => setPreApproval(null)} />}
      {approval.dialog}
      {done && (
        <Modal title={done.receipt.offline ? t('Saved offline') : t('Sale complete')} onClose={() => setDone(null)}>
          <div className="stack">
            {done.receipt.offline && <p className="amber-note">{t('This sale is stored on this device and will sync automatically when the internet is back.')}</p>}
            {!!done.receipt.change && <p className="change">{t('Change')}: <b>{fmt(done.receipt.change, tenant, lang)}</b></p>}
            {done.links.map((k) => {
              const url = `${publicAppUrl}/pay/${k.token}`
              const text = encodeURIComponent(`${tenant.name}: ${t('Pay {amount} here', { amount: fmt(k.amount, tenant, lang) })} ${url}`)
              return (
                <div key={k.token} className="linkbox">
                  <code>{url}</code>
                  <div className="row">
                    <button onClick={() => { navigator.clipboard?.writeText(url).catch(() => undefined) }}>{t('Copy link')}</button>
                    <a className="button" href={`https://wa.me/${(customer?.phone ?? '').replace(/\D/g, '')}?text=${text}`} target="_blank" rel="noreferrer">{t('Send by WhatsApp')}</a>
                  </div>
                </div>
              )
            })}
            <div className="receipt-preview"><Receipt data={done.receipt} tenant={tenant} branch={s.branch} /></div>
            <div className="row end">
              <button onClick={() => setPrinting(done.receipt)}>{t('Print receipt')}</button>
              <button className="primary" autoFocus onClick={() => setDone(null)}>{t('New sale')}</button>
            </div>
          </div>
        </Modal>
      )}
      {printing && <PrintReceipt data={printing} tenant={tenant} branch={s.branch} onDone={() => setPrinting(null)} />}
    </div>
  )
}

function NumberDialog({ title, initial, onSave, onClose }: { title: string; initial: string; onSave: (v: string) => void; onClose: () => void }) {
  const { t } = useT()
  const [v, setV] = useState(initial)
  return (
    <Modal title={title} onClose={onClose}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); onSave(v) }}>
        <input id="number-dialog" autoFocus inputMode="decimal" value={v} onChange={(e) => setV(e.target.value)} onFocus={(e) => e.target.select()} />
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

function DiscountDialog({ lineTotal, decimals, onSave, onClose }: { lineTotal: number; decimals: number; onSave: (minor: number) => void; onClose: () => void }) {
  const { t } = useT()
  const [kind, setKind] = useState<'pct' | 'amt'>('pct')
  const [v, setV] = useState('')
  const minor = kind === 'pct' ? Math.round((lineTotal * (parseFloat(v) || 0)) / 100) : toMinor(v || '0', decimals)
  const ok = Number.isFinite(minor) && minor >= 0 && minor <= lineTotal
  return (
    <Modal title={t('Line discount')} onClose={onClose}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); if (ok) onSave(minor) }}>
        <div className="seg"><button type="button" className={kind === 'pct' ? 'on' : ''} onClick={() => setKind('pct')}>%</button>
          <button type="button" className={kind === 'amt' ? 'on' : ''} onClick={() => setKind('amt')}>{t('Amount')}</button></div>
        <input id="discount-value" autoFocus inputMode="decimal" value={v} onChange={(e) => setV(e.target.value)} />
        <p className="muted">{t('Discount')}: {num(ok ? minor : 0, decimals)}</p>
        <p className="muted small">{t('Discounts above your limit need a manager PIN.')}</p>
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!ok}>{t('Apply')}</button></div>
      </form>
    </Modal>
  )
}

function TextDialog({ title, initial, suggestions, onSave, onClose }: { title: string; initial: string; suggestions: string[]; onSave: (v: string) => void; onClose: () => void }) {
  const { t } = useT()
  const [v, setV] = useState(initial)
  return (
    <Modal title={title} onClose={onClose}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); onSave(v) }}>
        <input id="line-note" autoFocus value={v} onChange={(e) => setV(e.target.value)} maxLength={120} />
        <div className="quick">{suggestions.map((x) => <button type="button" key={x} className="chipbtn" onClick={() => setV(v ? `${v}, ${x}` : x)}>{x}</button>)}</div>
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

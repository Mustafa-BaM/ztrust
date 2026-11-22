import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Banknote, Bike, ChefHat, CreditCard, Gift, Hand, Inbox, Keyboard, LayoutGrid, Minus, MonitorSmartphone, PauseCircle, Plus, Save, ScanLine, Search, StickyNote, Tag, Ticket, UserRound, UsersRound, X } from 'lucide-react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { CustomerPicker } from '../components/CustomerPicker'
import { cardMethods, PayDialog } from '../components/PayDialog'
import { ModifierDialog, StaffPicker, TablesDialog, VariantPicker } from '../components/pos/Dialogs'
import { DeliveryDialog, GiftCardDialog, IncomingOrders, type DeliveryInfo } from '../components/pos/Growth'
import { PrintReceipt, Receipt, type ReceiptData } from '../components/Receipt'
import { ApprovalDialog, Modal, useApproval } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { calcCart, calcLine, fmt, num, pgRound, toMinor } from '../lib/money'
import { hubConnected, hubSend, useHub } from '../lib/hub'
import { enqueueSale, loadCatalog, saveCatalog, useOnline, type Catalog } from '../lib/offline'
import { applyPromotions } from '../lib/promotions'
import { useSession } from '../lib/session'
import { getShift, norm } from '../lib/shift'
import { parseError, publicAppUrl, rpc, supabase, uuid } from '../lib/supabase'
import type { CartLine, Customer, CustomerPackage, DiningTable, Item, ModifierOption, OnlineOrder, OpenOrder, Sale, TenderEntry } from '../lib/types'

type Mode = 'touch' | 'keys'
type Held = { id: string; at: string; lines: CartLine[]; customer: Customer | null; note?: string }
/** Checkout handed over from another screen (calendar, job card, table) */
export interface CheckoutContext {
  lines: CartLine[]; customer: Customer | null; label?: string
  appointment_id?: string; work_order_id?: string; deposit?: number; open_order_id?: string; table?: DiningTable | null; online_order_id?: string
}
const ls = {
  get<T>(k: string, d: T): T { try { const v = localStorage.getItem(k); return v ? (JSON.parse(v) as T) : d } catch { return d } },
  set(k: string, v: unknown) { try { localStorage.setItem(k, JSON.stringify(v)) } catch { /* ignore */ } },
}

export default function Pos() {
  const { t, lang } = useT()
  const nameOf = useName()
  const s = useSession()
  const online = useOnline()
  const loc = useLocation()
  const nav = useNavigate()
  const tenant = s.tenant!
  const st = tenant.settings ?? {}
  const d = tenant.currency_decimals
  const shiftId = getShift(s.branch?.id, s.session?.user.id)

  const [catalog, setCatalog] = useState<Catalog | null>(null)
  const [mode, setMode] = useState<Mode>(() => ls.get<Mode>('zt.posmode', matchMedia('(pointer: coarse)').matches ? 'touch' : 'keys'))
  const [q, setQ] = useState('')
  const [cat, setCat] = useState<string | null>(null)
  const [lines, setLines] = useState<CartLine[]>([])
  const [sel, setSel] = useState(0)
  const [customer, setCustomer] = useState<Customer | null>(null)
  const [dialog, setDialog] = useState<null | 'pay' | 'customer' | 'qty' | 'discount' | 'held' | 'coupon' | 'staff' | 'tables' | 'delivery' | 'incoming'>(null)
  const [held, setHeld] = useState<Held[]>(() => ls.get<Held[]>('zt.held', []))
  const [saleNote, setSaleNote] = useState('')
  const [noteSale, setNoteSale] = useState(false)
  const [cartDisc, setCartDisc] = useState(false)
  const [done, setDone] = useState<null | { receipt: ReceiptData; links: { token: string; amount: number }[] }>(null)
  const [printing, setPrinting] = useState<ReceiptData | null>(null)
  const [preApproval, setPreApproval] = useState<null | ((pin: string) => void)>(null)
  const [busy, setBusy] = useState(false)
  const [orderType, setOrderType] = useState<'takeaway' | 'dine_in' | 'delivery'>('takeaway')
  const [table, setTable] = useState('')
  const [noteFor, setNoteFor] = useState<number | null>(null)
  const [variantOf, setVariantOf] = useState<Item | null>(null)
  const [modFor, setModFor] = useState<Item | null>(null)
  const [weighFor, setWeighFor] = useState<Item | null>(null)
  const [coupon, setCoupon] = useState<string | null>(null)
  const [ctx, setCtx] = useState<CheckoutContext | null>(null)
  const [pkgs, setPkgs] = useState<CustomerPackage[]>([])
  const [points, setPoints] = useState<number | null>(null)
  const [splitKeys, setSplitKeys] = useState<string[] | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [giftFor, setGiftFor] = useState<Item | null>(null)
  const [delivery, setDelivery] = useState<DeliveryInfo | null>(null)
  const [incoming, setIncoming] = useState<OnlineOrder[]>([])
  const approval = useApproval()
  const search = useRef<HTMLInputElement>(null)

  // ---- catalog: cached copy first, then refresh when online
  useEffect(() => {
    let live = true
    void loadCatalog(tenant.id).then((c) => { if (live && c) setCatalog(c) })
    if (online) {
      const none = Promise.resolve({ data: [] as never[], error: null })
      void Promise.all([
        supabase.from('items').select('*').eq('tenant_id', tenant.id).eq('is_active', true).neq('item_type', 'ingredient').order('name').limit(5000),
        supabase.from('categories').select('*').eq('tenant_id', tenant.id).order('sort'),
        supabase.from('customers').select('*').eq('tenant_id', tenant.id).order('name').limit(2000),
        s.branch ? supabase.from('kitchen_stations').select('id, name, is_default, sort').eq('branch_id', s.branch.id).eq('is_active', true) : none,
        s.branch && s.has('delivery') ? supabase.from('delivery_channels').select('id, display_name, platform').eq('branch_id', s.branch.id).eq('is_active', true) : none,
        s.has('modifiers') ? supabase.from('modifier_groups').select('*').eq('tenant_id', tenant.id).order('sort') : none,
        s.has('modifiers') ? supabase.from('modifier_options').select('*').eq('tenant_id', tenant.id).eq('is_active', true).order('sort') : none,
        s.has('modifiers') ? supabase.from('item_modifier_groups').select('item_id, group_id, sort').eq('tenant_id', tenant.id) : none,
        s.has('promotions') ? supabase.from('promotions').select('*').eq('tenant_id', tenant.id).eq('is_active', true) : none,
        supabase.from('memberships').select('user_id, display_name, bookable, color, is_driver').eq('tenant_id', tenant.id).eq('is_active', true).order('display_name'),
      ]).then(([i, c, cu, ks, dc, mg, mo, ig, pr, sf]) => {
        if (i.error || !live) return
        const next = {
          items: (i.data ?? []) as Item[], categories: c.data ?? [], customers: (cu.data ?? []) as Customer[], stations: (ks.data ?? []).length,
          stationList: (ks.data ?? []) as Catalog['stationList'], channels: (dc.data ?? []) as Catalog['channels'],
          modGroups: (mg.data ?? []) as Catalog['modGroups'], modOptions: (mo.data ?? []) as Catalog['modOptions'], itemGroups: (ig.data ?? []) as Catalog['itemGroups'],
          promos: (pr.data ?? []) as Catalog['promos'], staff: (sf.data ?? []) as Catalog['staff'],
        }
        setCatalog({ ...next, savedAt: new Date().toISOString() })
        void saveCatalog(tenant.id, next)
      })
    }
    return () => { live = false }
  }, [tenant.id, online, s.branch, s])

  // ---- checkout handed over from the calendar, a job card or a table
  useEffect(() => {
    const c = (loc.state as { checkout?: CheckoutContext } | null)?.checkout
    if (!c) return
    setCtx(c); setLines(c.lines); setCustomer(c.customer); setSel(0)
    nav(loc.pathname, { replace: true, state: null })
  }, [loc.state, loc.pathname, nav])

  // ---- the customer's packages and points
  useEffect(() => {
    setPkgs([]); setPoints(null)
    if (!customer || !online) return
    if (s.has('memberships')) void supabase.from('customer_packages').select('*').eq('customer_id', customer.id).eq('status', 'active').then(({ data }) => setPkgs((data ?? []) as CustomerPackage[]))
    if (s.has('loyalty')) void rpc<number>('customer_points', { p_customer: customer.id }).then(setPoints).catch(() => setPoints(null))
  }, [customer, online, s])

  // QR / kiosk orders waiting for staff
  const loadIncoming = useCallback(async () => {
    if (!s.has('qr_ordering') || !s.branch || !online) return
    const { data } = await supabase.from('online_orders').select('*').eq('branch_id', s.branch.id).in('status', ['pending', 'accepted']).is('sale_id', null).order('created_at')
    setIncoming(((data ?? []) as OnlineOrder[]).filter((o) => o.status === 'pending' || o.source === 'kiosk'))
  }, [s, online])
  useEffect(() => { void loadIncoming(); const id = window.setInterval(() => void loadIncoming(), 10_000); return () => clearInterval(id) }, [loadIncoming])
  function payKiosk(o: OnlineOrder) {
    const cl: CartLine[] = o.lines.map((l) => {
      const it = items.find((x) => x.id === l.item_id)
      const mods = (catalog?.modOptions ?? []).filter((m) => (l.modifiers ?? []).includes(m.id))
      return { key: l.key, item_id: l.item_id, name: it?.name ?? l.name, name_ar: it?.name_ar ?? null, qty: Number(l.qty), unit_price: Number(l.unit_price), list_price: Number(l.unit_price),
               discount: 0, tax_rate: it?.tax_rate ?? tenant.vat_rate, note: l.note ?? undefined, modifiers: mods.map((m) => ({ id: m.id, name: m.name, name_ar: m.name_ar, price: m.price })) }
    })
    setDialog(null); setCtx({ lines: cl, customer: null, online_order_id: o.id, label: `${t('Kiosk')} #${o.number}` }); setLines(cl); setSel(0)
  }

  useEffect(() => ls.set('zt.posmode', mode), [mode])
  useEffect(() => ls.set('zt.held', held), [held])

  const items = catalog?.items ?? []
  const filtered = useMemo(() => {
    const n = norm(q)
    // variants appear through their template, unless searched for
    return items.filter((i) => (!cat || i.category_id === cat) && (!i.parent_id || !!n) &&
      (!n || norm(i.name).includes(n) || norm(i.name_ar ?? '').includes(n) || i.barcode === q.trim() || (i.sku ?? '').toLowerCase() === n))
  }, [items, q, cat])

  // promotions are recalculated on every change; the server applies the same rules and caps the claim
  const priced = useMemo(() => s.has('promotions') ? applyPromotions(lines, catalog?.promos ?? [], items, coupon) : lines, [lines, catalog?.promos, items, coupon, s])
  const payLines = useMemo(() => (splitKeys ? priced.filter((l) => splitKeys.includes(l.key)) : priced), [priced, splitKeys])
  const totals = useMemo(() => calcCart(payLines, tenant.prices_include_tax), [payLines, tenant.prices_include_tax])
  const deposit = ctx?.deposit ? Math.min(ctx.deposit, totals.total - totals.packages) : 0
  const due = totals.total - totals.packages - deposit

  const groupsOf = useCallback((itemId: string) => {
    const ids = (catalog?.itemGroups ?? []).filter((x) => x.item_id === itemId).sort((a, b) => a.sort - b.sort).map((x) => x.group_id)
    return (catalog?.modGroups ?? []).filter((g) => ids.includes(g.id)).sort((a, b) => ids.indexOf(a.id) - ids.indexOf(b.id))
  }, [catalog])

  const addLine = useCallback((i: Item, qty = 1, mods: ModifierOption[] = []) => {
    const extra = mods.reduce((a, o) => a + o.price, 0)
    setLines((cur) => {
      const idx = mods.length ? -1 : cur.findIndex((l) => l.item_id === i.id && l.discount === 0 && l.unit_price === i.price && !l.note && !l.modifiers?.length && !l.customer_package_id && !l.fired)
      if (idx >= 0) { const next = [...cur]; next[idx] = { ...next[idx], qty: Math.round((next[idx].qty + qty) * 1000) / 1000 }; setSel(idx); return next }
      setSel(cur.length)
      return [...cur, { key: uuid(), item_id: i.id, name: i.name, name_ar: i.name_ar, qty, unit_price: i.price + extra, list_price: i.price + extra,
                        discount: 0, tax_rate: i.tax_rate ?? tenant.vat_rate, modifiers: mods.map((o) => ({ id: o.id, name: o.name, name_ar: o.name_ar, price: o.price })),
                        staff_id: i.item_type === 'service' && s.member?.user_id ? s.member.user_id : null }]
    })
  }, [tenant.vat_rate, s.member])

  /** tap or scan: variants → choose size/colour, add-ons → choose options, sold by weight → enter the weight */
  const add = useCallback((i: Item, qty?: number) => {
    if (i.item_type === 'gift_card') return setGiftFor(i)
    if (i.is_template) return setVariantOf(i)
    if (s.has('modifiers') && groupsOf(i.id).length) return setModFor(i)
    if (i.sold_by_weight && qty == null) return setWeighFor(i)
    addLine(i, qty ?? 1)
  }, [groupsOf, addLine, s])

  // "3*" then scan/enter = quantity 3; scale labels carry the PLU and the weight or price
  function submitSearch() {
    const raw = q.trim()
    const pre = st.scale_prefix ?? '20', len = st.scale_plu_len ?? 5
    if (s.has('weighed') && /^\d{13}$/.test(raw) && raw.startsWith(pre)) {
      const plu = raw.slice(pre.length, pre.length + len), val = Number(raw.slice(pre.length + len, 12))
      const it = items.find((x) => x.plu && Number(x.plu) === Number(plu))
      if (it) {
        const qty = st.scale_mode === 'price' ? Math.round((val / Math.max(it.price, 1)) * 1000) / 1000 : val / 1000
        addLine(it, qty); setQ(''); return
      }
    }
    const m = raw.match(/^(\d+(?:\.\d+)?)\*(.*)$/)
    const qty = m ? parseFloat(m[1]) : undefined
    const code = m ? m[2].trim() : raw
    const exact = items.find((i) => i.barcode === code || (i.sku && i.sku.toLowerCase() === code.toLowerCase()))
    const pick = exact ?? (filtered.length === 1 ? filtered[0] : null)
    if (pick) { add(pick, qty); setQ('') }
  }

  const setQty = (idx: number, qty: number) => setLines((cur) => qty <= 0 ? cur.filter((_, i) => i !== idx) : cur.map((l, i) => (i === idx ? { ...l, qty } : l)))
  const park = () => { if (!lines.length) return; setHeld((h) => [...h, { id: uuid(), at: new Date().toISOString(), lines, customer, note: saleNote || undefined }]); clear() }
  const recall = (h: Held) => {
    // the sale on screen is parked first so nothing is lost
    setHeld((cur) => [...cur.filter((x) => x.id !== h.id), ...(lines.length ? [{ id: uuid(), at: new Date().toISOString(), lines, customer, note: saleNote || undefined }] : [])])
    setLines(h.lines); setCustomer(h.customer); setSaleNote(h.note ?? ''); setSel(0)
  }
  const clear = () => { setLines([]); setCustomer(null); setSaleNote(''); setSel(0); setTable(''); setCtx(null); setCoupon(null); setSplitKeys(null); setMsg(null); setDelivery(null) }
  const hasKitchen = s.has('kitchen') && (catalog?.stations ?? 0) > 0
  const hub = useHub()
  const showImages = Boolean(st.pos_show_images)
  const isTable = Boolean(ctx?.open_order_id || ctx?.table || (ctx?.label && !ctx.appointment_id && !ctx.work_order_id && !ctx.online_order_id))
  const usesStaff = s.has('commissions') || s.has('appointments')

  // ---- customer display (a second window or screen on this device)
  useEffect(() => {
    if (!s.has('customer_display') || typeof BroadcastChannel === 'undefined') return
    const ch = new BroadcastChannel(`zt-display-${tenant.id}`)
    ch.postMessage({ type: 'cart', business: lang === 'ar' && tenant.name_ar ? tenant.name_ar : tenant.name, logo: tenant.logo_url, currency: tenant.currency, decimals: d, lang,
      lines: payLines.map((l) => ({ name: lineName(l), qty: l.qty, total: calcLine(l, tenant.prices_include_tax).total, promo: l.promo_discount ? l.promo_name : null })),
      promo: totals.promo, tax: totals.tax, total: totals.total, due, customer: customer?.name ?? null, points })
    ch.close()
  })

  // ---- keyboard mode shortcuts
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (dialog || done || approval.dialog || preApproval || noteFor !== null || variantOf || modFor || weighFor || giftFor) return
      const map: Record<string, () => void> = {
        F2: () => search.current?.focus(),
        F3: () => setDialog('customer'),
        F4: () => lines.length && setDialog('qty'),
        F6: () => lines.length && setDialog('discount'),
        F7: () => lines.length && setNoteFor(sel),
        F8: () => lines.length && setDialog('pay'),
        F9: () => (lines.length && !isTable ? park() : setDialog('held')),
        F10: () => lines.length && setCartDisc(true),
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
  }, [dialog, done, lines, sel, approval.dialog, preApproval, noteFor, variantOf, modFor, weighFor, giftFor])

  // ---- package sessions on a service line
  const pkgFor = (l: CartLine) => pkgs.find((p) => p.kind === 'sessions' && (p.sessions_total ?? 0) - p.sessions_used >= l.qty && (!p.covers || (l.item_id && p.covers.includes(l.item_id))))
  async function togglePackage(idx: number) {
    const l = lines[idx]
    if (l.customer_package_id) return setLines(lines.map((x, i) => (i === idx ? { ...x, customer_package_id: null, package_value: null } : x)))
    const p = pkgFor(l); if (!p) return
    const value = await rpc<number>('package_session_value', { p_id: p.id, p_sessions: Math.round(l.qty) })
    setLines(lines.map((x, i) => (i === idx ? { ...x, qty: Math.round(x.qty), customer_package_id: p.id, package_value: Math.min(value, Math.round(x.qty * x.unit_price)) } : x)))
  }

  // ---- table orders: save / send to the kitchen
  async function saveTable(fire: boolean) {
    if (!ctx) return
    setBusy(true); setMsg(null)
    try {
      const o = await approval.run((pin) => rpc<OpenOrder>('save_open_order', { p: {
        id: ctx.open_order_id ?? null, branch_id: s.branch!.id, table_id: ctx.table?.id ?? null, label: ctx.label ?? null, customer_id: customer?.id ?? null, fire, approver_pin: pin ?? null,
        lines: lines.map((l) => ({ key: l.key, item_id: l.item_id, qty: l.qty, note: l.note ?? null, modifiers: (l.modifiers ?? []).map((m) => m.id), staff_id: l.staff_id ?? null })) } }))
      if (o) {
        if (fire) { clear(); setMsg(t('Sent to the kitchen')) }
        else { setCtx({ ...ctx, open_order_id: o.id }); setLines(lines.map((l) => ({ ...l, fired: o.lines.find((x) => x.key === l.key)?.fired ?? l.fired }))); setMsg(t('Saved')) }
      }
    } finally { setBusy(false) }
  }
  function openTable(o: OpenOrder | null, tb: DiningTable | null, label?: string) {
    setDialog(null)
    const cl: CartLine[] = (o?.lines ?? []).map((l) => {
      const it = items.find((x) => x.id === l.item_id)
      const mods = (catalog?.modOptions ?? []).filter((m) => (l.modifiers as unknown as string[] ?? []).includes(m.id))
      return { key: l.key, item_id: l.item_id, name: it?.name ?? l.name, name_ar: it?.name_ar ?? null, qty: Number(l.qty), unit_price: Number(l.unit_price), list_price: Number(l.unit_price),
               discount: 0, tax_rate: it?.tax_rate ?? tenant.vat_rate, note: l.note ?? undefined, fired: Boolean(l.fired),
               modifiers: mods.map((m) => ({ id: m.id, name: m.name, name_ar: m.name_ar, price: m.price })), staff_id: (l.staff_id as string | null) ?? null }
    })
    setCtx({ lines: cl, customer: null, open_order_id: o?.id, table: tb, label: o?.label ?? tb?.name ?? label })
    setLines(cl); setSel(0); setOrderType('dine_in'); setTable(tb?.name ?? '')
  }

  // ---- completing the sale
  function buildPayload(tenders: TenderEntry[], pin?: string) {
    return {
      tenant_id: tenant.id, branch_id: s.branch!.id, shift_id: shiftId, client_id: uuid(), customer_id: customer?.id ?? null,
      device_created_at: new Date().toISOString(), approver_pin: pin ?? null, coupon, note: saleNote.trim() || null,
      lines: payLines.map((l) => ({ item_id: l.item_id, name: l.item_id ? null : l.name, qty: l.qty, unit_price: l.unit_price, discount: l.discount, note: l.note ?? null,
        modifiers: (l.modifiers ?? []).map((m) => m.id), staff_id: l.staff_id ?? null, promo_discount: l.promo_discount ?? 0, customer_package_id: l.customer_package_id ?? null, gift_code: l.gift_code ?? null })),
      kitchen: hasKitchen && !ctx?.open_order_id ? { order_type: tenders.some((x) => x.tender === 'platform') ? 'delivery' : orderType, table_no: orderType === 'dine_in' ? table : null, hub: hubConnected() } : null,
      payments: tenders.map((x) => ({ tender: x.tender, amount: x.amount, reference: x.reference ?? null, method: x.method ?? null })),
      channel_id: tenders.find((x) => x.tender === 'platform')?.channel_id ?? null,
      external_ref: tenders.find((x) => x.tender === 'platform')?.reference ?? null,
      appointment_id: ctx?.appointment_id ?? null, work_order_id: ctx?.work_order_id ?? null,
      open_order_id: ctx?.open_order_id ?? null, open_order_keys: ctx?.open_order_id ? payLines.map((l) => l.key) : undefined,
      online_order_id: ctx?.online_order_id ?? null,
      delivery: delivery ? { address: delivery.address, phone: delivery.phone, note: delivery.note, driver_id: delivery.driver_id } : undefined,
    }
  }

  const lineName = (l: CartLine) => `${nameOf(l) || l.name}${l.modifiers?.length ? ` (${l.modifiers.map((m) => nameOf(m)).join(', ')})` : ''}`
  function receiptFromCart(tenders: TenderEntry[], change: number, number: string, offline: boolean): ReceiptData {
    const auto: TenderEntry[] = [...(totals.packages ? [{ tender: 'package' as const, amount: totals.packages }] : []), ...(deposit ? [{ tender: 'deposit' as const, amount: deposit }] : [])]
    return {
      number, doc_type: 'invoice', created_at: new Date().toISOString(), offline,
      lines: payLines.map((l) => ({ name: lineName(l), qty: l.qty, line_total: calcLine(l, tenant.prices_include_tax).total, promo: l.promo_discount ? l.promo_name : undefined })),
      subtotal: totals.net, tax_total: totals.tax, total: totals.total, discount_total: totals.discount + totals.promo,
      payments: [...auto, ...tenders].map((x) => ({ tender: x.tender, amount: x.amount, method: x.method, status: x.tender === 'payment_link' ? 'pending' : 'captured' })),
      change, customer, note: saleNote.trim() || null, cashier: s.member?.display_name,
    }
  }

  /** Builds one kitchen ticket per station from the cart (same routing as the cloud) and sends it to the branch hub. */
  function sendToHub(clientId: string, ref: string) {
    if (!hasKitchen || !hubConnected() || !catalog || ctx?.open_order_id) return
    const stations = catalog.stationList ?? []
    const fallback = [...stations].sort((a, b) => Number(b.is_default) - Number(a.is_default) || a.sort - b.sort)[0]
    if (!fallback) return
    const routeOf = (itemId: string | null) => {
      const it = items.find((x) => x.id === itemId); const c = catalog.categories.find((x) => x.id === it?.category_id)
      return stations.some((x) => x.id === c?.station_id) ? c!.station_id! : fallback.id
    }
    const groups = new Map<string, CartLine[]>()
    for (const l of payLines) { const sid = routeOf(l.item_id); groups.set(sid, [...(groups.get(sid) ?? []), l]) }
    const tickets = [...groups.entries()].map(([station_id, gl]) => ({
      id: uuid(), station_id, sale_client_id: clientId, order_ref: ref, order_type: orderType, table_no: orderType === 'dine_in' ? table || null : null,
      customer_name: customer?.name ?? null, created_at: new Date().toISOString(),
      items: gl.map((l) => ({ id: uuid(), name: lineName(l), name_ar: l.name_ar, qty: l.qty, note: l.note ?? null })),
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
    const needsServer = Boolean(ctx?.appointment_id || ctx?.work_order_id || ctx?.open_order_id || ctx?.online_order_id || delivery || totals.packages || tenders.some((x) => ['loyalty', 'gift_card', 'cod'].includes(x.tender)) || payLines.some((l) => items.find((i) => i.id === l.item_id)?.item_type === 'gift_card'))
    const offlineSale = async () => {
      if (tenders.some((x) => x.tender === 'payment_link')) { approval.setError(t('Payment links need internet.')); return }
      if (needsServer) { approval.setError(t('This checkout needs internet (package, deposit, points or table).')); return }
      await enqueueSale(payload)
      const ref = `OFF-${String(payload.client_id).slice(0, 8).toUpperCase()}`
      sendToHub(String(payload.client_id), ref)
      setDone({ receipt: receiptFromCart(tenders, change, ref, true), links: [] })
      afterSale()
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
        afterSale()
      } else if (!navigator.onLine) {
        await offlineSale()
      }
    } finally { setBusy(false) }
  }
  /** after paying part of a table, keep the rest open */
  function afterSale() {
    if (ctx?.open_order_id && splitKeys) {
      const rest = lines.filter((l) => !splitKeys.includes(l.key))
      if (rest.length) { setLines(rest); setCtx({ ...ctx, lines: rest }); setSplitKeys(null); setSel(0); return }
    }
    clear()
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
  const staffName = (id?: string | null) => catalog?.staff?.find((m) => m.user_id === id)?.display_name
  const hasCoupons = (catalog?.promos ?? []).some((p) => p.coupon_code)
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
          <button className={!cat ? 'on' : ''} onClick={() => setCat(null)} style={{ ['--cat' as string]: 'var(--ink)' }}>{t('All')}<em>{items.filter((x) => !x.parent_id).length}</em></button>
          {(catalog?.categories ?? []).map((c, idx) => (
            <button key={c.id} className={cat === c.id ? 'on' : ''} onClick={() => setCat(c.id)} style={{ ['--cat' as string]: `var(--c${(idx % 8) + 1})` }}>
              <i className="cat-dot" aria-hidden="true" />{nameOf(c)}<em>{items.filter((x) => x.category_id === c.id && !x.parent_id).length}</em>
            </button>))}
        </div>
        {mode === 'touch' ? (
          <div className="tiles">
            {filtered.slice(0, 200).map((i) => {
              const inCart = lines.filter((l) => l.item_id === i.id || items.find((x) => x.id === l.item_id)?.parent_id === i.id).reduce((a, l) => a + l.qty, 0)
              const idx = (catalog?.categories ?? []).findIndex((c) => c.id === i.category_id)
              const label = nameOf(i)
              return (
                <button key={i.id} className={`tile ${inCart ? 'in' : ''}`} onClick={() => add(i)} style={{ ['--cat' as string]: idx >= 0 ? `var(--c${(idx % 8) + 1})` : 'var(--muted)' }}>
                  {showImages && i.image_url
                    ? <img className="tile-img" src={i.image_url} alt="" loading="lazy" />
                    : <span className="tile-mono" aria-hidden="true">{label.trim().charAt(0)}</span>}
                  <span className="tile-name">{label}</span>
                  <span className="tile-price">{num(i.price, d)}{i.sold_by_weight ? <small>/{t('kg')}</small> : ''}</span>
                  {(i.is_template || (s.has('modifiers') && groupsOf(i.id).length > 0)) && <span className="tile-more" aria-hidden="true">⋯</span>}
                  {inCart > 0 && <span className="tile-qty" aria-label={t('In cart')}>{Number(inCart.toFixed(3))}</span>}
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
        {(hasKitchen || s.has('tables') || s.has('own_delivery') || s.has('qr_ordering') || s.has('customer_display')) && (
          <div className="order-bar">
            {s.has('qr_ordering') && <button className={`ghost incoming-btn ${incoming.some((o) => o.status === 'pending') ? 'alert' : ''}`} onClick={() => setDialog('incoming')}><Inbox size={16} aria-hidden="true" />{t('Online orders')}{incoming.length > 0 && <em className="badge">{incoming.length}</em>}</button>}
            {s.has('own_delivery') && !isTable && <button className={`ghost ${delivery ? 'on' : ''}`} onClick={() => setDialog('delivery')}><Bike size={16} aria-hidden="true" />{delivery ? t('Own delivery ✓') : t('Own delivery')}</button>}
            {s.has('customer_display') && <button className="icon" title={t('Customer display')} aria-label={t('Customer display')} onClick={() => window.open('/display', 'zt-display', 'width=1024,height=700')}><MonitorSmartphone size={18} /></button>}
            {s.has('tables') && <button className={`ghost tables-btn ${isTable ? 'on' : ''}`} onClick={() => setDialog('tables')}><LayoutGrid size={16} aria-hidden="true" />{isTable ? (ctx?.label ?? t('Table')) : t('Tables')}</button>}
            {hasKitchen && !isTable && (
              <div className="seg" role="group" aria-label={t('Order type')}>
                {(['takeaway', 'dine_in', 'delivery'] as const).map((x) => (
                  <button key={x} className={orderType === x ? 'on' : ''} onClick={() => setOrderType(x)}>{t({ takeaway: 'Takeaway', dine_in: 'Dine-in', delivery: 'Delivery' }[x])}</button>))}
              </div>)}
            {hasKitchen && !isTable && orderType === 'dine_in' && !s.has('tables') && <input id="pos-table" className="table-in" placeholder={t('Table')} value={table} onChange={(e) => setTable(e.target.value)} />}
            {hub.status !== 'off' && <span className={`hub-badge ${hub.status}`} title={t('Branch hub')}>{hub.status === 'connected' ? t('Kitchen via hub') : t('Hub reconnecting…')}</span>}
          </div>
        )}
        {ctx && (ctx.appointment_id || ctx.work_order_id || ctx.online_order_id) && (
          <div className="ctx-bar"><Ticket size={15} aria-hidden="true" />{ctx.label}{deposit > 0 && <span className="pill">{t('Deposit')} −{num(deposit, d)}</span>}
            <button className="icon" aria-label={t('Clear')} onClick={clear}><X size={14} /></button></div>)}
        <header className="cart-head">
          <button className="ghost" onClick={() => setDialog('customer')}><UserRound size={16} aria-hidden="true" />{customer ? customer.name : t('Walk-in customer')} <kbd>F3</kbd>
            {points != null && <em className="badge pts">{t('{n} pts', { n: points })}</em>}</button>
          {!isTable && <button className="ghost" disabled={!lines.length} onClick={park} title={t('Park this sale and start a new one')}><PauseCircle size={16} aria-hidden="true" />{t('Park')} <kbd>F9</kbd></button>}
        </header>
        {!isTable && held.length > 0 && (
          <div className="park-chips" aria-label={t('Parked sales')}>
            {held.map((h) => (
              <button key={h.id} className="chipbtn" onClick={() => recall(h)} title={t('Recall')}>
                <PauseCircle size={13} aria-hidden="true" />{h.customer?.name ?? new Date(h.at).toLocaleTimeString(lang === 'ar' ? 'ar-KW' : 'en-GB', { hour: '2-digit', minute: '2-digit' })}
                <b>{num(calcCart(h.lines, tenant.prices_include_tax).total, d)}</b></button>))}
            <button className="chipbtn ghost" onClick={() => setDialog('held')}>{t('All')}</button>
          </div>)}
        {saleNote && <button className="sale-note" onClick={() => setNoteSale(true)}><StickyNote size={14} aria-hidden="true" />{saleNote}</button>}
        <div className="paper">
          <div className="paper-head"><span>{isTable ? ctx?.label : t('Ticket')}</span><span>{Number(lines.reduce((a, l) => a + l.qty, 0).toFixed(3))} {t('items')}</span></div>
          <ul className="cart-lines">
            {priced.map((l, i) => {
              const c = calcLine(l, tenant.prices_include_tax)
              const inSplit = !splitKeys || splitKeys.includes(l.key)
              return (
                <li key={l.key} className={`${i === sel ? 'sel' : ''} ${inSplit ? '' : 'dim'}`} onClick={() => setSel(i)}>
                  <div className="cl-main">
                    {splitKeys && <input type="checkbox" aria-label={t('Pay now')} checked={inSplit} onClick={(e) => e.stopPropagation()}
                      onChange={(e) => setSplitKeys(e.target.checked ? [...splitKeys, l.key] : splitKeys.filter((k) => k !== l.key))} />}
                    <span className="cl-q">{Number(l.qty.toFixed(3))}×</span>
                    <span className="cl-name">{nameOf(l)}{l.fired && <ChefHat size={13} className="fired" aria-label={t('Sent to the kitchen')} />}</span>
                    <span className="cl-lead" aria-hidden="true" />
                    <span className="cl-total">{num(c.total, d)}</span>
                  </div>
                  {(l.note || l.discount > 0 || l.unit_price !== l.list_price || l.modifiers?.length || l.promo_discount || l.staff_id || l.customer_package_id) && (
                    <div className="cl-sub">
                      {l.modifiers?.map((m) => <span key={m.id} className="mod-tag">+ {nameOf(m)}</span>)}
                      {!!l.promo_discount && <span className="tag promo"><Tag size={11} aria-hidden="true" /> {l.promo_name} −{num(l.promo_discount, d)}</span>}
                      {l.customer_package_id && <span className="tag promo"><Gift size={11} aria-hidden="true" /> {t('From package')}</span>}
                      {(l.discount > 0 || l.unit_price !== l.list_price) && <span className="tag">{t('Discount')} −{num(l.discount + Math.max(0, Math.round(l.qty * (l.list_price - l.unit_price))), d)}</span>}
                      {l.staff_id && usesStaff && <span className="staff-tag">{staffName(l.staff_id)}</span>}
                      {l.note && <span className="cl-note">» {l.note}</span>}
                    </div>)}
                  {i === sel && (
                    <div className="cl-qty">
                      <button className="icon" aria-label="-" onClick={(e) => { e.stopPropagation(); setQty(i, l.qty - 1) }}><Minus size={16} /></button>
                      <span>{Number(l.qty.toFixed(3))}</span>
                      <button className="icon" aria-label="+" onClick={(e) => { e.stopPropagation(); setQty(i, l.qty + 1) }}><Plus size={16} /></button>
                      <span className="cl-unit muted">@ {num(l.unit_price, d)}</span>
                      {pkgs.length > 0 && (l.customer_package_id || pkgFor(l)) && (
                        <button className="ghost small" onClick={(e) => { e.stopPropagation(); void togglePackage(i) }}><Gift size={14} />{l.customer_package_id ? t('Pay normally') : t('Use package')}</button>)}
                    </div>)}
                </li>
              )
            })}
            {lines.length === 0 && <li className="empty-cart"><ScanLine size={28} aria-hidden="true" />{t('Scan or tap a product to start a sale')}</li>}
          </ul>
          <div className="paper-totals">
            {totals.promo > 0 && <div className="promo"><span>{t('Promotions')}</span><span>−{num(totals.promo, d)}</span></div>}
            {totals.discount > 0 && <div><span>{t('Discount')}</span><span>−{num(totals.discount, d)} ({totals.discountPct}%)</span></div>}
            <div><span>{t('VAT')}</span><span>{num(totals.tax, d)}</span></div>
            {(totals.packages > 0 || deposit > 0) && <div><span>{t('Total')}</span><span>{fmt(totals.total, tenant, lang)}</span></div>}
            {totals.packages > 0 && <div><span>{t('Paid by package')}</span><span>−{num(totals.packages, d)}</span></div>}
            {deposit > 0 && <div><span>{t('Deposit paid')}</span><span>−{num(deposit, d)}</span></div>}
            <div className="grand"><span>{totals.packages > 0 || deposit > 0 ? t('To pay') : t('Total')}</span><span>{fmt(due, tenant, lang)}</span></div>
          </div>
        </div>
        <div className="cart-actions">
          <button disabled={!line} onClick={() => setDialog('qty')}>{t('Qty')} <kbd>F4</kbd></button>
          <button disabled={!line} onClick={() => setDialog('discount')}>{t('Discount')} <kbd>F6</kbd></button>
          <button disabled={!line} onClick={() => setNoteFor(sel)}>{t('Line note')} <kbd>F7</kbd></button>
          <button disabled={!lines.length} onClick={() => setCartDisc(true)}>{t('Invoice discount')} <kbd>F10</kbd></button>
          <button onClick={() => setNoteSale(true)}><StickyNote size={15} aria-hidden="true" />{t('Invoice note')}</button>
          {usesStaff && <button disabled={!line} onClick={() => setDialog('staff')}><UsersRound size={15} aria-hidden="true" />{t('Staff')}</button>}
          {hasCoupons && <button onClick={() => setDialog('coupon')}><Tag size={15} aria-hidden="true" />{coupon ?? t('Coupon')}</button>}
          <button disabled={!line} onClick={() => setQty(sel, 0)}>{t('Remove')} <kbd>Del</kbd></button>
          {isTable && lines.length > 1 && <button onClick={() => setSplitKeys(splitKeys ? null : lines.map((l) => l.key))}>{splitKeys ? t('Pay all') : t('Split bill')}</button>}
          <button disabled={!lines.length && !ctx} onClick={clear}>{isTable ? t('Close') : t('Clear')}</button>
        </div>
        {approval.error && <p className="error">{approval.error}</p>}
        {msg && <p className="success" role="status">{msg}</p>}
        {isTable && (
          <div className="pay-row table-row">
            <button className="quick" disabled={!lines.length || busy} onClick={() => void saveTable(false)}><Save size={18} aria-hidden="true" />{t('Save order')}</button>
            {hasKitchen && <button className="quick" disabled={!lines.some((l) => !l.fired) || busy} onClick={() => void saveTable(true)}><ChefHat size={18} aria-hidden="true" />{t('Send to kitchen')}</button>}
          </div>)}
        <div className="pay-row">
          <button className="quick" disabled={!payLines.length || busy || due <= 0} onClick={() => void finish([{ tender: 'cash', amount: due }], 0)} title={t('Customer pays the exact amount in cash')}>
            <Banknote size={18} aria-hidden="true" />{t('Exact cash')}</button>
          <button className="quick" disabled={!payLines.length || busy || due <= 0} onClick={() => void finish([{ tender: 'card', amount: due, method: cardMethods(tenant.country_code)[0] }], 0)} title={t('Paid in full by card')}>
            <CreditCard size={18} aria-hidden="true" />{t('Card')}<small className="quick-sub">{cardMethods(tenant.country_code)[0]}</small></button>
          <button className="primary pay-btn" disabled={!payLines.length || busy} onClick={() => (due <= 0 ? void finish([], 0) : setDialog('pay'))}>
            <span>{busy ? t('Please wait…') : due <= 0 ? t('Confirm') : t('Pay')}</span><b>{fmt(due, tenant, lang)}</b><kbd>F8</kbd>
          </button>
        </div>
      </section>

      {dialog === 'pay' && (
        <PayDialog total={due} tenant={tenant} customer={customer} online={online} channels={catalog?.channels ?? []} cod={Boolean(delivery)} giftCards={s.has('gift_cards')}
                   points={s.has('loyalty') ? points : null}
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
      {weighFor && (
        <NumberDialog title={t('Weight of {name} (kg)', { name: nameOf(weighFor) })} initial="" onClose={() => setWeighFor(null)}
          onSave={(v) => { const n = parseFloat(v); if (n > 0) addLine(weighFor, Math.round(n * 1000) / 1000); setWeighFor(null) }} />
      )}
      {variantOf && <VariantPicker template={variantOf} items={items} tenant={tenant} onClose={() => setVariantOf(null)} onPick={(v) => { setVariantOf(null); add(v) }} />}
      {modFor && <ModifierDialog item={modFor} groups={groupsOf(modFor.id)} options={catalog?.modOptions ?? []} decimals={d} onClose={() => setModFor(null)}
        onConfirm={(o) => { const it = modFor; setModFor(null); if (it.sold_by_weight) setWeighFor(it); else addLine(it, 1, o) }} />}
      {dialog === 'discount' && line && (
        <DiscountDialog lineTotal={Math.round(line.qty * line.unit_price)} decimals={d} onClose={() => setDialog(null)}
          onSave={(minor) => { setLines(lines.map((l, i) => (i === sel ? { ...l, discount: minor } : l))); setDialog(null) }} />
      )}
      {dialog === 'staff' && line && (
        <StaffPicker staff={catalog?.staff ?? []} current={line.staff_id} onClose={() => setDialog(null)}
          onPick={(id) => { setLines(lines.map((l, i) => (i === sel ? { ...l, staff_id: id } : l))); setDialog(null) }} />
      )}
      {dialog === 'coupon' && (
        <TextDialog title={t('Coupon code')} initial={coupon ?? ''} suggestions={[]} onClose={() => setDialog(null)}
          onSave={(v) => { setCoupon(v.trim().toUpperCase() || null); setDialog(null) }} />
      )}
      {giftFor && <GiftCardDialog item={giftFor} decimals={d} onClose={() => setGiftFor(null)}
        onAdd={(amount, code) => { const it = giftFor; setGiftFor(null); setLines((cur) => [...cur, { key: uuid(), item_id: it.id, name: it.name, name_ar: it.name_ar, qty: 1, unit_price: amount, list_price: amount, discount: 0, tax_rate: 0, gift_code: code || undefined }]); setSel(lines.length) }} />}
      {dialog === 'delivery' && <DeliveryDialog customer={customer} drivers={(catalog?.staff ?? []).filter((m) => (m as { is_driver?: boolean }).is_driver)} initial={delivery}
        onPickCustomer={() => setDialog('customer')} onClose={() => setDialog(null)} onSave={(d2) => { setDelivery(d2); setDialog(null) }} />}
      {dialog === 'incoming' && <IncomingOrders orders={incoming} tenant={tenant} onClose={() => setDialog(null)} onChanged={() => void loadIncoming()} onPay={payKiosk} />}
      {dialog === 'tables' && <TablesDialog branchId={s.branch.id} tenant={tenant} onClose={() => setDialog(null)} onOpen={openTable} />}
      {dialog === 'held' && (
        <Modal title={t('Held sales')} onClose={() => setDialog(null)}>
          <div className="stack">
            <button className="primary" disabled={!lines.length} onClick={() => { park(); setDialog(null) }}>{t('Hold current sale')}</button>
            <ul className="pick-list">{held.map((h) => (
              <li key={h.id}><button onClick={() => { recall(h); setDialog(null) }}>
                <b>{new Date(h.at).toLocaleTimeString()}</b><span>{h.lines.length} {t('items')} · {fmt(calcCart(h.lines, tenant.prices_include_tax).total, tenant, lang)}</span></button></li>
            ))}</ul>
          </div>
        </Modal>
      )}
      {noteSale && <TextDialog title={t('Invoice note')} initial={saleNote} suggestions={[]} onClose={() => setNoteSale(false)} onSave={(v) => { setSaleNote(v.trim()); setNoteSale(false) }} />}
      {cartDisc && <DiscountDialog title={t('Invoice discount')} lineTotal={discBase(lines).reduce((a, b) => a + b, 0)} decimals={d} onClose={() => setCartDisc(false)}
        onSave={(minor) => { setLines(spreadDiscount(lines, minor)); setCartDisc(false) }} />}
      {noteFor !== null && lines[noteFor] && (
        <TextDialog title={t('Note')} initial={lines[noteFor].note ?? ''} suggestions={hasKitchen || isTable ? [t('No onion'), t('Extra hot'), t('No sugar'), t('Well done')] : []}
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
                    <a className="button" href={`https://wa.me/${(done.receipt.customer?.phone ?? '').replace(/\D/g, '')}?text=${text}`} target="_blank" rel="noreferrer">{t('Send by WhatsApp')}</a>
                  </div>
                </div>
              )
            })}
            <div className="receipt-preview"><Receipt data={done.receipt} tenant={tenant} branch={s.branch} /></div>
            <PrintButtons onPrint={(paper) => setPrinting({ ...done.receipt, paper })} />
            <div className="row end"><button className="primary" autoFocus onClick={() => setDone(null)}>{t('New sale')}</button></div>
          </div>
        </Modal>
      )}
      {printing && <PrintReceipt data={printing} tenant={tenant} branch={s.branch} onDone={() => setPrinting(null)} />}
    </div>
  )
}

/** Print on the paper the customer asks for: 80 mm, 58 mm or an A4 invoice. The device's usual paper is first. */
export function PrintButtons({ onPrint }: { onPrint: (paper: '80' | '58' | 'a4') => void }) {
  const { t } = useT()
  const def = (() => { try { return (localStorage.getItem('zt.paper') as '80' | '58' | 'a4' | null) ?? '80' } catch { return '80' } })()
  const order = [def, ...(['80', '58', 'a4'] as const).filter((x) => x !== def)]
  return (
    <div className="print-row" role="group" aria-label={t('Print receipt')}>
      <span className="muted small">{t('Print')}</span>
      {order.map((p, i) => <button key={p} className={i === 0 ? 'primary-outline' : 'ghost'} onClick={() => onPrint(p)}>{p === 'a4' ? t('A4 invoice') : `${p} mm`}</button>)}
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

/** What each line can be discounted on: its price × qty less promotions. Package sessions and gift cards are never discounted. */
function discBase(lines: CartLine[]) {
  return lines.map((l) => (l.customer_package_id || l.gift_code ? 0 : Math.max(0, pgRound(l.qty * l.unit_price) - (l.promo_discount ?? 0))))
}
/** An invoice discount is spread over the lines in proportion to their value, as ordinary line discounts (so discount limits and approvals still apply). */
export function spreadDiscount(lines: CartLine[], total: number): CartLine[] {
  const base = discBase(lines), sum = base.reduce((a, b) => a + b, 0)
  if (sum <= 0) return lines
  const amt = Math.min(total, sum)
  let left = amt
  const last = base.map((b, i) => (b > 0 ? i : -1)).filter((i) => i >= 0).pop()!
  return lines.map((l, i) => {
    if (base[i] <= 0) return l
    const share = i === last ? left : Math.min(base[i], Math.floor((amt * base[i]) / sum))
    left -= share
    return { ...l, discount: share }
  })
}

function DiscountDialog({ lineTotal, decimals, onSave, onClose, title }: { lineTotal: number; decimals: number; onSave: (minor: number) => void; onClose: () => void; title?: string }) {
  const { t } = useT()
  const [kind, setKind] = useState<'pct' | 'amt'>('pct')
  const [v, setV] = useState('')
  const minor = kind === 'pct' ? Math.round((lineTotal * (parseFloat(v) || 0)) / 100) : toMinor(v || '0', decimals)
  const ok = Number.isFinite(minor) && minor >= 0 && minor <= lineTotal
  return (
    <Modal title={title ?? t('Line discount')} onClose={onClose}>
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
        {suggestions.length > 0 && <div className="quick">{suggestions.map((x) => <button type="button" key={x} className="chipbtn" onClick={() => setV(v ? `${v}, ${x}` : x)}>{x}</button>)}</div>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

export const posError = (e: unknown) => { const p = parseError(e); return p.kind === 'message' ? p.message : p.perm }

import { Minus, Plus, ShoppingBag } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { useParams, useSearchParams } from 'react-router-dom'
import { Logo, Modal } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt } from '../lib/money'
import { parseError, rpc } from '../lib/supabase'

interface Opt { id: string; name: string; name_ar: string | null; price: number }
interface Group { id: string; name: string; name_ar: string | null; min_select: number; max_select: number; options: Opt[] }
interface MItem { id: string; name: string; name_ar: string | null; price: number; image_url: string | null; category_id: string | null; groups: string[] }
interface Menu {
  business: string; business_ar: string | null; logo_url: string | null; brand_color: string | null; currency: string; decimals: number
  table: { id: string; name: string } | null; categories: { id: string; name: string; name_ar: string | null }[]; items: MItem[]; groups: Group[]
}
interface Line { key: string; item: MItem; qty: number; mods: Opt[]; note: string }

/**
 * Ordering from the table (QR code on the table: /order/<shop>?t=<table code>) or from a kiosk (/order/<shop>?kiosk=1).
 * Table orders go to staff to accept and then to the kitchen; kiosk orders are paid at the counter.
 */
export default function Order() {
  const { slug = '' } = useParams()
  const [qs] = useSearchParams()
  const table = qs.get('t'), kiosk = qs.get('kiosk') === '1'
  const { t, lang, setLang } = useT()
  const [menu, setMenu] = useState<Menu | null | undefined>(undefined)
  const [cat, setCat] = useState<string | null>(null)
  const [cart, setCart] = useState<Line[]>([])
  const [pick, setPick] = useState<MItem | null>(null)
  const [open, setOpen] = useState(false)
  const [who, setWho] = useState({ name: '', note: '' })
  const [sent, setSent] = useState<{ id: string; number: number } | null>(null)
  const [status, setStatus] = useState<string>('pending')
  const [err, setErr] = useState<string | null>(null)
  const nm = (x: { name: string; name_ar?: string | null }) => (lang === 'ar' && x.name_ar ? x.name_ar : x.name)
  useEffect(() => { rpc<Menu | null>('menu_info', { p_slug: slug, p_table: table }).then(setMenu).catch(() => setMenu(null)) }, [slug, table])
  useEffect(() => {
    if (!sent) return
    const id = window.setInterval(() => void rpc<{ status: string }>('order_status', { p_id: sent.id }).then((r) => setStatus(r.status)).catch(() => undefined), 8000)
    return () => clearInterval(id)
  }, [sent])
  const money = (v: number) => (menu ? fmt(v, { currency: menu.currency, currency_decimals: menu.decimals }, lang) : '')
  const shown = useMemo(() => (menu?.items ?? []).filter((i) => !cat || i.category_id === cat), [menu, cat])
  const unit = (l: Line) => l.item.price + l.mods.reduce((a, o) => a + o.price, 0)
  const total = cart.reduce((a, l) => a + unit(l) * l.qty, 0)
  const count = cart.reduce((a, l) => a + l.qty, 0)
  function add(i: MItem) {
    if (i.groups.length) return setPick(i)
    const idx = cart.findIndex((l) => l.item.id === i.id && !l.mods.length)
    if (idx >= 0) setCart(cart.map((l, j) => (j === idx ? { ...l, qty: l.qty + 1 } : l)))
    else setCart([...cart, { key: crypto.randomUUID(), item: i, qty: 1, mods: [], note: '' }])
  }
  async function send() {
    setErr(null)
    try {
      const r = await rpc<{ id: string; number: number }>('place_order', { p_slug: slug, p: { table, kiosk, name: who.name, note: who.note,
        lines: cart.map((l) => ({ key: l.key, item_id: l.item.id, qty: l.qty, modifiers: l.mods.map((o) => o.id), note: l.note || null })) } })
      setSent(r); setCart([]); setOpen(false); setStatus('pending')
    } catch (e) { const p = parseError(e); setErr(p.kind === 'message' ? t(p.message) : '') }
  }
  if (menu === undefined) return <div className="splash">{t('Loading…')}</div>
  if (!menu || (!menu.table && !kiosk)) return <div className="auth"><div className="auth-card"><p className="error">{t('This ordering link is not valid. Scan the code on your table again.')}</p></div></div>
  if (sent) {
    return (
      <div className={`order-page ${kiosk ? 'kiosk' : ''}`}><div className="order-done">
        {menu.logo_url && <img className="paylink-logo" src={menu.logo_url} alt="" />}
        <p className="muted">{t('Your order number')}</p><b className="order-no">#{sent.number}</b>
        <p>{kiosk ? t('Please pay at the counter. We start preparing once paid.') : status === 'pending' ? t('Sent. A staff member will confirm it shortly.') : status === 'rejected' ? t('Sorry, the staff could not accept this order. Please ask a staff member.') : t('Confirmed and sent to the kitchen.')}</p>
        <button className="primary big" onClick={() => setSent(null)}>{kiosk ? t('New order') : t('Order more')}</button>
      </div></div>
    )
  }
  return (
    <div className={`order-page ${kiosk ? 'kiosk' : ''}`} style={menu.brand_color ? { ['--brand' as string]: menu.brand_color } : undefined}>
      <header className="order-head">
        {menu.logo_url ? <img src={menu.logo_url} alt="" /> : <Logo size={36} tile />}
        <div><b>{lang === 'ar' && menu.business_ar ? menu.business_ar : menu.business}</b><span className="muted small">{menu.table ? `${t('Table')} ${menu.table.name}` : t('Self-order')}</span></div>
        <button className="ghost small" onClick={() => setLang(lang === 'ar' ? 'en' : 'ar')}>{lang === 'ar' ? 'English' : 'العربية'}</button>
      </header>
      <nav className="order-cats">
        <button className={!cat ? 'on' : ''} onClick={() => setCat(null)}>{t('All')}</button>
        {menu.categories.filter((c) => menu.items.some((i) => i.category_id === c.id)).map((c) => <button key={c.id} className={cat === c.id ? 'on' : ''} onClick={() => setCat(c.id)}>{nm(c)}</button>)}
      </nav>
      <div className="order-grid">{shown.map((i) => (
        <button key={i.id} className="order-item" onClick={() => add(i)}>
          {i.image_url ? <img src={i.image_url} alt="" loading="lazy" /> : <span className="tile-mono">{nm(i).charAt(0)}</span>}
          <b>{nm(i)}</b><span>{money(i.price)}</span>
        </button>))}</div>
      {count > 0 && <button className="primary order-cart-btn" onClick={() => setOpen(true)}><ShoppingBag size={18} />{t('View order')} · {count} · {money(total)}</button>}
      {pick && <PickMods item={pick} groups={menu.groups.filter((g) => pick.groups.includes(g.id))} money={money} nm={nm} onClose={() => setPick(null)}
        onAdd={(mods) => { setCart([...cart, { key: crypto.randomUUID(), item: pick, qty: 1, mods, note: '' }]); setPick(null) }} />}
      {open && (
        <Modal title={t('Your order')} onClose={() => setOpen(false)}>
          <div className="stack">
            <ul className="mod-list">{cart.map((l, i) => (
              <li key={l.key}><div><b>{nm(l.item)}</b>{l.mods.length > 0 && <p className="muted small">{l.mods.map(nm).join(', ')}</p>}</div>
                <span className="row"><button className="icon" aria-label="-" onClick={() => setCart(l.qty > 1 ? cart.map((x, j) => (j === i ? { ...x, qty: x.qty - 1 } : x)) : cart.filter((_, j) => j !== i))}><Minus size={15} /></button>
                  {l.qty}<button className="icon" aria-label="+" onClick={() => setCart(cart.map((x, j) => (j === i ? { ...x, qty: x.qty + 1 } : x)))}><Plus size={15} /></button>
                  <b>{money(unit(l) * l.qty)}</b></span></li>))}</ul>
            <label className="field"><span>{t('Your name (optional)')}</span><input id="ord-name" value={who.name} onChange={(e) => setWho({ ...who, name: e.target.value })} /></label>
            <label className="field"><span>{t('Note (optional)')}</span><input id="ord-note" value={who.note} onChange={(e) => setWho({ ...who, note: e.target.value })} placeholder={t('e.g. no onion')} /></label>
            {err && <p className="error">{err}</p>}
            <button className="primary big" onClick={() => void send()}>{kiosk ? t('Order and pay at the counter') : t('Send order')} · {money(total)}</button>
          </div>
        </Modal>)}
    </div>
  )
}

function PickMods({ item, groups, money, nm, onAdd, onClose }: { item: MItem; groups: Group[]; money: (v: number) => string; nm: (x: { name: string; name_ar?: string | null }) => string; onAdd: (o: Opt[]) => void; onClose: () => void }) {
  const { t } = useT()
  const [picked, setPicked] = useState<Opt[]>([])
  const ok = groups.every((g) => { const n = picked.filter((o) => g.options.some((x) => x.id === o.id)).length; return n >= g.min_select && n <= g.max_select })
  const toggle = (g: Group, o: Opt) => {
    if (picked.some((x) => x.id === o.id)) return setPicked(picked.filter((x) => x.id !== o.id))
    const inG = picked.filter((x) => g.options.some((y) => y.id === x.id))
    if (g.max_select === 1) return setPicked([...picked.filter((x) => !g.options.some((y) => y.id === x.id)), o])
    if (inG.length < g.max_select) setPicked([...picked, o])
  }
  return (
    <Modal title={nm(item)} onClose={onClose}>
      <div className="stack">
        {groups.map((g) => (
          <div key={g.id} className="stack tight"><span className="mod-head">{nm(g)} <em className="muted small">{g.min_select > 0 ? t('Required') : t('Optional')}</em></span>
            <div className="chip-pick">{g.options.map((o) => <button key={o.id} className={picked.some((x) => x.id === o.id) ? 'on' : ''} onClick={() => toggle(g, o)}>{nm(o)}{o.price > 0 && <small> +{money(o.price)}</small>}</button>)}</div></div>))}
        <button className="primary" disabled={!ok} onClick={() => onAdd(picked)}>{t('Add')} · {money(item.price + picked.reduce((a, o) => a + o.price, 0))}</button>
      </div>
    </Modal>
  )
}

import { ArrowRight, CornerDownLeft, FileText, Languages, Package, Palette, PanelLeft, Plus, Search, User, Wrench } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useT } from '../lib/i18n'
import { fmt } from '../lib/money'
import type { NavItem } from '../lib/nav'
import { THEMES, usePrefs } from '../lib/prefs'
import { useSession } from '../lib/session'
import { norm } from '../lib/shift'
import { supabase } from '../lib/supabase'

interface Cmd { id: string; label: string; hint?: string; group: string; icon: typeof Search; run: () => void; keys?: string }

/** Ctrl K: jump to any screen, run an action, or find a customer, product, invoice or job card by typing. */
export function CommandPalette({ nav, onClose }: { nav: NavItem[]; onClose: () => void }) {
  const { t, lang, setLang } = useT()
  const s = useSession()
  const go = useNavigate()
  const { prefs, set } = usePrefs()
  const [q, setQ] = useState('')
  const [sel, setSel] = useState(0)
  const [found, setFound] = useState<Cmd[]>([])
  const input = useRef<HTMLInputElement>(null)
  const list = useRef<HTMLUListElement>(null)
  const tn = s.tenant!
  const navTo = (to: string) => { go(to); onClose() }

  const fixed = useMemo<Cmd[]>(() => {
    const has = (to: string) => nav.some((n) => n.to === to)
    const actions: (Cmd & { ok: boolean })[] = [
      { id: 'a-sale', label: t('New sale'), group: t('Actions'), icon: Plus, run: () => navTo('/pos'), ok: has('/pos'), keys: 'sell بيع' },
      { id: 'a-shift', label: t('Open or close the shift'), group: t('Actions'), icon: Plus, run: () => navTo('/shift'), ok: has('/shift'), keys: 'وردية' },
      { id: 'a-item', label: t('Add item'), group: t('Actions'), icon: Plus, run: () => navTo('/products?new=1'), ok: s.can('catalog.manage'), keys: 'product صنف' },
      { id: 'a-cust', label: t('Add customer'), group: t('Actions'), icon: Plus, run: () => navTo('/customers?new=1'), ok: has('/customers'), keys: 'عميل' },
      { id: 'a-appt', label: t('New appointment'), group: t('Actions'), icon: Plus, run: () => navTo('/calendar?new=1'), ok: has('/calendar'), keys: 'موعد' },
      { id: 'a-job', label: t('New job card'), group: t('Actions'), icon: Plus, run: () => navTo('/orders?new=1'), ok: has('/orders'), keys: 'تذكرة' },
      { id: 'a-res', label: t('New reservation'), group: t('Actions'), icon: Plus, run: () => navTo('/reservations?new=1'), ok: has('/reservations'), keys: 'حجز' },
      { id: 'a-lang', label: lang === 'ar' ? 'English' : 'العربية', group: t('Actions'), icon: Languages, run: () => { setLang(lang === 'ar' ? 'en' : 'ar'); onClose() }, ok: true, keys: 'language لغة' },
      { id: 'a-side', label: t(prefs.sidebar === 'closed' ? 'Expand menu' : 'Collapse menu'), group: t('Actions'), icon: PanelLeft, run: () => { set({ sidebar: prefs.sidebar === 'closed' ? 'open' : 'closed' }); onClose() }, ok: true, keys: 'sidebar قائمة' },
    ]
    const themes: Cmd[] = THEMES.map((th) => ({ id: `t-${th.key}`, label: `${t('Theme')}: ${t(th.name)}`, group: t('Theme'), icon: Palette, run: () => { set({ theme: th.key }); onClose() }, keys: 'theme ثيم مظهر' }))
    const screens: Cmd[] = nav.map((n) => ({ id: `n-${n.to}`, label: t(n.label), hint: n.to, group: t('Screens'), icon: n.icon, run: () => navTo(n.to), keys: n.keys }))
    const settingsTabs: Cmd[] = has('/settings') ? [['modules', 'Business type & modules'], ['business', 'Business and receipt'], ['staff', 'Staff'], ['roles', 'Roles & permissions'], ['integrations', 'Integrations'], ['device', 'This device']]
      .map(([k, l]) => ({ id: `s-${k}`, label: `${t('Settings')} · ${t(l)}`, group: t('Settings'), icon: Wrench, run: () => navTo(`/settings?tab=${k}`) })) : []
    return [...screens, ...actions.filter((a) => a.ok), ...settingsTabs, ...themes]
  }, [nav, t, lang, prefs.sidebar]) // eslint-disable-line react-hooks/exhaustive-deps

  // live search in the business's data
  useEffect(() => {
    const term = q.trim()
    if (term.length < 2) { setFound([]); return }
    const safe = term.replace(/[%,()]/g, '')
    const id = window.setTimeout(async () => {
      const [c, i, sa, w] = await Promise.all([
        s.can('sale.create') || s.can('customers.manage') ? supabase.from('customers').select('id, name, phone').eq('tenant_id', tn.id).or(`name.ilike.%${safe}%,phone.ilike.%${safe}%`).limit(5) : Promise.resolve({ data: [] }),
        supabase.from('items').select('id, name, name_ar, barcode, price').eq('tenant_id', tn.id).or(`name.ilike.%${safe}%,name_ar.ilike.%${safe}%,barcode.eq.${safe},sku.eq.${safe}`).limit(5),
        s.can('sale.create') || s.can('reports.all') ? supabase.from('sales').select('id, number, total, created_at').eq('tenant_id', tn.id).ilike('number', `%${safe}%`).order('created_at', { ascending: false }).limit(5) : Promise.resolve({ data: [] }),
        s.has('job_cards') || s.has('preorders') ? supabase.from('work_orders').select('id, number, reference, status').eq('tenant_id', tn.id).or(`number.ilike.%${safe}%,reference.ilike.%${safe}%,tags.ilike.%${safe}%`).limit(5) : Promise.resolve({ data: [] }),
      ])
      setFound([
        ...((c.data ?? []) as { id: string; name: string; phone: string | null }[]).map((x) => ({ id: `c-${x.id}`, label: x.name, hint: x.phone ?? '', group: t('Customers'), icon: User, run: () => navTo(`/customers?c=${x.id}`) })),
        ...((i.data ?? []) as { id: string; name: string; name_ar: string | null; barcode: string | null; price: number }[]).map((x) => ({ id: `i-${x.id}`, label: lang === 'ar' && x.name_ar ? x.name_ar : x.name, hint: `${x.barcode ?? ''} · ${fmt(x.price, tn, lang)}`, group: t('Products'), icon: Package, run: () => navTo(`/products?q=${encodeURIComponent(x.name)}`) })),
        ...((sa.data ?? []) as { id: string; number: string; total: number; created_at: string }[]).map((x) => ({ id: `v-${x.id}`, label: x.number, hint: `${fmt(x.total, tn, lang)} · ${new Date(x.created_at).toLocaleDateString()}`, group: t('Invoices'), icon: FileText, run: () => navTo(`/sales?q=${encodeURIComponent(x.number)}`) })),
        ...((w.data ?? []) as { id: string; number: string; reference: string | null }[]).map((x) => ({ id: `w-${x.id}`, label: x.number, hint: x.reference ?? '', group: t('Orders'), icon: FileText, run: () => navTo(`/orders?q=${encodeURIComponent(x.number)}`) })),
      ])
    }, 180)
    return () => clearTimeout(id)
  }, [q]) // eslint-disable-line react-hooks/exhaustive-deps

  const n = norm(q)
  const shown = useMemo(() => [...fixed.filter((c) => !n || norm(c.label).includes(n) || norm(c.keys ?? '').includes(n) || norm(c.hint ?? '').includes(n)), ...found].slice(0, 40), [fixed, found, n])
  useEffect(() => { setSel(0) }, [q])
  useEffect(() => { input.current?.focus() }, [])
  useEffect(() => { list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' }) }, [sel])

  function key(e: React.KeyboardEvent) {
    if (e.key === 'ArrowDown') { e.preventDefault(); setSel((x) => Math.min(x + 1, shown.length - 1)) }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setSel((x) => Math.max(x - 1, 0)) }
    else if (e.key === 'Enter') { e.preventDefault(); shown[sel]?.run() }
    else if (e.key === 'Escape') { e.preventDefault(); onClose() }
  }
  let lastGroup = ''
  return (
    <div className="modal-back palette-back" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="palette" role="dialog" aria-modal="true" aria-label={t('Search and commands')}>
        <label className="palette-input"><Search size={18} aria-hidden="true" />
          <input ref={input} id="palette-q" role="combobox" aria-expanded="true" aria-controls="palette-list" aria-activedescendant={shown[sel] ? `cmd-${shown[sel].id}` : undefined}
            placeholder={t('Type a screen, action, customer, product or invoice number…')} value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={key} />
          <kbd>Esc</kbd></label>
        <ul id="palette-list" ref={list} role="listbox" className="palette-list">
          {shown.length === 0 && <li className="muted palette-empty">{t('Nothing found')}</li>}
          {shown.map((c, i) => {
            const head = c.group !== lastGroup ? c.group : null; lastGroup = c.group
            return (
              <li key={c.id} role="presentation">
                {head && <span className="palette-group">{head}</span>}
                <button id={`cmd-${c.id}`} role="option" aria-selected={i === sel} className={i === sel ? 'on' : ''} onMouseEnter={() => setSel(i)} onClick={() => c.run()}>
                  <c.icon size={16} aria-hidden="true" /><span className="palette-label">{c.label}</span>{c.hint && <small>{c.hint}</small>}
                  {i === sel ? <CornerDownLeft size={14} aria-hidden="true" className="flip-rtl" /> : <ArrowRight size={14} aria-hidden="true" className="flip-rtl dim" />}
                </button>
              </li>)
          })}
        </ul>
        <footer className="palette-foot"><span><kbd>↑</kbd><kbd>↓</kbd> {t('move')}</span><span><kbd>Enter</kbd> {t('open')}</span><span><kbd>Ctrl K</kbd> {t('anywhere')}</span><span><kbd>Ctrl B</kbd> {t('menu')}</span></footer>
      </div>
    </div>
  )
}

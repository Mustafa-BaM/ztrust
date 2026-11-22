import { FileText, Languages, LogOut, PanelLeftClose, PanelLeftOpen, Search } from 'lucide-react'
import { useEffect, useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { configureHub, hubSettings, useHub } from '../lib/hub'
import { useT } from '../lib/i18n'
import { NAV_GROUPS, useNav } from '../lib/nav'
import { flushOutbox, useOnline, useOutboxCount } from '../lib/offline'
import { usePrefs } from '../lib/prefs'
import { useSession } from '../lib/session'
import { CommandPalette } from './CommandPalette'
import { ThemePicker } from './ThemePicker'
import { Logo } from './ui'

/** Sidebar (open with names and groups, or a slim icon rail) + slim top bar with search (Ctrl K) and theme. */
export default function Layout() {
  const { t, lang, setLang } = useT()
  const s = useSession()
  const loc = useLocation()
  const nav = useNav()
  const { prefs, set } = usePrefs()
  const browserOnline = useOnline()
  const hubState = useHub()
  // behind a hub, "online" means the cloud is reachable, not just the shop Wi-Fi
  const online = hubState.status === 'connected' ? Boolean(hubState.cloudOnline) && browserOnline : browserOnline
  const queued = useOutboxCount()
  const [palette, setPalette] = useState(false)
  const [wide, setWide] = useState(() => matchMedia('(min-width: 1180px)').matches)
  useEffect(() => { const m = matchMedia('(min-width: 1180px)'); const f = () => setWide(m.matches); m.addEventListener('change', f); return () => m.removeEventListener('change', f) }, [])
  // open by default on wide screens; the till keeps the full width unless the user opened the sidebar there
  const open = (prefs.sidebar ?? (wide ? 'open' : 'closed')) === 'open'
  const trialDays = s.tenant ? Math.ceil((new Date(s.tenant.trial_ends_at).getTime() - Date.now()) / 86_400_000) : 0
  const current = nav.find((n) => loc.pathname.startsWith(n.to))
  const initials = (s.member?.display_name || '?').split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase()

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); setPalette(true) }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'b') { e.preventDefault(); set({ sidebar: open ? 'closed' : 'open' }) }
    }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [open, set])

  const groups = (Object.keys(NAV_GROUPS) as (keyof typeof NAV_GROUPS)[]).map((g) => ({ g, items: nav.filter((n) => n.group === g) })).filter((x) => x.items.length)
  return (
    <div className={`shell ${open ? 'side-open' : 'side-closed'}`}>
      <aside className="side" aria-label={t('Main menu')}>
        <div className="rail-logo" title="Z Trust"><Logo size={open ? 36 : 40} tile />{open && <span className="side-brand">Z Trust</span>}</div>
        <nav>
          {groups.map(({ g, items }) => (
            <div key={g} className="nav-group">
              {open && <span className="nav-group-title">{t(NAV_GROUPS[g])}</span>}
              {items.map((n) => (
                <NavLink key={n.to} to={n.to} title={t(n.label)}>
                  <n.icon size={open ? 19 : 21} strokeWidth={1.8} aria-hidden="true" /><span>{t(n.label)}</span>
                </NavLink>))}
            </div>))}
        </nav>
        <div className="rail-foot">
          <button className="rail-btn side-toggle" onClick={() => set({ sidebar: open ? 'closed' : 'open' })} title={`${t(open ? 'Collapse menu' : 'Expand menu')} (Ctrl B)`} aria-label={t(open ? 'Collapse menu' : 'Expand menu')} aria-expanded={open}>
            {open ? <PanelLeftClose size={19} className="flip-rtl" aria-hidden="true" /> : <PanelLeftOpen size={19} className="flip-rtl" aria-hidden="true" />}<span>{t(open ? 'Collapse' : 'Expand')}</span>
          </button>
          <button className="rail-btn" onClick={() => setLang(lang === 'ar' ? 'en' : 'ar')} title={lang === 'ar' ? 'English' : 'العربية'} aria-label={lang === 'ar' ? 'English' : 'العربية'}>
            <Languages size={19} strokeWidth={1.8} aria-hidden="true" /><span>{lang === 'ar' ? 'English' : 'العربية'}</span>
          </button>
          <button className="rail-btn" onClick={() => void s.signOut()} title={t('Sign out')}><LogOut size={19} strokeWidth={1.8} className="flip-rtl" aria-hidden="true" /><span>{t('Sign out')}</span></button>
          <div className="me"><div className="avatar" title={`${s.member?.display_name} · ${s.roleName(s.role, lang)}`}>{initials}</div>
            {open && <span className="me-txt"><b>{s.member?.display_name}</b><small>{s.roleName(s.role, lang)}</small></span>}</div>
        </div>
      </aside>
      <div className="main">
        <header className="topbar">
          <div className="tb-title">
            <span className="tb-biz">{lang === 'ar' && s.tenant?.name_ar ? s.tenant.name_ar : s.tenant?.name}</span>
            <span className="tb-sep">/</span>
            <h1 className="tb-page">{current ? t(current.label) : ''}</h1>
          </div>
          <button className="tb-search" onClick={() => setPalette(true)} aria-label={t('Search and commands')}>
            <Search size={16} aria-hidden="true" /><span>{t('Search screens, customers, invoices…')}</span><kbd>Ctrl K</kbd>
          </button>
          <div className="tb-right">
            {s.branches.length > 1 ? (
              <select id="branch-select" className="tb-select" aria-label={t('Branch')} value={s.branch?.id ?? ''} onChange={(e) => s.selectBranch(e.target.value)}>
                {s.branches.map((b) => <option key={b.id} value={b.id}>{lang === 'ar' && b.name_ar ? b.name_ar : b.name}</option>)}
              </select>
            ) : <span className="tb-chip"><FileText size={14} aria-hidden="true" />{lang === 'ar' && s.branch?.name_ar ? s.branch.name_ar : s.branch?.name}</span>}
            {s.tenant?.plan === 'trial' && trialDays >= 0 && <span className="tb-chip amber">{t('Trial: {n} days left', { n: trialDays })}</span>}
            <button className={`status ${online ? 'ok' : 'off'}`} onClick={() => void flushOutbox()} title={t('Sync now')}>
              <i />{online ? t('Online') : t('Offline')}{queued > 0 && <em>{t('{n} waiting to sync', { n: queued })}</em>}
            </button>
            <ThemePicker />
          </div>
        </header>
        <HubPairPrompt />
        <main className="content"><Outlet /></main>
      </div>
      {palette && <CommandPalette nav={nav} onClose={() => setPalette(false)} />}
    </div>
  )
}

/** Any device opened from a branch hub asks once for the hub's pairing code. */
function HubPairPrompt() {
  const { t } = useT()
  const hub = useHub()
  const [code, setCode] = useState('')
  if (!(hub.status === 'error' && hub.error === 'pairing_code')) return null
  return (
    <form className="pair-bar" onSubmit={(e) => { e.preventDefault(); configureHub(hubSettings().url, code) }}>
      <span>{t('This device is on the branch hub network. Enter the pairing code shown by the hub:')}</span>
      <input id="pair-code" inputMode="numeric" maxLength={6} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} />
      <button className="primary small" disabled={code.length !== 6}>{t('Pair')}</button>
    </form>
  )
}

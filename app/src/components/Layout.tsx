import { BarChart3, BookOpenCheck, Boxes, ChefHat, Clock3, FileText, Languages, LayoutDashboard, LogOut, Package, Receipt, Settings, ShoppingBag, Truck, Users, type LucideIcon } from 'lucide-react'
import { useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { configureHub, hubSettings, useHub } from '../lib/hub'
import { useT } from '../lib/i18n'
import { flushOutbox, useOnline, useOutboxCount } from '../lib/offline'
import { useSession } from '../lib/session'
import { Logo } from './ui'

const TITLES: Record<string, string> = {
  '/pos': 'Sell', '/dashboard': 'Dashboard', '/sales': 'Sales', '/kds': 'Kitchen', '/shift': 'Shift', '/products': 'Products',
  '/purchasing': 'Purchasing', '/inventory': 'Inventory', '/customers': 'Customers', '/reports': 'Reports', '/accounting': 'Accounting', '/settings': 'Settings',
}

/** Dark icon rail + slim top bar: the POS keeps almost the whole screen. */
export default function Layout() {
  const { t, lang, setLang } = useT()
  const s = useSession()
  const loc = useLocation()
  const browserOnline = useOnline()
  const hubState = useHub()
  // behind a hub, "online" means the cloud is reachable, not just the shop Wi-Fi
  const online = hubState.status === 'connected' ? Boolean(hubState.cloudOnline) && browserOnline : browserOnline
  const queued = useOutboxCount()
  const trialDays = s.tenant ? Math.ceil((new Date(s.tenant.trial_ends_at).getTime() - Date.now()) / 86_400_000) : 0
  const any = (...p: string[]) => p.some((x) => s.can(x))

  const nav: { to: string; label: string; icon: LucideIcon; show: boolean }[] = [
    { to: '/pos', label: 'Sell', icon: ShoppingBag, show: s.can('sale.create') },
    { to: '/dashboard', label: 'Dashboard', icon: LayoutDashboard, show: any('sale.create', 'reports.all', 'inventory.view', 'finance.view') },
    { to: '/sales', label: 'Sales', icon: Receipt, show: any('sale.create', 'reports.all') },
    { to: '/kds', label: 'Kitchen', icon: ChefHat, show: s.can('kds.view') },
    { to: '/shift', label: 'Shift', icon: Clock3, show: s.can('sale.create') },
    { to: '/products', label: 'Products', icon: Package, show: any('catalog.manage', 'inventory.view', 'sale.create') },
    { to: '/inventory', label: 'Inventory', icon: Boxes, show: any('inventory.view', 'inventory.adjust', 'catalog.manage') },
    { to: '/purchasing', label: 'Purchasing', icon: Truck, show: any('suppliers.manage', 'purchase.create', 'purchase.approve', 'inventory.receive') },
    { to: '/customers', label: 'Customers', icon: Users, show: any('sale.create', 'customers.manage') },
    { to: '/accounting', label: 'Accounting', icon: BookOpenCheck, show: any('finance.view', 'finance.journal', 'expenses.create', 'payables.pay') },
    { to: '/reports', label: 'Reports', icon: BarChart3, show: s.can('reports.all') },
    { to: '/settings', label: 'Settings', icon: Settings, show: s.role === 'owner' || any('staff.manage', 'settings.manage') },
  ]
  const title = TITLES[loc.pathname] ?? ''
  const initials = (s.member?.display_name || '?').split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase()

  return (
    <div className="shell">
      <aside className="side" aria-label={t('Main menu')}>
        <div className="rail-logo" title="Z Trust"><Logo size={40} tile /></div>
        <nav>
          {nav.filter((n) => n.show).map((n) => (
            <NavLink key={n.to} to={n.to} title={t(n.label)}>
              <n.icon size={21} strokeWidth={1.8} aria-hidden="true" /><span>{t(n.label)}</span>
            </NavLink>
          ))}
        </nav>
        <div className="rail-foot">
          <button className="rail-btn" onClick={() => setLang(lang === 'ar' ? 'en' : 'ar')} title={lang === 'ar' ? 'English' : 'العربية'} aria-label={lang === 'ar' ? 'English' : 'العربية'}>
            <Languages size={19} strokeWidth={1.8} aria-hidden="true" /><span>{lang === 'ar' ? 'EN' : 'ع'}</span>
          </button>
          <button className="rail-btn" onClick={() => void s.signOut()} title={t('Sign out')}><LogOut size={19} strokeWidth={1.8} aria-hidden="true" /><span>{t('Sign out')}</span></button>
          <div className="avatar" title={`${s.member?.display_name} · ${s.roleName(s.role, lang)}`}>{initials}</div>
        </div>
      </aside>
      <div className="main">
        <header className="topbar">
          <div className="tb-title">
            <span className="tb-biz">{lang === 'ar' && s.tenant?.name_ar ? s.tenant.name_ar : s.tenant?.name}</span>
            <span className="tb-sep">/</span>
            <h1 className="tb-page">{t(title)}</h1>
          </div>
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
            <span className="tb-user">{s.member?.display_name} · {s.roleName(s.role, lang)}</span>
          </div>
        </header>
        <HubPairPrompt />
        <main className="content"><Outlet /></main>
      </div>
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

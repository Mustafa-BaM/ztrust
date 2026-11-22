import { BarChart3, Bike, BookOpenCheck, Boxes, CalendarClock, CalendarDays, ChefHat, ClipboardList, Clock3, Fingerprint, LayoutDashboard, Package, Receipt, Settings, ShoppingBag, Tag, Truck, Users, type LucideIcon } from 'lucide-react'
import { useSession } from './session'

export interface NavItem { to: string; label: string; icon: LucideIcon; group: 'sell' | 'stock' | 'insight' | 'admin'; keys?: string }
export const NAV_GROUPS: Record<NavItem['group'], string> = { sell: 'Sell & serve', stock: 'Catalogue & stock', insight: 'Insight & finance', admin: 'Team & settings' }

/** The screens this user may open, for the sidebar and the command palette. */
export function useNav(): NavItem[] {
  const s = useSession()
  const any = (...p: string[]) => p.some((x) => s.can(x))
  const isDriver = Boolean((s.member as { is_driver?: boolean } | null)?.is_driver)
  const all: (NavItem & { show: boolean })[] = [
    { to: '/pos', label: 'Sell', icon: ShoppingBag, group: 'sell', keys: 'pos till cashier بيع كاشير', show: s.can('sale.create') },
    { to: '/shift', label: 'Shift', icon: Clock3, group: 'sell', keys: 'drawer cash وردية', show: s.can('sale.create') },
    { to: '/sales', label: 'Sales', icon: Receipt, group: 'sell', keys: 'invoices refunds فواتير مبيعات', show: any('sale.create', 'reports.all') },
    { to: '/customers', label: 'Customers', icon: Users, group: 'sell', keys: 'clients عملاء', show: any('sale.create', 'customers.manage') },
    { to: '/calendar', label: 'Calendar', icon: CalendarDays, group: 'sell', keys: 'appointments booking مواعيد', show: s.has('appointments') && s.can('sale.create') },
    { to: '/reservations', label: 'Reservations', icon: CalendarClock, group: 'sell', keys: 'tables waitlist حجوزات', show: s.has('reservations') && s.can('sale.create') },
    { to: '/orders', label: 'Orders', icon: ClipboardList, group: 'sell', keys: 'job cards preorders تذاكر طلبات', show: (s.has('job_cards') || s.has('preorders')) && s.can('sale.create') },
    { to: '/deliveries', label: 'Deliveries', icon: Bike, group: 'sell', keys: 'drivers توصيل', show: s.has('own_delivery') && (s.can('sale.create') || isDriver) },
    { to: '/kds', label: 'Kitchen', icon: ChefHat, group: 'sell', keys: 'kds مطبخ', show: s.can('kds.view') && s.has('kitchen') },
    { to: '/products', label: 'Products', icon: Package, group: 'stock', keys: 'items catalogue منتجات أصناف', show: any('catalog.manage', 'inventory.view', 'sale.create') },
    { to: '/inventory', label: 'Inventory', icon: Boxes, group: 'stock', keys: 'stock count expiry مخزون جرد', show: any('inventory.view', 'inventory.adjust', 'catalog.manage') },
    { to: '/purchasing', label: 'Purchasing', icon: Truck, group: 'stock', keys: 'suppliers po مشتريات موردين', show: s.has('purchasing') && any('suppliers.manage', 'purchase.create', 'purchase.approve', 'inventory.receive') },
    { to: '/promotions', label: 'Promotions', icon: Tag, group: 'stock', keys: 'offers coupons عروض', show: s.has('promotions') && s.can('catalog.manage') },
    { to: '/dashboard', label: 'Dashboard', icon: LayoutDashboard, group: 'insight', keys: 'kpi لوحة', show: any('sale.create', 'reports.all', 'inventory.view', 'finance.view') },
    { to: '/reports', label: 'Reports', icon: BarChart3, group: 'insight', keys: 'تقارير', show: s.can('reports.all') },
    { to: '/accounting', label: 'Accounting', icon: BookOpenCheck, group: 'insight', keys: 'ledger journal محاسبة قيود', show: any('finance.view', 'finance.journal', 'expenses.create', 'payables.pay') },
    { to: '/attendance', label: 'Attendance', icon: Fingerprint, group: 'admin', keys: 'clock حضور', show: s.has('attendance') },
    { to: '/settings', label: 'Settings', icon: Settings, group: 'admin', keys: 'إعدادات', show: s.role === 'owner' || any('staff.manage', 'settings.manage') },
  ]
  return all.filter((x) => x.show)
}

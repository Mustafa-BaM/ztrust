import { Navigate, Route, Routes } from 'react-router-dom'
import Layout from './components/Layout'
import { useT } from './lib/i18n'
import { useSession } from './lib/session'
import Accounting from './pages/Accounting'
import Attendance from './pages/Attendance'
import Book from './pages/Book'
import Deliveries from './pages/Deliveries'
import Display from './pages/Display'
import Order from './pages/Order'
import Reservations from './pages/Reservations'
import Calendar from './pages/Calendar'
import Orders from './pages/Orders'
import Promotions from './pages/Promotions'
import Customers from './pages/Customers'
import Inventory from './pages/Inventory'
import Kds from './pages/Kds'
import Purchasing from './pages/Purchasing'
import Dashboard from './pages/Dashboard'
import Login from './pages/Login'
import Onboarding from './pages/Onboarding'
import PayLink from './pages/PayLink'
import Pos from './pages/Pos'
import Products from './pages/Products'
import Reports from './pages/Reports'
import Sales from './pages/Sales'
import SalesDocs from './pages/SalesDocs'
import Hr from './pages/Hr'
import Settings from './pages/Settings'
import Shift from './pages/Shift'

function Guarded() {
  const s = useSession()
  const { t } = useT()
  if (s.loading) return <div className="splash">{t('Loading…')}</div>
  if (!s.session) return <Login />
  if (!s.tenant) return <Onboarding />
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route path="/pos" element={<Pos />} />
        <Route path="/dashboard" element={<Dashboard />} />
        <Route path="/sales" element={<Sales />} />
        <Route path="/quotes" element={<SalesDocs />} />
        <Route path="/hr" element={<Hr />} />
        <Route path="/shift" element={<Shift />} />
        <Route path="/kds" element={<Kds />} />
        <Route path="/calendar" element={<Calendar />} />
        <Route path="/reservations" element={<Reservations />} />
        <Route path="/deliveries" element={<Deliveries />} />
        <Route path="/attendance" element={<Attendance />} />
        <Route path="/orders" element={<Orders />} />
        <Route path="/promotions" element={<Promotions />} />
        <Route path="/purchasing" element={<Purchasing />} />
        <Route path="/products" element={<Products />} />
        <Route path="/inventory" element={<Inventory />} />
        <Route path="/customers" element={<Customers />} />
        <Route path="/reports" element={<Reports />} />
        <Route path="/accounting" element={<Accounting />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="*" element={<Navigate to={s.can('sale.create') ? '/pos' : s.can('kds.view') && s.has('kitchen') ? '/kds' : s.has('purchasing') && (s.can('purchase.create') || s.can('inventory.receive')) ? '/purchasing' : s.can('finance.view') || s.can('expenses.create') ? '/accounting' : '/dashboard'} replace />} />
      </Route>
    </Routes>
  )
}

export default function App() {
  return (
    <Routes>
      <Route path="/pay/:token" element={<PayLink />} />
      <Route path="/book/:slug" element={<Book />} />
      <Route path="/order/:slug" element={<Order />} />
      <Route path="/display" element={<Display />} />
      <Route path="*" element={<Guarded />} />
    </Routes>
  )
}

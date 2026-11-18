import { supabase } from './supabase'

export interface Range { from: string; to: string; branchId: string | null }

export interface DailyRow { day: string; branch_id: string; invoices: number; credit_notes: number; gross_sales: number; refunds: number; net_sales: number; tax: number; discounts: number }
export interface TenderRow { day: string; tender: string; status: string; amount: number; count: number }
export interface ItemRow { item_id: string | null; name: string; qty: number; total: number; net: number; cost: number }
export interface HourRow { hour: number; net_sales: number; docs: number }
export interface CashierRow { created_by: string; cashier: string; invoices: number; sales: number; discounts: number; refunds: number }
export interface ExceptionRow { id: number; created_at: string; action: string; amount: number | null; reason: string | null; user_name: string | null; approver_name: string | null; meta: Record<string, unknown> }
export interface TbRow { code: string; name_en: string; name_ar: string; type: string; debit: number; credit: number; balance: number }

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function scope(q: any, r: Range, dayCol = 'day') {
  q = q.gte(dayCol, r.from).lte(dayCol, r.to)
  return r.branchId ? q.eq('branch_id', r.branchId) : q
}

/** Sums rows by key (views are per branch per day; dashboards show the total of the range). */
function rollup<T extends object>(rows: T[], key: (r: T) => string, sumKeys: (keyof T)[]): T[] {
  const m = new Map<string, T>()
  for (const r of rows) {
    const k = key(r); const cur = m.get(k)
    if (!cur) { m.set(k, { ...r }); continue }
    const c = cur as Record<string, unknown>, x = r as Record<string, unknown>
    for (const s of sumKeys) c[s as string] = Number(c[s as string] ?? 0) + Number(x[s as string] ?? 0)
  }
  return [...m.values()]
}

export async function daily(r: Range) {
  const { data } = await scope(supabase.from('v_daily_sales').select('*'), r).order('day')
  return rollup((data ?? []) as DailyRow[], (x) => x.day, ['invoices', 'credit_notes', 'gross_sales', 'refunds', 'net_sales', 'tax', 'discounts'])
}
export async function tenders(r: Range) {
  const { data } = await scope(supabase.from('v_tender_daily').select('*'), r)
  return rollup((data ?? []) as TenderRow[], (x) => `${x.tender}:${x.status}`, ['amount', 'count'])
}
export async function itemSales(r: Range) {
  const { data } = await scope(supabase.from('v_item_sales').select('*'), r)
  return rollup((data ?? []) as ItemRow[], (x) => x.item_id ?? x.name, ['qty', 'total', 'net', 'cost']).sort((a, b) => b.total - a.total)
}
export async function hourly(r: Range) {
  const { data } = await scope(supabase.from('v_hourly_sales').select('*'), r)
  return rollup((data ?? []) as HourRow[], (x) => String(x.hour), ['net_sales', 'docs']).sort((a, b) => a.hour - b.hour)
}
export async function cashiers(r: Range) {
  const { data } = await scope(supabase.from('v_cashier_sales').select('*'), r)
  return rollup((data ?? []) as CashierRow[], (x) => x.created_by, ['invoices', 'sales', 'discounts', 'refunds']).sort((a, b) => b.sales - a.sales)
}
export async function exceptions(r: Range) {
  let q = supabase.from('v_exceptions').select('*').gte('created_at', `${r.from}T00:00:00`).lte('created_at', `${r.to}T23:59:59.999`)
  if (r.branchId) q = q.eq('branch_id', r.branchId)
  const { data } = await q.order('created_at', { ascending: false }).limit(200)
  return (data ?? []) as ExceptionRow[]
}
export async function trialBalance(tenantId: string) {
  const { data } = await supabase.from('v_trial_balance').select('*').eq('tenant_id', tenantId).order('code')
  return (data ?? []) as TbRow[]
}

/** Builds a CSV file (UTF-8 with BOM so Excel shows Arabic correctly). */
export function toCsv(rows: Record<string, unknown>[]): string {
  if (!rows.length) return ''
  const cols = Object.keys(rows[0])
  const esc = (v: unknown) => { const s = v == null ? '' : String(v); return /[",\n;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s }
  return '﻿' + [cols.join(','), ...rows.map((r) => cols.map((c) => esc(r[c])).join(','))].join('\n')
}
export function downloadCsv(name: string, rows: Record<string, unknown>[]) {
  const url = URL.createObjectURL(new Blob([toCsv(rows)], { type: 'text/csv;charset=utf-8' }))
  const a = document.createElement('a'); a.href = url; a.download = name; a.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export function rangeFor(preset: 'today' | '7d' | '30d' | 'month'): { from: string; to: string } {
  const now = new Date(); const iso = (d: Date) => d.toISOString().slice(0, 10)
  const back = (n: number) => { const d = new Date(now); d.setDate(d.getDate() - n); return d }
  if (preset === 'today') return { from: iso(now), to: iso(now) }
  if (preset === '7d') return { from: iso(back(6)), to: iso(now) }
  if (preset === '30d') return { from: iso(back(29)), to: iso(now) }
  return { from: iso(new Date(now.getFullYear(), now.getMonth(), 1)), to: iso(now) }
}

export const ACTION_LABEL: Record<string, string> = {
  'sale.discount': 'Discount', 'sale.refund': 'Refund', 'sale.cancel': 'Invoice cancelled', 'shift.variance': 'Cash over/short',
  'drawer.no_sale': 'Drawer opened, no sale', 'inventory.adjust': 'Stock adjustment',
  'purchase.approve': 'Purchase approved', 'purchase.cancel': 'Purchase cancelled',
}

/** Fills empty hours so the chart keeps a readable time axis (at least 8 hours wide). */
export function fillHours(rows: HourRow[]): HourRow[] {
  if (!rows.length) return rows
  let lo = Math.min(...rows.map((r) => r.hour)), hi = Math.max(...rows.map((r) => r.hour))
  while (hi - lo < 7) { if (lo > 0) lo--; if (hi - lo < 7 && hi < 23) hi++; if (lo === 0 && hi === 23) break }
  const m = new Map(rows.map((r) => [r.hour, r]))
  return Array.from({ length: hi - lo + 1 }, (_, i) => m.get(lo + i) ?? { hour: lo + i, net_sales: 0, docs: 0 })
}

export interface HourDayRow { day: string; hour: number; net_sales: number; docs: number }
export async function hourlyByDay(r: Range) {
  const { data } = await scope(supabase.from('v_hourly_sales').select('day, hour, net_sales, docs'), r)
  return (data ?? []) as HourDayRow[]
}
export function previousRange(from: string, to: string) {
  const f = new Date(from + 'T00:00:00Z'), t = new Date(to + 'T00:00:00Z')
  const days = Math.round((t.getTime() - f.getTime()) / 86_400_000) + 1
  const pt = new Date(f.getTime() - 86_400_000), pf = new Date(f.getTime() - days * 86_400_000)
  return { from: pf.toISOString().slice(0, 10), to: pt.toISOString().slice(0, 10), days }
}
export function eachDay(from: string, to: string): string[] {
  const out: string[] = []
  for (let d = new Date(from + 'T00:00:00Z'); d <= new Date(to + 'T00:00:00Z'); d = new Date(d.getTime() + 86_400_000)) out.push(d.toISOString().slice(0, 10))
  return out
}

export interface KitchenRow { id: string; station: string; alert_minutes: number; order_ref: string; order_type: string; created_at: string; day: string; hour: number; wait_s: number | null; prep_s: number | null; total_s: number | null; pickup_s: number | null; late: boolean | null; status: string; item_qty: number }
export async function kitchenTimes(r: Range) {
  const { data } = await scope(supabase.from('v_kitchen_times').select('*'), r).neq('status', 'cancelled').order('created_at', { ascending: false }).limit(5000)
  return (data ?? []) as KitchenRow[]
}
export async function channelSales(r: Range) {
  const { data } = await scope(supabase.from('v_channel_sales').select('*'), r)
  return rollup((data ?? []) as { channel: string; platform: string | null; orders: number; net_sales: number }[], (x) => x.channel, ['orders', 'net_sales']).sort((a, b) => b.net_sales - a.net_sales)
}
export const mmss = (sec: number | null | undefined) => (sec == null ? '—' : `${Math.floor(sec / 60)}:${String(Math.round(sec % 60)).padStart(2, '0')}`)
const avg = (xs: (number | null)[]) => { const v = xs.filter((x): x is number => x != null); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null }
/** Kitchen performance summary per station (and "All"). */
export function kitchenSummary(rows: KitchenRow[]) {
  const groups = new Map<string, KitchenRow[]>([['*', rows]])
  for (const r of rows) groups.set(r.station, [...(groups.get(r.station) ?? []), r])
  return [...groups.entries()].map(([k, list]) => {
    const done = list.filter((x) => x.total_s != null)
    return { station: k, tickets: list.length, done: done.length, wait: avg(list.map((x) => x.wait_s)), prep: avg(list.map((x) => x.prep_s)), total: avg(done.map((x) => x.total_s)),
      pickup: avg(list.map((x) => x.pickup_s)), lateCount: done.filter((x) => x.late).length, onTime: done.length ? Math.round((done.filter((x) => !x.late).length / done.length) * 100) : null,
      slowest: done.reduce<KitchenRow | null>((a, b) => (!a || (b.total_s ?? 0) > (a.total_s ?? 0) ? b : a), null) }
  })
}

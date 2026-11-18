import type { CartLine, Tenant } from './types'

/** Formats minor units (fils, halalas, cents) as money in the tenant's currency. Western digits by default. */
export function fmt(minor: number, t: Pick<Tenant, 'currency' | 'currency_decimals'>, lang = 'en'): string {
  const d = t.currency_decimals
  return new Intl.NumberFormat(lang === 'ar' ? 'ar-u-nu-latn' : 'en', {
    style: 'currency', currency: t.currency, minimumFractionDigits: d, maximumFractionDigits: d,
  }).format(minor / 10 ** d)
}

export function num(minor: number, decimals: number): string {
  return (minor / 10 ** decimals).toFixed(decimals)
}

/** Parses "12.5" into minor units. Returns NaN for invalid input. */
export function toMinor(input: string, decimals: number): number {
  const clean = input.replace(/[٠-٩]/g, (c) => String('٠١٢٣٤٥٦٧٨٩'.indexOf(c))).replace(/[,\s]/g, '').replace('٫', '.')
  if (clean === '' || !/^-?\d*\.?\d*$/.test(clean)) return NaN
  return Math.round(parseFloat(clean) * 10 ** decimals)
}

/** Postgres round() on numeric rounds half away from zero; mirror it so offline totals match the server exactly. */
const pgRound = (x: number) => Math.sign(x) * Math.round(Math.abs(x))

export interface LineCalc { gross: number; net: number; tax: number; total: number }

/** Same formula as complete_sale() in the database. */
export function calcLine(l: CartLine, pricesIncludeTax: boolean): LineCalc {
  const gross = pgRound(l.qty * l.unit_price) - l.discount
  if (pricesIncludeTax) {
    const tax = pgRound((gross * l.tax_rate) / (100 + l.tax_rate))
    return { gross, net: gross - tax, tax, total: gross }
  }
  const tax = pgRound((gross * l.tax_rate) / 100)
  return { gross, net: gross, tax, total: gross + tax }
}

export function calcCart(lines: CartLine[], pricesIncludeTax: boolean) {
  let net = 0, tax = 0, total = 0, list = 0, discount = 0
  for (const l of lines) {
    const c = calcLine(l, pricesIncludeTax)
    net += c.net; tax += c.tax; total += c.total
    list += pgRound(l.qty * l.list_price)
    discount += l.discount + Math.max(pgRound(l.qty * (l.list_price - l.unit_price)), 0)
  }
  const discountPct = list > 0 ? Math.round((discount * 10000) / list) / 100 : 0
  return { net, tax, total, list, discount, discountPct }
}

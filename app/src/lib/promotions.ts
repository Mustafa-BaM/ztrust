import { pgRound } from './money'
import type { CartLine, Item, Promotion } from './types'

/**
 * The promotion engine, rule for rule the same as promo_allowance() in the database, so totals match offline too.
 * Each line gets the single best promotion (no stacking on one line). The server caps whatever the POS claims.
 */
export interface PromoLine { idx: number; item_id: string | null; qty: number; gross: number }
export interface PromoHit { idx: number; promo_id: string; discount: number }

function activeAt(p: Promotion, at: Date, coupon: string | null) {
  const day = at.toLocaleDateString('en-CA'), time = at.toTimeString().slice(0, 8), dow = ((at.getDay() + 6) % 7) + 1
  return p.is_active && (!p.starts_on || day >= p.starts_on) && (!p.ends_on || day <= p.ends_on)
    && (!p.weekdays || p.weekdays.includes(dow)) && (!p.time_from || time >= p.time_from) && (!p.time_to || time < p.time_to)
    && (!p.coupon_code || p.coupon_code.toUpperCase() === (coupon ?? '').toUpperCase())
}

export function promoAllowance(promos: Promotion[], items: Item[], lines: PromoLine[], at = new Date(), coupon: string | null = null): PromoHit[] {
  const byId = new Map(items.map((i) => [i.id, i]))
  const best = new Map<number, PromoHit>()
  for (const pr of promos) {
    if (!activeAt(pr, at, coupon)) continue
    const q = lines.filter((x) => {
      if (pr.kind === 'bundle' || (!pr.item_ids && !pr.category_ids)) return true
      const it = x.item_id ? byId.get(x.item_id) : undefined
      return (x.item_id && pr.item_ids?.includes(x.item_id)) || (it?.parent_id && pr.item_ids?.includes(it.parent_id)) || (it?.category_id && pr.category_ids?.includes(it.category_id))
    })
    if (!q.length) continue
    const qty = q.reduce((a, x) => a + x.qty, 0), sum = q.reduce((a, x) => a + x.gross, 0)
    if (pr.kind !== 'bundle' && qty < pr.min_qty) continue
    const d = new Map<number, number>()
    if (pr.kind === 'percent') {
      for (const x of q) d.set(x.idx, pgRound((x.gross * (pr.params.percent ?? 0)) / 100))
    } else if (pr.kind === 'amount') {
      if (sum <= 0 || sum < (pr.params.min_amount ?? 0)) continue
      const disc = Math.min(pr.params.amount ?? 0, sum); let given = 0
      const sorted = [...q].sort((a, b) => a.idx - b.idx)
      sorted.forEach((x, i) => { const share = i === sorted.length - 1 ? disc - given : pgRound((disc * x.gross) / sum); given += share; d.set(x.idx, share) })
    } else if (pr.kind === 'bxgy') {
      const units = q.flatMap((x) => Array.from({ length: Math.floor(x.qty) }, () => ({ idx: x.idx, unit: pgRound(x.gross / x.qty), key: x.gross / x.qty })))
        .sort((a, b) => b.key - a.key || a.idx - b.idx)
      const buy = pr.params.buy ?? 1, chunk = buy + (pr.params.get ?? 1)
      for (let i = 0; i < Math.floor(units.length / chunk) * chunk; i++) {
        if (i % chunk >= buy) { const u = units[i]; d.set(u.idx, (d.get(u.idx) ?? 0) + pgRound((u.unit * (pr.params.percent ?? 100)) / 100)) }
      }
    } else {
      const comps = pr.params.components ?? []
      let sets = Infinity, setValue = 0
      const avg = (id: string) => { const m = q.filter((x) => x.item_id === id); const n = m.reduce((a, x) => a + x.qty, 0); return { n, unit: n ? Math.round(m.reduce((a, x) => a + x.gross, 0) / n) : 0, idx: Math.min(...m.map((x) => x.idx)) } }
      for (const c of comps) { const a = avg(c.item_id); sets = Math.min(sets, Math.floor(a.n / c.qty)); setValue += pgRound(a.unit * c.qty) }
      if (!comps.length || !Number.isFinite(sets) || sets < 1 || setValue <= (pr.params.price ?? 0)) continue
      const disc = pgRound(sets * (setValue - (pr.params.price ?? 0))); let given = 0
      comps.forEach((c, i) => {
        const a = avg(c.item_id)
        const share = i === comps.length - 1 ? disc - given : pgRound((disc * a.unit * c.qty) / setValue)
        given += share; d.set(a.idx, (d.get(a.idx) ?? 0) + share)
      })
    }
    for (const [idx, v] of d) {
      if (v > 0 && v > (best.get(idx)?.discount ?? 0)) {
        const gross = lines.find((x) => x.idx === idx)?.gross ?? 0
        best.set(idx, { idx, promo_id: pr.id, discount: Math.min(v, gross) })
      }
    }
  }
  return [...best.values()].sort((a, b) => a.idx - b.idx)
}

/** Returns the cart with promo_discount filled in (package-session lines are left out). */
export function applyPromotions(lines: CartLine[], promos: Promotion[], items: Item[], coupon: string | null, at = new Date()): CartLine[] {
  if (!promos.length) return lines.map((l) => ({ ...l, promo_discount: 0, promo_name: undefined }))
  const input = lines.map((l, i) => ({ idx: i + 1, item_id: l.item_id, qty: l.qty, gross: pgRound(l.qty * l.unit_price) }))
  const hits = promoAllowance(promos, items, input.filter((_, i) => !lines[i].customer_package_id), at, coupon)
  return lines.map((l, i) => {
    const h = hits.find((x) => x.idx === i + 1)
    // a line with a manual discount keeps it; the promotion fills the rest up to the line value
    const room = Math.max(pgRound(l.qty * l.unit_price) - l.discount, 0)
    return { ...l, promo_discount: h ? Math.min(h.discount, room) : 0, promo_name: h ? promos.find((p) => p.id === h.promo_id)?.name : undefined }
  })
}

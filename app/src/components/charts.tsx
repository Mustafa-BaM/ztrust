import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'

/** Track an element's width so SVG charts draw at real pixel size (crisp 2px lines, 8px markers). */
function useWidth<T extends HTMLElement>(fallback = 600) {
  const ref = useRef<T>(null)
  const [w, setW] = useState(fallback)
  useEffect(() => {
    if (!ref.current) return
    const ro = new ResizeObserver(([e]) => setW(Math.max(120, Math.floor(e.contentRect.width))))
    ro.observe(ref.current)
    return () => ro.disconnect()
  }, [])
  return [ref, w] as const
}

function niceMax(v: number) {
  if (v <= 0) return 1
  const p = 10 ** Math.floor(Math.log10(v)); const n = v / p
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p
}

export function Sparkline({ values, height = 34 }: { values: number[]; height?: number }) {
  const [ref, w] = useWidth<HTMLDivElement>(120)
  if (values.length < 2) return <div ref={ref} className="spark" style={{ height }} />
  const max = Math.max(...values, 1), min = Math.min(...values, 0)
  const x = (i: number) => (i / (values.length - 1)) * (w - 6) + 3
  const y = (v: number) => height - 4 - ((v - min) / (max - min || 1)) * (height - 8)
  const d = values.map((v, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join('')
  return (
    <div ref={ref} className="spark" aria-hidden="true">
      <svg width={w} height={height}>
        <path d={`${d}L${x(values.length - 1)},${height}L${x(0)},${height}Z`} className="spark-area" />
        <path d={d} className="spark-line" />
        <circle cx={x(values.length - 1)} cy={y(values[values.length - 1])} r="3" className="spark-dot" />
      </svg>
    </div>
  )
}

export interface SeriesPoint { label: string; value: number; prev?: number }

/** One measure over time. Optional dashed comparison series; crosshair snaps to the nearest point. */
export function AreaChart({ points, format, axisFormat, height = 260, seriesName, prevName }: {
  points: SeriesPoint[]; format: (v: number) => string; axisFormat?: (v: number) => string; height?: number; seriesName: string; prevName?: string
}) {
  const [ref, w] = useWidth<HTMLDivElement>()
  const [hover, setHover] = useState<number | null>(null)
  const pad = { l: 64, r: 28, t: 14, b: 28 }
  const hasPrev = points.some((p) => p.prev != null)
  const max = niceMax(Math.max(1, ...points.map((p) => Math.max(p.value, p.prev ?? 0))))
  const iw = w - pad.l - pad.r, ih = height - pad.t - pad.b
  const x = (i: number) => pad.l + (points.length < 2 ? iw / 2 : (i / (points.length - 1)) * iw)
  const y = (v: number) => pad.t + ih - (v / max) * ih
  const line = (get: (p: SeriesPoint) => number | undefined) =>
    points.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(get(p) ?? 0).toFixed(1)}`).join('')
  const ticks = [0, max / 2, max]
  const every = Math.max(1, Math.ceil(points.length / Math.max(2, Math.floor(iw / 70))))

  function move(e: React.PointerEvent<SVGSVGElement>) {
    const r = e.currentTarget.getBoundingClientRect()
    const px = e.clientX - r.left
    const i = Math.round(((px - pad.l) / iw) * (points.length - 1))
    setHover(Math.min(points.length - 1, Math.max(0, i)))
  }
  const hp = hover != null ? points[hover] : null
  const flip = hover != null && x(hover) > w * 0.6

  return (
    <div ref={ref} className="chart">
      <svg width={w} height={height} onPointerMove={move} onPointerLeave={() => setHover(null)} role="img" aria-label={seriesName}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={pad.l} x2={w - pad.r} y1={y(t)} y2={y(t)} className="grid" />
            <text x={pad.l - 8} y={y(t) + 4} className="axis" textAnchor="end">{(axisFormat ?? format)(t)}</text>
          </g>
        ))}
        {points.map((p, i) => (i % every === 0 || i === points.length - 1) && (
          <text key={i} x={x(i)} y={height - 8} className="axis" textAnchor="middle">{p.label}</text>
        ))}
        <path d={`${line((p) => p.value)}L${x(points.length - 1)},${y(0)}L${x(0)},${y(0)}Z`} className="area-fill" />
        {hasPrev && <path d={line((p) => p.prev)} className="line-prev" />}
        <path d={line((p) => p.value)} className="line-main" />
        {points.length > 0 && <circle cx={x(points.length - 1)} cy={y(points[points.length - 1].value)} r="4.5" className="dot-main" />}
        {hp && hover != null && (
          <g>
            <line x1={x(hover)} x2={x(hover)} y1={pad.t} y2={pad.t + ih} className="crosshair" />
            {hasPrev && hp.prev != null && <circle cx={x(hover)} cy={y(hp.prev)} r="4" className="dot-prev" />}
            <circle cx={x(hover)} cy={y(hp.value)} r="5" className="dot-main" />
          </g>
        )}
      </svg>
      {hp && hover != null && (
        <div className="tip" style={{ left: flip ? undefined : x(hover) + 12, right: flip ? w - x(hover) + 12 : undefined, top: 8 }}>
          <div className="tip-head">{hp.label}</div>
          <div className="tip-row"><i className="key main" /><b>{format(hp.value)}</b><span>{seriesName}</span></div>
          {hasPrev && hp.prev != null && <div className="tip-row"><i className="key prev" /><b>{format(hp.prev)}</b><span>{prevName}</span></div>}
        </div>
      )}
    </div>
  )
}

export interface Slice { key: string; label: string; value: number }

/** Part-to-whole for a few categories (≤4 slots + Other). Legend always shows label and value. */
export function Donut({ items, format, center }: { items: Slice[]; format: (v: number) => string; center: ReactNode }) {
  const [hover, setHover] = useState<string | null>(null)
  const total = items.reduce((a, b) => a + Math.max(0, b.value), 0) || 1
  const R = 64, r = 44, C = 80
  let a0 = -Math.PI / 2
  const arcs = items.map((it, i) => {
    const frac = Math.max(0, it.value) / total
    const a1 = a0 + frac * Math.PI * 2
    const gap = items.length > 1 ? 0.025 : 0
    const s = a0 + gap / 2, e = Math.max(s, a1 - gap / 2)
    const large = e - s > Math.PI ? 1 : 0
    const p = (ang: number, rad: number) => `${C + rad * Math.cos(ang)},${C + rad * Math.sin(ang)}`
    const d = frac >= 0.999
      ? `M${C - R},${C}a${R},${R} 0 1,0 ${2 * R},0a${R},${R} 0 1,0 ${-2 * R},0M${C - r},${C}a${r},${r} 0 1,1 ${2 * r},0a${r},${r} 0 1,1 ${-2 * r},0`
      : `M${p(s, R)}A${R},${R} 0 ${large} 1 ${p(e, R)}L${p(e, r)}A${r},${r} 0 ${large} 0 ${p(s, r)}Z`
    a0 = a1
    return { ...it, d, slot: i + 1, frac }
  })
  return (
    <div className="donut">
      <svg width="160" height="160" viewBox="0 0 160 160" role="img" aria-label={items.map((i) => `${i.label} ${format(i.value)}`).join(', ')}>
        {arcs.map((a) => (
          <path key={a.key} d={a.d} fillRule="evenodd" className={`slice s${a.slot} ${hover && hover !== a.key ? 'dim' : ''}`}
                tabIndex={0} onPointerEnter={() => setHover(a.key)} onPointerLeave={() => setHover(null)} onFocus={() => setHover(a.key)} onBlur={() => setHover(null)} />
        ))}
      </svg>
      <div className="donut-center">{center}</div>
      <ul className="legend">
        {arcs.map((a) => (
          <li key={a.key} className={hover === a.key ? 'on' : ''} onPointerEnter={() => setHover(a.key)} onPointerLeave={() => setHover(null)}>
            <i className={`sw s${a.slot}`} /><span>{a.label}</span><b>{format(a.value)}</b><em>{Math.round(a.frac * 100)}%</em>
          </li>
        ))}
      </ul>
    </div>
  )
}

/** Ranked magnitudes: one hue, value labels at the bar end. */
export function HBars({ items, format, max: maxIn }: { items: { key: string; label: string; value: number; sub?: string }[]; format: (v: number) => string; max?: number }) {
  const max = maxIn ?? Math.max(1, ...items.map((i) => i.value))
  return (
    <ul className="hbars">
      {items.map((it) => (
        <li key={it.key} title={`${it.label}: ${format(it.value)}`}>
          <div className="hb-label"><span>{it.label}</span>{it.sub && <em>{it.sub}</em>}</div>
          <div className="hb-track"><i style={{ width: `${Math.max(1.5, (it.value / max) * 100)}%` }} /></div>
          <b>{format(it.value)}</b>
        </li>
      ))}
    </ul>
  )
}

/** Weekday × hour intensity (sequential, one hue). Each cell is its own hover target. */
export function Heatmap({ grid, format, dayLabels, hours }: { grid: number[][]; format: (v: number) => string; dayLabels: string[]; hours: number[] }) {
  const [tip, setTip] = useState<{ d: number; h: number } | null>(null)
  const max = Math.max(1, ...grid.flat())
  const step = (v: number) => (v <= 0 ? 0 : Math.min(5, Math.ceil((v / max) * 5)))
  const cols = useMemo(() => hours, [hours])
  return (
    <div className="heat" style={{ gridTemplateColumns: `auto repeat(${cols.length}, minmax(10px, 1fr))` }} onPointerLeave={() => setTip(null)}>
      <span />
      {cols.map((h) => <span key={h} className="heat-h">{h % 3 === 0 ? h : ''}</span>)}
      {dayLabels.map((dl, d) => (
        <div key={dl} className="heat-row" style={{ display: 'contents' }}>
          <span className="heat-d">{dl}</span>
          {cols.map((h) => (
            <i key={h} tabIndex={0} className={`cell q${step(grid[d][h])} ${tip && tip.d === d && tip.h === h ? 'on' : ''}`}
               onPointerEnter={() => setTip({ d, h })} onFocus={() => setTip({ d, h })} aria-label={`${dl} ${h}:00 ${format(grid[d][h])}`} />
          ))}
        </div>
      ))}
      <div className="heat-tip" aria-live="polite">
        {tip ? <><b>{format(grid[tip.d][tip.h])}</b> · {dayLabels[tip.d]} {String(tip.h).padStart(2, '0')}:00</> : ' '}
      </div>
    </div>
  )
}

export function Delta({ now, prev, invert = false }: { now: number; prev: number; invert?: boolean }) {
  if (!prev) return <span className="delta flat">—</span>
  const pct = ((now - prev) / Math.abs(prev)) * 100
  const up = pct >= 0
  const good = invert ? !up : up
  return <span className={`delta ${good ? 'good' : 'bad'}`}>{up ? '▲' : '▼'} {Math.abs(pct).toFixed(Math.abs(pct) < 10 ? 1 : 0)}%</span>
}

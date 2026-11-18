import { useEffect, useMemo, useState } from 'react'
import { useName, useT } from '../../lib/i18n'
import { fmt, num } from '../../lib/money'
import { useSession } from '../../lib/session'
import { supabase } from '../../lib/supabase'
import type { DiningTable, Item, ModifierGroup, ModifierOption, OpenOrder, Tenant } from '../../lib/types'
import { Modal } from '../ui'

/** Pick the size / colour of a variant group. */
export function VariantPicker({ template, items, stock, tenant, onPick, onClose }: {
  template: Item; items: Item[]; stock?: Record<string, number>; tenant: Tenant; onPick: (i: Item) => void; onClose: () => void
}) {
  const { t, lang } = useT()
  const nameOf = useName()
  const variants = items.filter((i) => i.parent_id === template.id && i.is_active)
  const attrs = [...new Set(variants.flatMap((v) => Object.keys(v.variant_attrs ?? {})))]
  const [sel, setSel] = useState<Record<string, string>>({})
  const match = variants.find((v) => attrs.every((a) => v.variant_attrs?.[a] === sel[a]))
  const valuesOf = (a: string) => [...new Set(variants.map((v) => v.variant_attrs?.[a]).filter(Boolean) as string[])]
  // a value is possible when some variant has it together with the values already chosen
  const possible = (a: string, val: string) => variants.some((v) => v.variant_attrs?.[a] === val && attrs.every((b) => b === a || !sel[b] || v.variant_attrs?.[b] === sel[b]))
  useEffect(() => { if (match) onPick(match) }, [match, onPick])
  return (
    <Modal title={nameOf(template)} onClose={onClose}>
      <div className="stack">
        {attrs.map((a) => (
          <div key={a} className="stack tight"><span className="muted small">{a}</span>
            <div className="chip-pick">{valuesOf(a).map((val) => (
              <button key={val} className={sel[a] === val ? 'on' : ''} disabled={!possible(a, val)} onClick={() => setSel({ ...sel, [a]: val })}>{val}</button>))}</div>
          </div>))}
        {variants.length === 0 && <p className="muted">{t('No variants yet. Create them in Products.')}</p>}
        <p className="muted small">{fmt(template.price, tenant, lang)}{stock ? '' : ''}</p>
      </div>
    </Modal>
  )
}

/** Choose the add-ons for one item; required groups must be answered. */
export function ModifierDialog({ item, groups, options, decimals, onConfirm, onClose }: {
  item: Item; groups: ModifierGroup[]; options: ModifierOption[]; decimals: number
  onConfirm: (opts: ModifierOption[]) => void; onClose: () => void
}) {
  const { t } = useT()
  const nameOf = useName()
  const [picked, setPicked] = useState<string[]>([])
  const ok = groups.every((g) => { const n = options.filter((o) => o.group_id === g.id && picked.includes(o.id)).length; return n >= g.min_select && n <= g.max_select })
  const extra = options.filter((o) => picked.includes(o.id)).reduce((a, o) => a + o.price, 0)
  function toggle(g: ModifierGroup, o: ModifierOption) {
    const inGroup = options.filter((x) => x.group_id === g.id).map((x) => x.id)
    if (picked.includes(o.id)) return setPicked(picked.filter((x) => x !== o.id))
    if (g.max_select === 1) return setPicked([...picked.filter((x) => !inGroup.includes(x)), o.id])
    if (picked.filter((x) => inGroup.includes(x)).length < g.max_select) setPicked([...picked, o.id])
  }
  return (
    <Modal title={nameOf(item)} onClose={onClose}>
      <div className="stack">
        {groups.map((g) => (
          <div key={g.id} className="stack tight">
            <span className="mod-head">{nameOf(g)} <em className="muted small">{g.min_select > 0 ? t('Required') : t('Optional')}{g.max_select > 1 ? ` · ${t('up to {n}', { n: g.max_select })}` : ''}</em></span>
            <div className="chip-pick">{options.filter((o) => o.group_id === g.id && o.is_active).map((o) => (
              <button key={o.id} className={picked.includes(o.id) ? 'on' : ''} onClick={() => toggle(g, o)}>{nameOf(o)}{o.price > 0 && <small> +{num(o.price, decimals)}</small>}</button>))}</div>
          </div>))}
        <div className="row between">
          <span className="muted">{t('Price')}: <b>{num(item.price + extra, decimals)}</b></span>
          <button className="primary" disabled={!ok} onClick={() => onConfirm(options.filter((o) => picked.includes(o.id)))}>{t('Add to sale')}</button>
        </div>
      </div>
    </Modal>
  )
}

export interface StaffMember { user_id: string; display_name: string; bookable: boolean; color: string | null }
export function StaffPicker({ staff, current, onPick, onClose }: { staff: StaffMember[]; current?: string | null; onPick: (id: string | null) => void; onClose: () => void }) {
  const { t } = useT()
  return (
    <Modal title={t('Served by')} onClose={onClose}>
      <div className="chip-pick wrap">
        {staff.map((m) => <button key={m.user_id} className={current === m.user_id ? 'on' : ''} onClick={() => onPick(m.user_id)}>{m.display_name}</button>)}
        <button className={!current ? 'on' : ''} onClick={() => onPick(null)}>{t('Nobody')}</button>
      </div>
    </Modal>
  )
}

/** Floor plan: free tables, tables with an open order (amount and minutes), and tabs without a table. */
export function TablesDialog({ branchId, tenant, onOpen, onClose }: {
  branchId: string; tenant: Tenant; onOpen: (o: OpenOrder | null, table: DiningTable | null, label?: string) => void; onClose: () => void
}) {
  const { t, lang } = useT()
  const s = useSession()
  const [tables, setTables] = useState<DiningTable[]>([])
  const [orders, setOrders] = useState<OpenOrder[]>([])
  const [tab, setTab] = useState('')
  useEffect(() => {
    void Promise.all([
      supabase.from('dining_tables').select('*').eq('branch_id', branchId).eq('is_active', true).order('area').order('name'),
      supabase.from('open_orders').select('*').eq('branch_id', branchId).eq('status', 'open').order('opened_at'),
    ]).then(([a, b]) => { setTables((a.data ?? []) as DiningTable[]); setOrders((b.data ?? []) as OpenOrder[]) })
  }, [branchId])
  const areas = useMemo(() => [...new Set(tables.map((x) => x.area))], [tables])
  const totalOf = (o: OpenOrder) => o.lines.reduce((a, l) => a + Math.round(Number(l.qty) * Number(l.unit_price)), 0)
  const mins = (o: OpenOrder) => Math.floor((Date.now() - new Date(o.opened_at).getTime()) / 60000)
  return (
    <Modal title={t('Tables')} onClose={onClose} wide>
      <div className="stack">
        {tables.length === 0 && <p className="muted">{t('No tables yet.')} {s.can('settings.manage') ? t('Add them in Settings → Tables.') : ''}</p>}
        {areas.map((a) => (
          <div key={a} className="stack tight"><span className="fam-head">{a}</span>
            <div className="table-grid">{tables.filter((x) => x.area === a).map((tb) => {
              const o = orders.find((x) => x.table_id === tb.id)
              return (
                <button key={tb.id} className={`dtable ${tb.shape} ${o ? 'busy' : ''}`} onClick={() => onOpen(o ?? null, tb)}>
                  <b>{tb.name}</b>
                  {o ? <><span>{fmt(totalOf(o), tenant, lang)}</span><small>{t('{n} min', { n: mins(o) })}{o.guests ? ` · ${o.guests} ${t('guests')}` : ''}</small></> : <small>{t('{n} seats', { n: tb.seats })}</small>}
                </button>)
            })}</div>
          </div>))}
        {orders.filter((o) => !o.table_id).length > 0 && (
          <div className="stack tight"><span className="fam-head">{t('Open tabs')}</span>
            <div className="table-grid">{orders.filter((o) => !o.table_id).map((o) => (
              <button key={o.id} className="dtable busy" onClick={() => onOpen(o, null)}><b>{o.label}</b><span>{fmt(totalOf(o), tenant, lang)}</span><small>{t('{n} min', { n: mins(o) })}</small></button>))}</div>
          </div>)}
        <form className="row" onSubmit={(e) => { e.preventDefault(); if (tab.trim()) onOpen(null, null, tab.trim()) }}>
          <input id="tab-name" placeholder={t('New tab without a table, e.g. Bar 1')} value={tab} onChange={(e) => setTab(e.target.value)} />
          <button className="ghost" disabled={!tab.trim()}>{t('Open tab')}</button>
        </form>
      </div>
    </Modal>
  )
}

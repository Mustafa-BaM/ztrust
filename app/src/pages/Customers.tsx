import { useSearchParams } from 'react-router-dom'
import { useCallback, useEffect, useState } from 'react'
import { Statement } from '../components/Statement'
import { Empty, Modal, useApproval } from '../components/ui'
import { useT } from '../lib/i18n'
import { fmt, num, toMinor } from '../lib/money'
import { useSession } from '../lib/session'
import { rpc, supabase } from '../lib/supabase'
import type { Customer, CustomerPackage } from '../lib/types'
import { parseError } from '../lib/supabase'

export default function Customers() {
  const { t, lang } = useT()
  const s = useSession()
  const tenant = s.tenant!
  const [rows, setRows] = useState<Customer[]>([])
  const [bal, setBal] = useState<Record<string, number>>({})
  const [q, setQ] = useState('')
  const [edit, setEdit] = useState<Partial<Customer> | null>(null)
  const [view, setView] = useState<Customer | null>(null)
  const [tab, setTab] = useState<'customers' | 'gift'>('customers')
  const [tagF, setTagF] = useState('')
  const [bdays, setBdays] = useState(false)
  const [params, setParams] = useSearchParams()
  useEffect(() => {
    const c = params.get('c'), n = params.get('new')
    if (n) { setEdit({ credit_limit: 0 }); setParams({}, { replace: true }) }
    if (c) void supabase.from('customers').select('*').eq('id', c).maybeSingle().then(({ data }) => { if (data) setView(data as Customer); setParams({}, { replace: true }) })
  }, [params, setParams])

  const load = useCallback(async () => {
    let query = supabase.from('customers').select('*').eq('tenant_id', tenant.id).order('name').limit(300)
    if (q) query = query.or(`name.ilike.%${q.replace(/[%,()]/g, '')}%,phone.ilike.%${q.replace(/[%,()]/g, '')}%`)
    const { data } = await query
    const list = (data ?? []) as Customer[]
    setRows(list)
    const b: Record<string, number> = {}
    await Promise.all(list.filter((c) => c.credit_limit > 0).map(async (c) => { b[c.id] = await rpc<number>('customer_balance', { p_customer: c.id }) }))
    setBal(b)
  }, [tenant.id, q])
  useEffect(() => { void load() }, [load])

  return (
    <div className="page">
      <div className="row between"><h1>{t('Customers')}</h1><button className="primary" onClick={() => setEdit({ credit_limit: 0 })}>{t('Add customer')}</button></div>
      {s.has('gift_cards') && <div className="tabs"><button className={tab === 'customers' ? 'on' : ''} onClick={() => setTab('customers')}>{t('Customers')}</button><button className={tab === 'gift' ? 'on' : ''} onClick={() => setTab('gift')}>{t('Gift cards')}</button></div>}
      {tab === 'gift' ? <GiftCards /> : <>
      <div className="row wrap"><input id="customers-q" className="search" placeholder={t('Search by name or phone')} value={q} onChange={(e) => setQ(e.target.value)} />
        <button className={`chipbtn ${bdays ? 'on' : ''}`} onClick={() => setBdays(!bdays)}>{t('Birthdays this month')}</button>
        {[...new Set(rows.flatMap((c) => c.tags ?? []))].map((g) => <button key={g} className={`chipbtn ${tagF === g ? 'on' : ''}`} onClick={() => setTagF(tagF === g ? '' : g)}>#{g}</button>)}</div>
      {rows.length === 0 ? <Empty title={t('No customers yet.')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>{t('Phone')}</th><th className="num">{t('Credit limit')}</th><th className="num">{t('Balance owed')}</th><th /></tr></thead>
          <tbody>{rows.filter((c) => (!tagF || c.tags?.includes(tagF)) && (!bdays || (c.birthday ?? '').slice(5, 7) === new Date().toISOString().slice(5, 7))).map((c) => (
            <tr key={c.id} tabIndex={0} className="clickable" onClick={() => setView(c)}><td>{c.name}{c.tags?.map((g) => <span key={g} className="tag">#{g}</span>)}{c.birthday && c.birthday.slice(5, 7) === new Date().toISOString().slice(5, 7) && <span className="tag promo">🎂 {c.birthday.slice(8, 10)}/{c.birthday.slice(5, 7)}</span>}</td><td className="mono">{c.phone}</td><td className="num">{c.credit_limit ? fmt(c.credit_limit, tenant, lang) : '—'}</td>
              <td className={`num ${(bal[c.id] ?? 0) > 0 ? 'bad' : ''}`}>{bal[c.id] != null ? fmt(bal[c.id], tenant, lang) : '—'}</td>
              <td>{s.can('customers.manage') && <button className="ghost small" onClick={(e) => { e.stopPropagation(); setEdit(c) }}>{t('Edit')}</button>}</td></tr>))}</tbody>
        </table></div>
      )}
      </>}
      {view && <CustomerCard c={view} onClose={() => setView(null)} />}
      {edit && <CustomerForm c={edit} onClose={() => setEdit(null)} onSaved={async () => { setEdit(null); await load() }} />}
    </div>
  )
}

function CustomerForm({ c, onClose, onSaved }: { c: Partial<Customer>; onClose: () => void; onSaved: () => void }) {
  const { t } = useT()
  const s = useSession()
  const d = s.tenant!.currency_decimals
  const [f, setF] = useState({ name: c.name ?? '', phone: c.phone ?? '', email: c.email ?? '', address: c.address ?? '', credit_limit: num(c.credit_limit ?? 0, d),
    birthday: c.birthday ?? '', tags: (c.tags ?? []).join(', '), preferences: c.preferences ?? '' })
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault()
    const row = { tenant_id: s.tenant!.id, name: f.name.trim(), phone: f.phone.trim() || null, email: f.email.trim() || null, address: f.address.trim() || null,
      birthday: f.birthday || null, tags: f.tags.split(',').map((x) => x.trim()).filter(Boolean), preferences: f.preferences.trim() || null,
      ...(s.can('customers.manage') ? { credit_limit: toMinor(f.credit_limit || '0', d) } : {}) }
    const r = c.id ? await supabase.from('customers').update(row).eq('id', c.id) : await supabase.from('customers').insert(row)
    if (r.error) setErr(r.error.message); else onSaved()
  }
  return (
    <Modal title={c.id ? t('Edit customer') : t('Add customer')} onClose={onClose}>
      <form className="stack" onSubmit={save}>
        <label className="field"><span>{t('Name')}</span><input id="c-name" required value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>{t('Phone')}</span><input id="c-phone" inputMode="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} placeholder="+965…" /></label>
        <label className="field"><span>{t('E-mail')}</span><input id="c-email" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></label>
        <label className="field"><span>{t('Delivery address')}</span><textarea id="c-address" rows={2} value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} /></label>
        <label className="field"><span>{t('Birthday')}</span><input id="c-birthday" type="date" value={f.birthday} onChange={(e) => setF({ ...f, birthday: e.target.value })} /></label>
        <label className="field"><span>{t('Tags (e.g. VIP, corporate)')}</span><input id="c-tags" value={f.tags} onChange={(e) => setF({ ...f, tags: e.target.value })} /></label>
        <label className="field"><span>{t('Preferences (sizes, favourite items, allergies)')}</span><textarea id="c-pref" rows={2} value={f.preferences} onChange={(e) => setF({ ...f, preferences: e.target.value })} /></label>
        {s.can('customers.manage') && <label className="field"><span>{t('Credit limit (0 = no credit sales)')}</span><input id="c-limit" inputMode="decimal" value={f.credit_limit} onChange={(e) => setF({ ...f, credit_limit: e.target.value })} /></label>}
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Save')}</button></div>
      </form>
    </Modal>
  )
}

/** One customer: points, prepaid packages and memberships (with check-in), gift cards. */
function CustomerCard({ c, onClose }: { c: Customer; onClose: () => void }) {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [pkgs, setPkgs] = useState<(CustomerPackage & { visits?: number })[]>([])
  const [points, setPoints] = useState<number | null>(null)
  const [cards, setCards] = useState<{ code: string; balance: number; status: string; expires_on: string | null }[]>([])
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [tab, setTab] = useState<'overview' | 'statement' | 'purchases'>('overview')
  const canMoney = s.can('payments.receive') || s.can('customers.manage') || s.can('finance.view')
  const load = useCallback(async () => {
    const [p, g] = await Promise.all([
      supabase.from('customer_packages').select('*, package_uses(count)').eq('customer_id', c.id).order('created_at', { ascending: false }),
      supabase.from('gift_cards').select('code, balance, status, expires_on').eq('customer_id', c.id),
    ])
    setPkgs(((p.data ?? []) as (CustomerPackage & { package_uses: { count: number }[] })[]).map((x) => ({ ...x, visits: x.package_uses?.[0]?.count ?? 0 })))
    setCards(g.data ?? [])
    if (s.has('loyalty')) setPoints(await rpc<number>('customer_points', { p_customer: c.id }).catch(() => null))
  }, [c.id, s])
  useEffect(() => { void load() }, [load])
  async function checkIn(id: string) {
    setMsg(null)
    try { const r = await rpc<{ visits: number; expires_on: string }>('use_membership', { p_id: id }); setMsg({ ok: true, text: t('Checked in · visit {n} · valid until {d}', { n: r.visits, d: r.expires_on }) }); await load() }
    catch (e) { const p = parseError(e); setMsg({ ok: false, text: p.kind === 'message' ? t(p.message) : t('Not allowed') }) }
  }
  return (
    <Modal title={c.name} onClose={onClose} wide>
      <div className="tabs" role="tablist">{(['overview', 'statement', 'purchases'] as const).filter((x) => x === 'overview' || canMoney).map((x) => (
        <button key={x} role="tab" aria-selected={tab === x} className={tab === x ? 'on' : ''} onClick={() => setTab(x)}>{t(x === 'overview' ? 'Overview' : x === 'statement' ? 'Statement' : 'Purchases')}</button>))}</div>
      {tab === 'statement' && <Statement kind="ar" partyId={c.id} partyName={c.name} />}
      {tab === 'purchases' && <Purchases customerId={c.id} />}
      {tab === 'overview' && <div className="stack">
        <p className="muted">{c.phone}{c.address ? ` · ${c.address}` : ''}</p>
        <CustomerTerms c={c} />
        {c.preferences && <p className="amber-note">{c.preferences}</p>}
        <ClientNotes customerId={c.id} />
        {points != null && <div className="kpi2"><span className="kpi2-label">{t('Loyalty points')}</span><b className="kpi2-value">{points}</b></div>}
        {pkgs.length > 0 && <>
          <h3 className="sub-h">{t('Packages and memberships')}</h3>
          <ul className="mod-list">{pkgs.map((p) => {
            const active = p.status === 'active' && p.expires_on >= new Date().toISOString().slice(0, 10)
            return (
              <li key={p.id}><div><b>{p.name}</b><p className="muted small">{p.kind === 'unlimited' ? t('{n} visits', { n: p.visits ?? 0 }) : t('{u} of {n} sessions used', { u: p.sessions_used, n: p.sessions_total ?? 0 })} · {t('valid until {d}', { d: p.expires_on })}</p></div>
                {p.kind === 'unlimited' && active ? <button className="primary" onClick={() => void checkIn(p.id)}>{t('Check in')}</button> : <span className={`pill ${active ? '' : 'muted-pill'}`}>{t(active ? 'Active' : p.status === 'used' ? 'Used' : 'Expired')}</span>}</li>)
          })}</ul></>}
        {cards.length > 0 && <>
          <h3 className="sub-h">{t('Gift cards')}</h3>
          <ul className="mod-list">{cards.map((g) => <li key={g.code}><span className="mono">{g.code}</span><b>{fmt(g.balance, tn, lang)}</b></li>)}</ul></>}
        {msg && <p className={msg.ok ? 'success' : 'error'} role="status">{msg.text}</p>}
        {pkgs.length === 0 && cards.length === 0 && points == null && <p className="muted">{t('No packages, points or gift cards yet.')}</p>}
      </div>}
    </Modal>
  )
}

function GiftCards() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [rows, setRows] = useState<{ id: string; code: string; initial: number; balance: number; status: string; expires_on: string | null; created_at: string }[]>([])
  const [q, setQ] = useState('')
  useEffect(() => {
    let x = supabase.from('gift_cards').select('*').eq('tenant_id', tn.id).order('created_at', { ascending: false }).limit(300)
    if (q) x = x.ilike('code', `%${q.replace(/[%,()]/g, '')}%`)
    void x.then(({ data }) => setRows(data ?? []))
  }, [tn.id, q])
  const out = rows.filter((r) => r.status === 'active').reduce((a, r) => a + r.balance, 0)
  return (
    <section className="stack">
      <div className="kpi-row"><div className="kpi2"><span className="kpi2-label">{t('Cards')}</span><b className="kpi2-value">{rows.length}</b></div>
        <div className="kpi2"><span className="kpi2-label">{t('Outstanding balance (owed to card holders)')}</span><b className="kpi2-value">{fmt(out, tn, lang)}</b></div></div>
      <p className="muted small">{t('Sell a gift card from the till (Products → type “Gift card”). Customers pay with it by choosing “Gift card” and entering the code.')}</p>
      <input id="gc-q" className="search" placeholder={t('Search code')} value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="table-wrap"><table className="list">
        <thead><tr><th>{t('Code')}</th><th className="num">{t('Value')}</th><th className="num">{t('Balance')}</th><th>{t('Valid until')}</th><th>{t('Issued')}</th></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.id}><td className="mono">{r.code}</td><td className="num">{fmt(r.initial, tn, lang)}</td><td className="num"><b>{fmt(r.balance, tn, lang)}</b></td><td>{r.expires_on ?? '—'}</td><td>{new Date(r.created_at).toLocaleDateString()}</td></tr>)}</tbody>
      </table></div>
    </section>
  )
}

/** Every invoice and credit note of this customer, newest first. */
function Purchases({ customerId }: { customerId: string }) {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [rows, setRows] = useState<{ id: string; number: string; doc_type: string; total: number; paid_total: number; refunded_total: number; status: string; created_at: string }[] | null>(null)
  useEffect(() => {
    void supabase.from('sales').select('id, number, doc_type, total, paid_total, refunded_total, status, created_at').eq('customer_id', customerId)
      .order('created_at', { ascending: false }).limit(200).then(({ data }) => setRows(data ?? []))
  }, [customerId])
  if (!rows) return <p className="muted">{t('Loading…')}</p>
  if (!rows.length) return <Empty title={t('No purchases yet')} />
  const spent = rows.reduce((a, r) => a + (r.doc_type === 'invoice' ? r.total : -r.total), 0)
  return (
    <div className="stack">
      <p className="muted">{t('{n} documents', { n: rows.length })} · {t('Net purchases')}: <b>{fmt(spent, tn, lang)}</b></p>
      <div className="table-wrap"><table className="list compact">
        <thead><tr><th>{t('Date')}</th><th>{t('Number')}</th><th>{t('Status')}</th><th className="num">{t('Total')}</th><th className="num">{t('Balance due')}</th></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.id}><td>{r.created_at.slice(0, 10)}</td><td><a href={`/sales?q=${encodeURIComponent(r.number)}`}>{r.number}</a></td><td>{t(r.status)}</td>
          <td className="num">{r.doc_type === 'invoice' ? '' : '−'}{fmt(r.total, tn, lang)}</td>
          <td className="num">{r.doc_type === 'invoice' && r.total - r.paid_total - r.refunded_total > 0 ? fmt(r.total - r.paid_total - r.refunded_total, tn, lang) : ''}</td></tr>)}</tbody>
      </table></div>
    </div>
  )
}

/** Price list and extra charges (debit note) for one customer. */
function CustomerTerms({ c }: { c: Customer }) {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const approval = useApproval()
  const [lists, setLists] = useState<{ id: string; name: string; name_ar: string | null }[]>([])
  const [listId, setListId] = useState(c.price_list_id ?? '')
  const [dn, setDn] = useState<null | { amount: string; reason: string }>(null)
  const [msg, setMsg] = useState<string | null>(null)
  useEffect(() => { void supabase.from('price_lists').select('id, name, name_ar').eq('tenant_id', tn.id).eq('is_active', true).order('name').then(({ data }) => setLists(data ?? [])) }, [tn.id])
  async function setList(v: string) {
    setListId(v)
    const r = await approval.run(() => rpc('set_customer_price_list', { p_customer: c.id, p_list: v || null }).then(() => true))
    setMsg(r ? t('Saved') : null)
  }
  async function debit() {
    if (!dn) return
    const r = await approval.run(() => rpc<{ number: string }>('customer_debit_note', { p: { tenant_id: tn.id, branch_id: s.branch!.id, customer_id: c.id, amount: toMinor(dn.amount, tn.currency_decimals), reason: dn.reason } }))
    if (r) { setDn(null); setMsg(t('Debit note {n} issued', { n: r.number })) }
  }
  return (
    <div className="row wrap">
      {s.can('customers.manage') && lists.length > 0 && <label className="field"><span>{t('Price list')}</span>
        <select id="cust-pricelist" value={listId} onChange={(e) => void setList(e.target.value)}><option value="">{t('Standard prices')}</option>
          {lists.map((l) => <option key={l.id} value={l.id}>{lang === 'ar' && l.name_ar ? l.name_ar : l.name}</option>)}</select></label>}
      {s.can('finance.journal') && !dn && <button className="ghost" onClick={() => setDn({ amount: '', reason: '' })}>{t('Debit note')}</button>}
      {dn && <form className="row wrap" onSubmit={(e) => { e.preventDefault(); void debit() }}>
        <label className="field"><span>{t('Amount')}</span><input id="dn-amount" inputMode="decimal" value={dn.amount} onChange={(e) => setDn({ ...dn, amount: e.target.value })} /></label>
        <label className="field"><span>{t('Reason')}</span><input id="dn-reason" value={dn.reason} onChange={(e) => setDn({ ...dn, reason: e.target.value })} placeholder={t('e.g. Delivery charge, price correction')} /></label>
        <button className="primary" disabled={!dn.amount || !dn.reason.trim()}>{t('Issue debit note')}</button><button type="button" className="ghost" onClick={() => setDn(null)}>{t('Cancel')}</button></form>}
      {(msg || approval.error) && <p className={approval.error ? 'error' : 'success'}>{approval.error ?? msg}</p>}
      {approval.dialog}
    </div>
  )
}

/** Clienteling: notes and follow-ups on a customer, newest first, with who wrote them. */
function ClientNotes({ customerId }: { customerId: string }) {
  const { t } = useT()
  const s = useSession()
  const [rows, setRows] = useState<{ id: number; note: string; follow_up: string | null; created_at: string; created_by: string | null }[]>([])
  const [people, setPeople] = useState<Record<string, string>>({})
  const [f, setF] = useState({ note: '', follow_up: '' })
  const load = useCallback(async () => {
    const { data } = await supabase.from('customer_notes').select('*').eq('customer_id', customerId).order('created_at', { ascending: false }).limit(50); setRows(data ?? [])
  }, [customerId])
  useEffect(() => { void load(); void supabase.from('memberships').select('user_id, display_name').eq('tenant_id', s.tenant!.id).then(({ data }) => setPeople(Object.fromEntries((data ?? []).map((m) => [m.user_id, m.display_name])))) }, [load, s.tenant])
  async function add() {
    const { error } = await supabase.from('customer_notes').insert({ tenant_id: s.tenant!.id, customer_id: customerId, note: f.note.trim(), follow_up: f.follow_up || null })
    if (!error) { setF({ note: '', follow_up: '' }); void load() }
  }
  return (
    <section className="stack">
      <h3 className="sub-h">{t('Notes and follow-ups')}</h3>
      <form className="row wrap" onSubmit={(e) => { e.preventDefault(); void add() }}>
        <input id="cn-note" aria-label={t('Note')} placeholder={t('e.g. Wants the blue one in size M when it arrives')} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} />
        <input id="cn-follow" type="date" aria-label={t('Follow up on')} value={f.follow_up} onChange={(e) => setF({ ...f, follow_up: e.target.value })} />
        <button className="primary" disabled={!f.note.trim()}>{t('Add note')}</button></form>
      {rows.length > 0 && <ul className="feed">{rows.map((r) => <li key={r.id}><span className="feed-ico" aria-hidden="true">✎</span>
        <div><b>{r.note}</b><p className="muted small">{people[r.created_by ?? ''] ?? ''} · {r.created_at.slice(0, 10)}{r.follow_up ? ` · ${t('Follow up on')} ${r.follow_up}` : ''}</p></div></li>)}</ul>}
    </section>
  )
}

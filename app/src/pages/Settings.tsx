import { useSearchParams } from 'react-router-dom'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Modal } from '../components/ui'
import { useName, useT } from '../lib/i18n'
import { useSession } from '../lib/session'
import { rpc, supabase, supabaseUrl } from '../lib/supabase'
import type { Category, DeliveryChannel, Membership, PermDef, RolePkg, RoleTemplate, Station } from '../lib/types'
import { Receipt, type ReceiptData } from '../components/Receipt'
import { num, toMinor } from '../lib/money'
import { WIDGETS, layoutFor } from './Dashboard'
import { configureHub, detectHub, hubSettings, useHub } from '../lib/hub'
import { prepareLogo } from '../lib/logo'
import Modules from './settings/Modules'
import Integrations from './settings/Integrations'
import { ModuleSettings, StaffExtras, TablesSetup } from './settings/ModuleSettings'
import { RulesSettings } from './settings/Rules'
import { RECEIPT_FONTS } from '../components/Receipt'

const MODULES: Record<string, string> = {
  sales: 'Sales and cash', kitchen: 'Kitchen', catalog: 'Products and customers', inventory: 'Inventory',
  purchasing: 'Purchasing', reports: 'Reports', finance: 'Finance', admin: 'Administration',
}

export default function Settings() {
  const { t } = useT()
  const s = useSession()
  const owner = s.role === 'owner'
  const tabs = [
    { id: 'modules' as const, label: 'Business type & modules', show: owner },
    { id: 'roles' as const, label: 'Roles & permissions', show: owner },
    { id: 'staff' as const, label: 'Staff', show: s.can('staff.manage') },
    { id: 'dash' as const, label: 'Dashboards', show: owner },
    { id: 'kitchen' as const, label: 'Kitchen stations', show: s.can('settings.manage') && s.has('kitchen') },
    { id: 'tables' as const, label: 'Tables', show: s.can('settings.manage') && s.has('tables') },
    { id: 'business' as const, label: 'Business and receipt', show: s.can('settings.manage') },
    { id: 'delivery' as const, label: 'Delivery platforms', show: s.can('settings.manage') && s.has('delivery') },
    { id: 'integrations' as const, label: 'Integrations', show: s.can('settings.manage') },
    { id: 'device' as const, label: 'This device', show: true },
  ].filter((x) => x.show)
  const [params] = useSearchParams()
  const [tab, setTab] = useState<(typeof tabs)[number]['id']>(() => (tabs.find((x) => x.id === params.get('tab'))?.id ?? tabs[0].id))
  return (
    <div className="page">
      <h1>{t('Settings')}</h1>
      <div className="tabs">{tabs.map((x) => <button key={x.id} className={tab === x.id ? 'on' : ''} onClick={() => setTab(x.id)}>{t(x.label)}</button>)}</div>
      {tab === 'modules' && <Modules />}
      {tab === 'roles' && <Roles />}
      {tab === 'staff' && <Staff />}
      {tab === 'dash' && <Dashboards />}
      {tab === 'kitchen' && <Kitchen />}
      {tab === 'tables' && <TablesSetup />}
      {tab === 'business' && <Business />}
      {tab === 'delivery' && <Delivery />}
      {tab === 'integrations' && <Integrations onOpenModules={() => setTab('modules')} />}
      {tab === 'device' && <Device />}
    </div>
  )
}

/** Role packages: pick a package on the left, tick its permissions and limits on the right. */
function Roles() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const unit = 10 ** tn.currency_decimals
  const [roles, setRoles] = useState<RolePkg[]>([])
  const [catalog, setCatalog] = useState<PermDef[]>([])
  const [templates, setTemplates] = useState<RoleTemplate[]>([])
  const [perms, setPerms] = useState<Record<string, number | null>>({})
  const [members, setMembers] = useState<Record<string, number>>({})
  const [sel, setSel] = useState('cashier')
  const [creating, setCreating] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const label = (r: { name_en: string; name_ar: string }) => (lang === 'ar' ? r.name_ar : r.name_en)

  const load = useCallback(async () => {
    const [r, c, tp, m] = await Promise.all([
      supabase.from('roles').select('*').eq('tenant_id', tn.id).order('sort'),
      supabase.from('permission_catalog').select('*').order('sort'),
      supabase.from('role_templates').select('*').order('sort'),
      supabase.from('memberships').select('role').eq('tenant_id', tn.id),
    ])
    setRoles((r.data ?? []) as RolePkg[]); setCatalog((c.data ?? []) as PermDef[]); setTemplates((tp.data ?? []) as RoleTemplate[])
    const cnt: Record<string, number> = {}; for (const x of m.data ?? []) cnt[x.role] = (cnt[x.role] ?? 0) + 1
    setMembers(cnt)
  }, [tn.id])
  const loadPerms = useCallback(async () => {
    const { data } = await supabase.from('role_permissions').select('permission, limit_value').eq('tenant_id', tn.id).eq('role', sel)
    const p: Record<string, number | null> = {}; for (const x of data ?? []) p[x.permission] = x.limit_value
    setPerms(p)
  }, [tn.id, sel])
  useEffect(() => { void load() }, [load])
  useEffect(() => { void loadPerms() }, [loadPerms])

  const role = roles.find((r) => r.key === sel)
  const grouped = useMemo(() => {
    const g: Record<string, PermDef[]> = {}
    for (const p of catalog) (g[p.module] ??= []).push(p)
    return g
  }, [catalog])

  async function toggle(p: PermDef, on: boolean) {
    const r = on
      ? await supabase.from('role_permissions').insert({ tenant_id: tn.id, role: sel, permission: p.key, limit_value: null })
      : await supabase.from('role_permissions').delete().eq('tenant_id', tn.id).eq('role', sel).eq('permission', p.key)
    setMsg(r.error ? r.error.message : null); await loadPerms()
  }
  async function setLimit(p: PermDef, raw: string) {
    const v = raw.trim() === '' ? null : p.limit_kind === 'money' ? Math.round(parseFloat(raw) * unit) : parseFloat(raw)
    if (v !== null && !Number.isFinite(v)) return
    const r = await supabase.from('role_permissions').update({ limit_value: v }).eq('tenant_id', tn.id).eq('role', sel).eq('permission', p.key)
    setMsg(r.error ? r.error.message : t('Saved')); await loadPerms()
  }
  async function remove() {
    if (!role || role.is_system) return
    const r = await supabase.from('roles').delete().eq('tenant_id', tn.id).eq('key', role.key)
    if (r.error) setMsg(members[role.key] ? t('Move the staff in this role to another role first.') : r.error.message)
    else { setSel('cashier'); await load(); await s.reload() }
  }

  return (
    <section className="roles">
      <aside className="card role-list">
        <div className="row between"><h2>{t('Role packages')}</h2><button className="primary small" onClick={() => setCreating(true)}>{t('New role')}</button></div>
        <ul className="plain">{roles.map((r) => (
          <li key={r.key}><button className={`role-item ${sel === r.key ? 'on' : ''}`} onClick={() => setSel(r.key)}>
            <b>{label(r)}</b><span className="muted small">{[members[r.key] ? t('{n} staff', { n: members[r.key] }) : '', !r.is_system ? t('custom') : ''].filter(Boolean).join(' · ')}</span>
          </button></li>))}</ul>
      </aside>
      <div className="card">
        {role && (
          <>
            <div className="row between wrap">
              <div><h2>{label(role)}</h2><p className="muted small">{lang === 'ar' ? role.description_ar : role.description_en}</p></div>
              {!role.is_system && <button className="danger small" onClick={() => void remove()}>{t('Delete role')}</button>}
            </div>
            {role.key === 'owner' ? <p className="muted">{t('The owner always has every permission.')}</p> : (
              <div className="perm-groups">
                {Object.entries(grouped).map(([mod, list]) => (
                  <fieldset key={mod} className="perm-group">
                    <legend>{t(MODULES[mod] ?? mod)}</legend>
                    {list.map((p) => {
                      const has = p.key in perms
                      const lim = perms[p.key]
                      return (
                        <div key={p.key} className="perm-row">
                          <label className="check"><input id={`p-${p.key}`} type="checkbox" checked={has} onChange={(e) => void toggle(p, e.target.checked)} />{label(p)}</label>
                          {has && p.limit_kind && (
                            <span className="row">
                              <input key={`${sel}-${p.key}-${lim}`} id={`lim-${p.key}`} className="lim" inputMode="decimal" aria-label={t('Limit')} placeholder="∞"
                                defaultValue={lim == null ? '' : p.limit_kind === 'money' ? String(lim / unit) : String(lim)}
                                onBlur={(e) => void setLimit(p, e.target.value)} />
                              <span className="muted small">{p.limit_kind === 'pct' ? '%' : tn.currency}</span>
                            </span>)}
                        </div>)
                    })}
                  </fieldset>))}
              </div>
            )}
            <p className="muted small">{t('Limits are checked by the database on every action. Above the limit, a manager with a higher limit approves with their PIN.')}</p>
            {msg && <p className="muted">{msg}</p>}
          </>
        )}
      </div>
      {creating && <NewRole templates={templates} catalog={catalog} onClose={() => setCreating(false)}
        onCreated={async (key) => { setCreating(false); await load(); await s.reload(); setSel(key) }} />}
    </section>
  )
}

function NewRole({ templates, catalog, onClose, onCreated }: { templates: RoleTemplate[]; catalog: PermDef[]; onClose: () => void; onCreated: (key: string) => void }) {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [f, setF] = useState({ name_en: '', name_ar: '', template: 'cashier' })
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    const key = (f.name_en.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'role').replace(/^([^a-z])/, 'r_$1').slice(0, 28) + '_' + Math.random().toString(36).slice(2, 5)
    const tpl = templates.find((x) => x.key === f.template)
    const r = await supabase.from('roles').insert({ tenant_id: tn.id, key, name_en: f.name_en.trim(), name_ar: f.name_ar.trim() || f.name_en.trim(), template: f.template,
      description_en: tpl ? `Based on ${tpl.name_en}` : null, description_ar: tpl ? `مبني على ${tpl.name_ar}` : null })
    if (r.error) return setErr(r.error.message)
    const unit = 10 ** tn.currency_decimals
    const rows = Object.entries(tpl?.perms ?? {}).map(([permission, v]) => ({
      tenant_id: tn.id, role: key, permission,
      limit_value: v == null ? null : catalog.find((c) => c.key === permission)?.limit_kind === 'money' ? v * unit : v,
    }))
    if (rows.length) { const p = await supabase.from('role_permissions').insert(rows); if (p.error) return setErr(p.error.message) }
    onCreated(key)
  }
  return (
    <Modal title={t('New role')} onClose={onClose}>
      <form className="stack" onSubmit={save}>
        <label className="field"><span>{t('Name (English)')}</span><input id="nr-en" required value={f.name_en} onChange={(e) => setF({ ...f, name_en: e.target.value })} placeholder="Night cashier" /></label>
        <label className="field"><span>{t('Name (Arabic)')}</span><input id="nr-ar" dir="rtl" value={f.name_ar} onChange={(e) => setF({ ...f, name_ar: e.target.value })} placeholder="كاشير ليلي" /></label>
        <label className="field"><span>{t('Start from')}</span>
          <select id="nr-tpl" value={f.template} onChange={(e) => setF({ ...f, template: e.target.value })}>
            {templates.filter((x) => x.key !== 'owner').map((x) => <option key={x.key} value={x.key}>{lang === 'ar' ? x.name_ar : x.name_en}</option>)}
          </select></label>
        {err && <p className="error">{err}</p>}
        <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary">{t('Create role')}</button></div>
      </form>
    </Modal>
  )
}

function Staff() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [list, setList] = useState<Membership[]>([])
  const assignable = s.roles.filter((r) => r.key !== 'owner')
  const [inv, setInv] = useState({ email: '', display_name: '', role: 'cashier' })
  const [msg, setMsg] = useState<string | null>(null)
  const load = useCallback(async () => {
    const { data } = await supabase.from('memberships').select('tenant_id,user_id,role,display_name,branch_ids,is_active,bookable,commission_pct,is_driver').eq('tenant_id', tn.id).order('display_name')
    setList((data ?? []) as Membership[])
  }, [tn.id])
  useEffect(() => { void load() }, [load])

  async function invite(e: React.FormEvent) {
    e.preventDefault(); setMsg(null)
    const { data, error } = await supabase.functions.invoke('invite-staff', { body: { tenant_id: tn.id, ...inv } })
    setMsg(error ? error.message : (data as { message?: string })?.message ?? t('Invitation sent'))
    if (!error) { setInv({ email: '', display_name: '', role: 'cashier' }); await load() }
  }
  async function update(m: Membership, patch: Partial<Membership>) {
    const { error } = await supabase.from('memberships').update(patch).eq('tenant_id', tn.id).eq('user_id', m.user_id)
    setMsg(error ? error.message : t('Saved')); await load()
  }
  const roleOptions = assignable.map((r) => <option key={r.key} value={r.key}>{lang === 'ar' ? r.name_ar : r.name_en}</option>)

  return (
    <section className="stack">
      <div className="card table-wrap"><table className="list">
        <thead><tr><th>{t('Name')}</th><th>{t('Role')}</th><th>{t('Branches')}</th><th>{t('Active')}</th>{s.has('appointments') && <th>{t('Takes bookings')}</th>}{s.has('own_delivery') && <th>{t('Driver')}</th>}{s.has('commissions') && <th>{t('Commission %')}</th>}</tr></thead>
        <tbody>{list.map((m) => (
          <tr key={m.user_id}><td>{m.display_name}</td>
            <td>{m.role === 'owner' ? s.roleName('owner', lang) : (
              <select id={`role-${m.user_id}`} value={m.role} onChange={(e) => void update(m, { role: e.target.value })}>{roleOptions}</select>)}</td>
            <td>{m.role === 'owner' ? t('All branches') : (
              <select id={`br-${m.user_id}`} value={m.branch_ids?.[0] ?? ''} onChange={(e) => void update(m, { branch_ids: e.target.value ? [e.target.value] : null })}>
                <option value="">{t('All branches')}</option>{s.branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select>)}</td>
            <td>{m.role !== 'owner' && <input id={`act-${m.user_id}`} type="checkbox" checked={m.is_active} onChange={(e) => void update(m, { is_active: e.target.checked })} />}</td>
            <StaffExtras m={m} onSaved={() => void load()} />
          </tr>))}</tbody>
      </table></div>
      <form className="card grid2" onSubmit={invite}>
        <h2 className="span2">{t('Invite staff')}</h2>
        <label className="field"><span>{t('E-mail')}</span><input id="inv-email" type="email" required value={inv.email} onChange={(e) => setInv({ ...inv, email: e.target.value })} /></label>
        <label className="field"><span>{t('Name')}</span><input id="inv-name" required value={inv.display_name} onChange={(e) => setInv({ ...inv, display_name: e.target.value })} /></label>
        <label className="field"><span>{t('Role')}</span><select id="inv-role" value={inv.role} onChange={(e) => setInv({ ...inv, role: e.target.value })}>{roleOptions}</select></label>
        <div className="row end"><button className="primary">{t('Send invitation')}</button></div>
        {msg && <p className="muted span2">{msg}</p>}
      </form>
    </section>
  )
}

function Dashboards() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [layouts, setLayouts] = useState<Record<string, string[]>>({})
  useEffect(() => {
    void supabase.from('dashboard_layouts').select('*').eq('tenant_id', tn.id).then(({ data }) => {
      const m: Record<string, string[]> = {}; for (const r of data ?? []) m[r.role] = r.widgets; setLayouts(m)
    })
  }, [tn.id])
  async function toggle(role: string, w: string, on: boolean) {
    const cur = layouts[role] ?? layoutFor(role)
    const next = on ? [...cur, w] : cur.filter((x) => x !== w)
    setLayouts({ ...layouts, [role]: next })
    await supabase.from('dashboard_layouts').upsert({ tenant_id: tn.id, role, widgets: next })
  }
  return (
    <section className="card">
      <p className="muted">{t('Choose what each role sees on its dashboard. A widget never shows data the role is not allowed to read.')}</p>
      <div className="table-wrap"><table className="list matrix">
        <thead><tr><th>{t('Widget')}</th>{s.roles.map((r) => <th key={r.key}>{lang === 'ar' ? r.name_ar : r.name_en}</th>)}</tr></thead>
        <tbody>{WIDGETS.map((w) => (
          <tr key={w.id}><td>{t(w.label)}</td>{s.roles.map((r) => (
            <td key={r.key}><input id={`dw-${r.key}-${w.id}`} type="checkbox" aria-label={`${w.label} · ${r.name_en}`}
              checked={(layouts[r.key] ?? layoutFor(r.key)).includes(w.id)} onChange={(e) => void toggle(r.key, w.id, e.target.checked)} /></td>))}</tr>))}</tbody>
      </table></div>
    </section>
  )
}

/** Stations per branch and which product categories go to which station. */
function Kitchen() {
  const { t } = useT()
  const nameOf = useName()
  const s = useSession()
  const tn = s.tenant!
  const branch = s.branch!
  const [stations, setStations] = useState<Station[]>([])
  const [cats, setCats] = useState<Category[]>([])
  const [name, setName] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const load = useCallback(async () => {
    const [st, c] = await Promise.all([
      supabase.from('kitchen_stations').select('*').eq('branch_id', branch.id).order('sort'),
      supabase.from('categories').select('*').eq('tenant_id', tn.id).order('sort'),
    ])
    setStations((st.data ?? []) as Station[]); setCats((c.data ?? []) as Category[])
  }, [branch.id, tn.id])
  useEffect(() => { void load() }, [load])
  const upd = async (id: string, patch: Partial<Station>) => {
    if (patch.is_default) await supabase.from('kitchen_stations').update({ is_default: false }).eq('branch_id', branch.id)
    const r = await supabase.from('kitchen_stations').update(patch).eq('id', id); setMsg(r.error?.message ?? null); await load()
  }
  async function add(e: React.FormEvent) {
    e.preventDefault()
    const r = await supabase.from('kitchen_stations').insert({ tenant_id: tn.id, branch_id: branch.id, name: name.trim(), is_default: stations.length === 0 })
    setMsg(r.error?.message ?? null); setName(''); await load()
  }
  async function route(c: Category, station: string) {
    const r = await supabase.from('categories').update({ station_id: station || null }).eq('id', c.id); setMsg(r.error?.message ?? null); await load()
  }
  return (
    <section className="stack">
      <div className="card">
        <h2>{t('Stations')} · {nameOf(branch)}</h2>
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>{t('Output')}</th><th>{t('Printer IP (network)')}</th><th>{t('Paper')}</th><th>{t('Late after (min)')}</th><th>{t('Default')}</th><th>{t('Active')}</th></tr></thead>
          <tbody>{stations.map((x) => (
            <tr key={x.id}>
              <td><input id={`st-name-${x.id}`} defaultValue={x.name} onBlur={(e) => e.target.value.trim() && e.target.value !== x.name && void upd(x.id, { name: e.target.value.trim() })} /></td>
              <td><select id={`st-mode-${x.id}`} value={x.mode} onChange={(e) => void upd(x.id, { mode: e.target.value as Station['mode'] })}>
                <option value="kds">{t('Screen (KDS)')}</option><option value="printer">{t('Kitchen printer')}</option><option value="both">{t('Screen + printer')}</option></select></td>
              <td><input id={`st-ip-${x.id}`} className="ip-in" inputMode="decimal" placeholder="192.168.1.50" defaultValue={x.printer_ip ?? ''}
                onBlur={(e) => { const v = e.target.value.trim(); if (v !== (x.printer_ip ?? '')) void upd(x.id, { printer_ip: v || null }) }} /></td>
              <td><select id={`st-w-${x.id}`} value={x.printer_width ?? 80} onChange={(e) => void upd(x.id, { printer_width: Number(e.target.value) })}><option value={80}>80 mm</option><option value={58}>58 mm</option></select></td>
              <td><input id={`st-alert-${x.id}`} className="lim" inputMode="numeric" defaultValue={x.alert_minutes} onBlur={(e) => { const v = parseInt(e.target.value); if (v > 0) void upd(x.id, { alert_minutes: v }) }} /></td>
              <td><input id={`st-def-${x.id}`} type="radio" name="default-station" checked={x.is_default} onChange={() => void upd(x.id, { is_default: true })} /></td>
              <td><input id={`st-act-${x.id}`} type="checkbox" checked={x.is_active} onChange={(e) => void upd(x.id, { is_active: e.target.checked })} /></td>
            </tr>))}</tbody>
        </table></div>
        <form className="row" onSubmit={add}><input id="st-new" placeholder={t('New station, e.g. Grill, Bar, Pastry')} value={name} onChange={(e) => setName(e.target.value)} />
          <button className="primary" disabled={!name.trim()}>{t('Add')}</button></form>
      </div>
      <div className="card">
        <h2>{t('Routing by category')}</h2>
        <p className="muted small">{t('Items go to the station of their category. Categories without a station go to the default station.')}</p>
        <div className="table-wrap"><table className="list"><tbody>{cats.map((c) => (
          <tr key={c.id}><td>{nameOf(c)}</td><td>
            <select id={`route-${c.id}`} value={c.station_id ?? ''} onChange={(e) => void route(c, e.target.value)}>
              <option value="">{t('Default station')}</option>{stations.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
            </select></td></tr>))}</tbody></table></div>
      </div>
      <BranchHub />
      {msg && <p className="error">{msg}</p>}
    </section>
  )
}

/** Creates the token a Branch Hub uses; shows it once with the command to start the hub. */
function BranchHub() {
  const { t } = useT()
  const s = useSession()
  const [hubs, setHubs] = useState<Array<{ id: string; name: string; last_seen_at: string | null; version: string | null; is_active: boolean }>>([])
  const [name, setName] = useState('Counter PC')
  const [token, setToken] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => {
    const { data } = await supabase.from('hubs').select('id, name, last_seen_at, version, is_active').eq('branch_id', s.branch!.id).order('created_at')
    setHubs((data ?? []) as typeof hubs)
  }, [s.branch])
  useEffect(() => { void load() }, [load])
  const online = (h: { last_seen_at: string | null }) => h.last_seen_at && Date.now() - Date.parse(h.last_seen_at) < 3 * 60_000
  const cmd = token ? `SUPABASE_URL=${supabaseUrl} SUPABASE_ANON_KEY=<publishable key> HUB_TOKEN=${token} npx z-trust-hub` : ''
  return (
    <div className="card">
      <h2>{t('Branch hub (works without internet)')}</h2>
      <p className="muted small">{t('Install the hub on one always-on device in this branch (PC, mini-PC or Raspberry Pi). POS devices, kitchen screens and network printers on the same Wi-Fi keep exchanging orders when the internet is down, and the hub syncs everything to the cloud when it returns.')}</p>
      {hubs.length > 0 && <ul className="plain">{hubs.map((h) => (
        <li key={h.id} className="row between"><span><b>{h.name}</b> <span className="muted small">{h.version ? `v${h.version}` : ''}</span></span>
          <span className={`pill ${online(h) ? '' : 'warn'}`}>{online(h) ? t('Online') : h.last_seen_at ? `${t('Last seen')} ${new Date(h.last_seen_at).toLocaleString()}` : t('Not started yet')}</span></li>))}</ul>}
      {token ? (
        <div className="amber-note stack">
          <b>{t('Copy this token now. It is shown only once.')}</b>
          <code className="token">{token}</code>
          <span className="small">{t('Start the hub with:')}</span><code className="token">{cmd}</code>
          <span className="small">{t('Then open the address it prints on every POS and kitchen tablet, and enter the pairing code it shows once on each device.')}</span>
          <button onClick={() => { navigator.clipboard?.writeText(token).catch(() => undefined) }}>{t('Copy token')}</button>
        </div>
      ) : (
        <form className="row" onSubmit={async (e) => { e.preventDefault(); setErr(null); try { setToken(await rpc<string>('create_hub', { p_branch: s.branch!.id, p_name: name })); await load() } catch (x) { setErr((x as Error).message) } }}>
          <input id="hub-name" value={name} onChange={(e) => setName(e.target.value)} />
          <button className="primary">{t('Create hub token')}</button>
        </form>
      )}
      {err && <p className="error">{err}</p>}
    </div>
  )
}

function Business() {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const st = tn.settings ?? {}
  const [f, setF] = useState({ name: tn.name, name_ar: tn.name_ar ?? '', tax_number: tn.tax_number ?? '', brand_color: tn.brand_color ?? '#2346D8' })
  const [r, setR] = useState({
    pos_show_images: Boolean(st.pos_show_images), receipt_address: st.receipt_address ?? '', receipt_phones: st.receipt_phones ?? '',
    receipt_cr: st.receipt_cr ?? '', receipt_website: st.receipt_website ?? '', receipt_header: st.receipt_header ?? '',
    receipt_terms: st.receipt_terms ?? '', receipt_footer: st.receipt_footer ?? '',
    logo_show: st.logo_show ?? true, logo_size: st.logo_size ?? 's', receipt_font: st.receipt_font ?? 'plex-mono', receipt_font_size: st.receipt_font_size ?? 'm',
    receipt_langs: st.receipt_langs ?? 'both',
  })
  const [logo, setLogo] = useState({ url: tn.logo_url, mono: st.logo_mono_url ?? null as string | null })
  const [logoBusy, setLogoBusy] = useState(false)
  async function uploadLogo(file: File) {
    setLogoBusy(true); setMsg(null)
    try {
      const { color, mono } = await prepareLogo(file)
      const stamp = Date.now()
      const up = async (name: string, blob: Blob) => {
        const path = `${tn.id}/${name}-${stamp}.png`
        const { error } = await supabase.storage.from('branding').upload(path, blob, { contentType: 'image/png', cacheControl: '31536000' })
        if (error) throw error
        return supabase.storage.from('branding').getPublicUrl(path).data.publicUrl
      }
      const next = { url: await up('logo', color), mono: await up('logo-mono', mono) }
      const { error } = await supabase.from('tenants').update({ logo_url: next.url, settings: { ...st, ...r, logo_mono_url: next.mono } }).eq('id', tn.id)
      if (error) throw error
      setLogo(next); setMsg(t('Logo saved')); await s.reload()
    } catch (x) { setMsg(t((x as Error).message)) } finally { setLogoBusy(false) }
  }
  async function removeLogo() {
    const { error } = await supabase.from('tenants').update({ logo_url: null, settings: { ...st, ...r, logo_mono_url: null } }).eq('id', tn.id)
    if (!error) { setLogo({ url: null, mono: null }); await s.reload() }
    setMsg(error ? error.message : t('Logo removed'))
  }
  const [msg, setMsg] = useState<string | null>(null)
  async function save() {
    const { error } = await supabase.from('tenants').update({ name: f.name, name_ar: f.name_ar || null, tax_number: f.tax_number || null, brand_color: f.brand_color,
      settings: { ...st, ...r } }).eq('id', tn.id)
    setMsg(error ? error.message : t('Saved')); if (!error) await s.reload()
  }
  const preview: ReceiptData = { number: 'B01-INV-000123', doc_type: 'invoice', created_at: new Date().toISOString(), lines: [{ name: 'Spanish Latte', qty: 2, line_total: 3500 }],
    subtotal: 3500, tax_total: 0, total: 3500, discount_total: 0, payments: [{ tender: 'cash', amount: 3500 }] }
  return (
    <section className="stack">
      <div className="card grid2">
        <h2 className="span2">{t('Business')}</h2>
        <label className="field"><span>{t('Business name (English)')}</span><input id="b-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>{t('Business name (Arabic)')}</span><input id="b-name-ar" dir="rtl" value={f.name_ar} onChange={(e) => setF({ ...f, name_ar: e.target.value })} /></label>
        <label className="field"><span>{t('VAT / tax number (optional)')}</span><input id="b-tax" value={f.tax_number} onChange={(e) => setF({ ...f, tax_number: e.target.value })} /></label>
        <label className="field"><span>{t('Brand colour')}</span><input id="b-color" type="color" value={f.brand_color} onChange={(e) => setF({ ...f, brand_color: e.target.value })} /></label>
        <label className="check span2"><input id="b-images" type="checkbox" checked={r.pos_show_images} onChange={(e) => setR({ ...r, pos_show_images: e.target.checked })} />{t('Show product photos on the POS (items without a photo show their initial)')}</label>
        <p className="muted span2">{t('Country')}: {tn.country_code} · {tn.currency} · {t('VAT')} {tn.vat_rate}% · {tn.prices_include_tax ? t('Prices include VAT') : t('VAT added at checkout')}</p>
      </div>
      <div className="receipt-settings">
        <div className="card grid2">
          <h2 className="span2">{t('Receipt and invoice')}</h2>
          <div className="span2 logo-field">
            <div className="logo-box">{logo.url ? <img src={logo.url} alt={t('Shop logo')} /> : <span className="muted small">{t('No logo')}</span>}</div>
            <div className="stack">
              <div className="row wrap">
                <label className={`button ${logoBusy ? 'disabled' : ''}`}>{logoBusy ? t('Please wait…') : logo.url ? t('Replace logo') : t('Upload logo')}
                  <input id="logo-file" type="file" accept="image/*" hidden disabled={logoBusy}
                    onChange={(e) => { const f = e.target.files?.[0]; if (f) void uploadLogo(f); e.target.value = '' }} /></label>
                {logo.url && <button type="button" className="ghost" onClick={() => void removeLogo()}>{t('Remove')}</button>}
              </div>
              <label className="check"><input id="logo-show" type="checkbox" checked={r.logo_show} onChange={(e) => setR({ ...r, logo_show: e.target.checked })} />{t('Print the logo on receipts')}</label>
              <div className="seg" role="group" aria-label={t('Logo size')}>{(['s', 'm', 'l'] as const).map((k) => (
                <button type="button" key={k} className={r.logo_size === k ? 'on' : ''} onClick={() => setR({ ...r, logo_size: k })}>{t({ s: 'Small', m: 'Medium', l: 'Large' }[k])}</button>))}</div>
              <p className="muted small">{t('Any photo or logo file (PNG, JPG, WebP, SVG). A black-and-white copy is made for thermal printers, which cannot print grey.')}</p>
            </div>
          </div>
          <label className="field"><span>{t('Phone numbers')}</span><input id="r-phones" value={r.receipt_phones} onChange={(e) => setR({ ...r, receipt_phones: e.target.value })} placeholder="+965 2222 0000 · WhatsApp 5555 0000" /></label>
          <label className="field"><span>{t('Commercial registration (CR)')}</span><input id="r-cr" value={r.receipt_cr} onChange={(e) => setR({ ...r, receipt_cr: e.target.value })} /></label>
          <label className="field span2"><span>{t('Address')}</span><textarea id="r-address" rows={2} value={r.receipt_address} onChange={(e) => setR({ ...r, receipt_address: e.target.value })} /></label>
          <label className="field"><span>{t('Website / Instagram')}</span><input id="r-web" value={r.receipt_website} onChange={(e) => setR({ ...r, receipt_website: e.target.value })} placeholder="@yourshop" /></label>
          <label className="field"><span>{t('Extra header line')}</span><input id="r-header" value={r.receipt_header} onChange={(e) => setR({ ...r, receipt_header: e.target.value })} placeholder={t('e.g. Open daily 7 am – 1 am')} /></label>
          <label className="field span2"><span>{t('Terms and conditions (printed at the bottom)')}</span><textarea id="r-terms" rows={4} value={r.receipt_terms} onChange={(e) => setR({ ...r, receipt_terms: e.target.value })}
            placeholder={t('e.g. Exchange within 7 days with the receipt. No refund on food items.')} /></label>
          <label className="field"><span>{t('Receipt font')}</span><select id="r-font" value={r.receipt_font} onChange={(e) => setR({ ...r, receipt_font: e.target.value })}>
            {RECEIPT_FONTS.map((f) => <option key={f.key} value={f.key} style={{ fontFamily: f.stack }}>{f.label}</option>)}</select></label>
          <label className="field"><span>{t('Text size')}</span><select id="r-font-size" value={r.receipt_font_size} onChange={(e) => setR({ ...r, receipt_font_size: e.target.value as 's' | 'm' | 'l' })}>
            <option value="s">{t('Small')}</option><option value="m">{t('Medium')}</option><option value="l">{t('Large')}</option></select></label>
          <label className="field"><span>{t('Receipt languages')}</span><select id="r-langs" value={r.receipt_langs} onChange={(e) => setR({ ...r, receipt_langs: e.target.value as 'both' | 'en' | 'ar' })}>
            <option value="both">{t('English and Arabic')}</option><option value="en">English</option><option value="ar">العربية</option></select></label>
          <label className="field span2"><span>{t('Closing message')}</span><input id="r-footer" value={r.receipt_footer} onChange={(e) => setR({ ...r, receipt_footer: e.target.value })} placeholder="شكراً لزيارتكم · Thank you" /></label>
          <div className="row end span2">{msg && <span className="muted">{msg}</span>}<button className="primary" onClick={save}>{t('Save')}</button></div>
        </div>
        <div className="card receipt-live"><h2>{t('Preview')}</h2><div className="receipt-preview"><Receipt data={preview} tenant={{ ...tn, name: f.name, name_ar: f.name_ar || null, tax_number: f.tax_number || null, logo_url: logo.url, settings: { ...st, ...r, logo_mono_url: logo.mono ?? undefined } }} branch={s.branch} /></div></div>
      </div>
      <ModuleSettings />
      {(s.role === 'owner' || s.can('settings.manage')) && <RulesSettings />}
    </section>
  )
}

/** Delivery platforms: orders arrive by webhook (via the platform or an integration partner) or are keyed at the POS. */
function Delivery() {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const d = tn.currency_decimals
  const [rows, setRows] = useState<DeliveryChannel[]>([])
  const [f, setF] = useState({ platform: 'keeta', display_name: 'Keeta', commission_pct: '18', store_ref: '' })
  const [token, setToken] = useState<{ id: string; token: string } | null>(null)
  const [settle, setSettle] = useState<DeliveryChannel | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const load = useCallback(async () => {
    const { data } = await supabase.from('delivery_channels').select('*').eq('branch_id', s.branch!.id).order('display_name'); setRows((data ?? []) as DeliveryChannel[])
  }, [s.branch])
  useEffect(() => { void load() }, [load])
  async function add(e: React.FormEvent) {
    e.preventDefault(); setMsg(null)
    const r = await supabase.from('delivery_channels').insert({ tenant_id: tn.id, branch_id: s.branch!.id, platform: f.platform, display_name: f.display_name.trim(),
      commission_pct: Number(f.commission_pct) || 0, store_ref: f.store_ref.trim() || null })
    setMsg(r.error ? r.error.message : null); await load()
  }
  const upd = async (id: string, patch: Partial<DeliveryChannel>) => { const r = await supabase.from('delivery_channels').update(patch).eq('id', id); setMsg(r.error?.message ?? null); await load() }
  const endpoint = `${supabaseUrl}/functions/v1/delivery-webhook`
  return (
    <section className="stack">
      <div className="card">
        <h2>{t('Delivery platforms')}</h2>
        <p className="muted small">{t('Each platform gets its own receivable: orders post to it, and the platform payout clears it with the commission booked as an expense. Orders can arrive automatically by webhook or be keyed at the POS with the platform as the payment method.')}</p>
        {rows.length > 0 && (
          <div className="table-wrap"><table className="list">
            <thead><tr><th>{t('Platform')}</th><th>{t('Store ID on platform')}</th><th className="num">{t('Commission %')}</th><th className="num">{t('Prep minutes')}</th><th>{t('Webhook')}</th><th>{t('Active')}</th><th /></tr></thead>
            <tbody>{rows.map((c) => (
              <tr key={c.id}><td><span className={`plat plat-${c.platform}`}>{c.display_name}</span></td>
                <td><input id={`dc-ref-${c.id}`} className="ip-in" defaultValue={c.store_ref ?? ''} onBlur={(e) => e.target.value !== (c.store_ref ?? '') && void upd(c.id, { store_ref: e.target.value || null })} /></td>
                <td className="num"><input id={`dc-com-${c.id}`} className="lim" inputMode="decimal" defaultValue={c.commission_pct} onBlur={(e) => void upd(c.id, { commission_pct: Number(e.target.value) || 0 })} /></td>
                <td className="num"><input id={`dc-prep-${c.id}`} className="lim" inputMode="numeric" defaultValue={c.prep_minutes} onBlur={(e) => void upd(c.id, { prep_minutes: Number(e.target.value) || 15 })} /></td>
                <td>{c.webhook_token_hash ? <span className="pill">{t('Connected')}</span> : <span className="pill warn">{t('Manual entry')}</span>}
                  <button className="ghost small" onClick={async () => setToken({ id: c.id, token: await rpc<string>('rotate_channel_token', { p_channel: c.id }) })}>{c.webhook_token_hash ? t('New token') : t('Connect webhook')}</button></td>
                <td><input id={`dc-act-${c.id}`} type="checkbox" checked={c.is_active} onChange={(e) => void upd(c.id, { is_active: e.target.checked })} /></td>
                <td>{s.can('payments.receive') && <button className="small" onClick={() => setSettle(c)}>{t('Record payout')}</button>}</td></tr>))}</tbody>
          </table></div>)}
        {token && (
          <div className="amber-note stack">
            <b>{t('Copy this token now. It is shown only once.')}</b>
            <span className="small">{t('Webhook URL')}</span><code className="token">{endpoint}?platform={rows.find((x) => x.id === token.id)?.platform}</code>
            <span className="small">{t('Header')}: <code>x-channel-token</code></span><code className="token">{token.token}</code>
            <span className="small">{t('Give both to the platform (or your integration partner). New orders then appear on the POS sales list and the kitchen screen automatically.')}</span>
          </div>)}
        <form className="row wrap" onSubmit={add}>
          <select id="dc-platform" value={f.platform} onChange={(e) => { const p = PLATFORMS.find((x) => x.id === e.target.value)!; setF({ ...f, platform: p.id, display_name: p.name }) }}>
            {PLATFORMS.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select>
          <input id="dc-name" value={f.display_name} onChange={(e) => setF({ ...f, display_name: e.target.value })} />
          <input id="dc-commission" className="lim" inputMode="decimal" value={f.commission_pct} onChange={(e) => setF({ ...f, commission_pct: e.target.value })} aria-label={t('Commission %')} />
          <button className="primary">{t('Add platform')}</button>
        </form>
        {msg && <p className="error">{msg}</p>}
      </div>
      {settle && <SettleForm channel={settle} decimals={d} onClose={() => setSettle(null)} />}
    </section>
  )
}

const PLATFORMS = [
  { id: 'keeta', name: 'Keeta' }, { id: 'talabat', name: 'Talabat' }, { id: 'jahez', name: 'Jahez' }, { id: 'hungerstation', name: 'HungerStation' },
  { id: 'deliveroo', name: 'Deliveroo' }, { id: 'careem', name: 'Careem' }, { id: 'noon_food', name: 'Noon Food' }, { id: 'mrsool', name: 'Mrsool' },
  { id: 'toyou', name: 'ToYou' }, { id: 'other', name: 'Other' },
]

function SettleForm({ channel, decimals, onClose }: { channel: DeliveryChannel; decimals: number; onClose: () => void }) {
  const { t } = useT()
  const [f, setF] = useState({ gross: '', commission: '', reference: '' })
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState(false)
  const g = toMinor(f.gross || '0', decimals), c = f.commission ? toMinor(f.commission, decimals) : Math.round(g * Number(channel.commission_pct) / 100)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try { await rpc('record_platform_settlement', { p: { channel_id: channel.id, gross: g, commission: c, reference: f.reference } }); setDone(true) } catch (x) { setErr((x as Error).message) }
  }
  return (
    <Modal title={`${t('Record payout')} · ${channel.display_name}`} onClose={onClose}>
      {done ? <div className="stack"><p className="success">{t('Payout recorded: bank, commission and platform receivable posted to the ledger.')}</p><button className="primary" onClick={onClose}>{t('Close')}</button></div> : (
        <form className="stack" onSubmit={save}>
          <label className="field"><span>{t('Gross sales in the statement')}</span><input id="st-gross" inputMode="decimal" required value={f.gross} onChange={(e) => setF({ ...f, gross: e.target.value })} /></label>
          <label className="field"><span>{t('Commission and fees')} ({channel.commission_pct}% = {num(Math.round(g * Number(channel.commission_pct) / 100), decimals)})</span>
            <input id="st-comm" inputMode="decimal" value={f.commission} placeholder={num(Math.round(g * Number(channel.commission_pct) / 100), decimals)} onChange={(e) => setF({ ...f, commission: e.target.value })} /></label>
          <p className="muted">{t('Net to bank')}: <b>{num(g - c, decimals)}</b></p>
          <label className="field"><span>{t('Statement / transfer reference')}</span><input id="st-ref" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></label>
          {err && <p className="error">{err}</p>}
          <div className="row end"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!g}>{t('Save')}</button></div>
        </form>)}
    </Modal>
  )
}

function Device() {
  const { t } = useT()
  const s = useSession()
  const [pin, setPin] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const [paper, setPaper] = useState(() => { try { return localStorage.getItem('zt.paper') || '80' } catch { return '80' } })
  return (
    <section className="card grid2">
      <form className="stack" onSubmit={async (e) => { e.preventDefault(); try { await rpc('set_my_pin', { p_tenant: s.tenant!.id, p_pin: pin }); setMsg(t('PIN updated')); setPin('') } catch (x) { setMsg((x as Error).message) } }}>
        <label className="field"><span>{t('My approval PIN (4–6 digits)')}</span><input id="my-pin" type="password" inputMode="numeric" maxLength={6} value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))} /></label>
        <button className="primary" disabled={pin.length < 4}>{t('Save PIN')}</button>
      </form>
      <HubPairing />
      <label className="field"><span>{t('Receipt paper width')}</span>
        <select id="paper" value={paper} onChange={(e) => { setPaper(e.target.value); try { localStorage.setItem('zt.paper', e.target.value) } catch { /* ignore */ } }}>
          <option value="80">80 mm</option><option value="58">58 mm</option><option value="a4">A4</option></select></label>
      {msg && <p className="muted span2">{msg}</p>}
    </section>
  )
}


function HubPairing() {
  const { t } = useT()
  const hub = useHub()
  const cur = hubSettings()
  const [url, setUrl] = useState(cur.url ?? '')
  const [code, setCode] = useState(cur.code ?? '')
  useEffect(() => { if (!url) void detectHub().then((u) => { if (u) setUrl(u) }) }, [url])
  return (
    <form className="stack span2 card" onSubmit={(e) => { e.preventDefault(); configureHub(url.trim() || null, code.trim() || null) }}>
      <h2>{t('Branch hub on this device')}</h2>
      <div className="grid2">
        <label className="field"><span>{t('Hub address')}</span><input id="hub-url" placeholder="http://192.168.1.20:8787" value={url} onChange={(e) => setUrl(e.target.value)} /></label>
        <label className="field"><span>{t('Pairing code')}</span><input id="hub-code" inputMode="numeric" maxLength={6} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} /></label>
      </div>
      <div className="row between wrap">
        <span className={`hub-badge ${hub.status}`}>{hub.status === 'connected' ? t('Connected to the hub') : hub.status === 'error' && hub.error === 'pairing_code' ? t('Wrong or missing pairing code') : hub.status === 'connecting' ? t('Connecting…') : t('Not using a hub')}</span>
        <div className="row"><button type="button" className="ghost" onClick={() => { setUrl(''); setCode(''); configureHub(null, null) }}>{t('Stop using hub')}</button><button className="primary">{t('Connect')}</button></div>
      </div>
    </form>
  )
}

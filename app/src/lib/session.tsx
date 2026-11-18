import type { Session } from '@supabase/supabase-js'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { supabase } from './supabase'
import type { Branch, Membership, Role, RolePkg, Tenant } from './types'

interface SessionCtx {
  session: Session | null
  loading: boolean
  memberships: Membership[]
  tenant: Tenant | null
  member: Membership | null
  role: Role | null
  branches: Branch[]
  branch: Branch | null
  perms: Record<string, number | null>
  roles: RolePkg[]
  roleName: (key: string | null | undefined, lang: string) => string
  can: (perm: string) => boolean
  /** module switched on for this business (Settings → Business type & modules) */
  has: (feature: string) => boolean
  limit: (perm: string) => number | null
  selectTenant: (id: string) => void
  selectBranch: (id: string) => void
  reload: () => Promise<void>
  signOut: () => Promise<void>
}

const Ctx = createContext<SessionCtx | null>(null)
const store = {
  get: (k: string) => { try { return localStorage.getItem(k) } catch { return null } },
  set: (k: string, v: string) => { try { localStorage.setItem(k, v) } catch { /* ignore */ } },
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)
  const [memberships, setMemberships] = useState<Membership[]>([])
  const [tenantId, setTenantId] = useState<string | null>(store.get('zt.tenant'))
  const [branches, setBranches] = useState<Branch[]>([])
  const [branchId, setBranchId] = useState<string | null>(store.get('zt.branch'))
  const [perms, setPerms] = useState<Record<string, number | null>>({})
  const [roles, setRoles] = useState<RolePkg[]>([])
  const loadedOnce = useRef(false)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); if (!data.session) setLoading(false) })
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => data.subscription.unsubscribe()
  }, [])

  const load = useCallback(async () => {
    if (!session) { setMemberships([]); return }
    // only the first load shows the splash; later reloads refresh in place so open screens keep their state
    if (!loadedOnce.current) setLoading(true)
    const { data: ms, error: msErr } = await supabase.from('memberships').select('*, tenants(*)').eq('user_id', session.user.id).eq('is_active', true)
    // internet down while the shop Wi-Fi is up: keep working from the last known context
    if (msErr) {
      try {
        const c = JSON.parse(localStorage.getItem(`zt.ctx.${session.user.id}`) ?? 'null')
        if (c) { setMemberships(c.memberships); setTenantId(c.tenantId); setBranches(c.branches); setBranchId((cur) => cur ?? c.branches[0]?.id ?? null); setPerms(c.perms); setRoles(c.roles) }
      } catch { /* no cache */ }
      loadedOnce.current = true; setLoading(false); return
    }
    const list = (ms ?? []) as Membership[]
    setMemberships(list)
    const tid = list.find((m) => m.tenant_id === tenantId)?.tenant_id ?? list[0]?.tenant_id ?? null
    setTenantId(tid)
    if (tid) {
      store.set('zt.tenant', tid)
      const me = list.find((m) => m.tenant_id === tid)!
      const [{ data: br }, { data: rp }, { data: rl }] = await Promise.all([
        supabase.from('branches').select('*').eq('tenant_id', tid).eq('is_active', true).order('code'),
        supabase.from('role_permissions').select('permission, limit_value').eq('tenant_id', tid).eq('role', me.role),
        supabase.from('roles').select('*').eq('tenant_id', tid).order('sort'),
      ])
      setRoles((rl ?? []) as RolePkg[])
      const bl = (br ?? []) as Branch[]
      setBranches(bl)
      setBranchId((cur) => (bl.some((b) => b.id === cur) ? cur : bl[0]?.id ?? null))
      const p: Record<string, number | null> = {}
      for (const r of rp ?? []) p[r.permission as string] = r.limit_value as number | null
      setPerms(p)
      try { localStorage.setItem(`zt.ctx.${session.user.id}`, JSON.stringify({ memberships: list, tenantId: tid, branches: bl, perms: p, roles: rl ?? [] })) } catch { /* ignore */ }
    }
    loadedOnce.current = true
    setLoading(false)
  }, [session, tenantId])

  useEffect(() => { void load() }, [load])
  useEffect(() => { if (branchId) store.set('zt.branch', branchId) }, [branchId])

  const member = memberships.find((m) => m.tenant_id === tenantId) ?? null
  const role = member?.role ?? null
  const value = useMemo<SessionCtx>(() => ({
    session, loading, memberships,
    tenant: member?.tenants ?? null, member, role,
    branches, branch: branches.find((b) => b.id === branchId) ?? null,
    perms, roles,
    roleName: (key, lang) => { const r = roles.find((x) => x.key === key); return r ? (lang === 'ar' ? r.name_ar : r.name_en) : key ?? '' },
    can: (p) => role === 'owner' || p in perms,
    has: (f) => Boolean(member?.tenants?.features?.[f]),
    limit: (p) => (role === 'owner' ? null : perms[p] ?? null),
    selectTenant: (id) => { store.set('zt.tenant', id); setTenantId(id) },
    selectBranch: (id) => setBranchId(id),
    reload: load,
    signOut: async () => { await supabase.auth.signOut(); setMemberships([]) },
  }), [session, loading, memberships, member, role, branches, branchId, perms, roles, load])

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useSession() {
  const c = useContext(Ctx)
  if (!c) throw new Error('SessionProvider missing')
  return c
}

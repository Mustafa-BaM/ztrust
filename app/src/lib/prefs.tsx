import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useSession } from './session'
import { supabase } from './supabase'

export type ThemeKey = 'auto' | 'executive' | 'emerald' | 'pearl' | 'obsidian'
export const THEMES: { key: ThemeKey; name: string; hint: string; swatch: string[] }[] = [
  { key: 'auto', name: 'Automatic', hint: 'Executive by day, Obsidian when the device is in dark mode', swatch: ['#F1F3F7', '#0F1E3D', '#1E4FD8', '#0A0E16'] },
  { key: 'executive', name: 'Executive Navy & Slate', hint: 'Precise corners, navy and steel grey: finance and management', swatch: ['#F1F3F7', '#0F1E3D', '#1E4FD8', '#E9A23B'] },
  { key: 'emerald', name: 'Modern Emerald & Glass', hint: 'Rounded, frosted surfaces: retail and cafés', swatch: ['#E9F4F0', '#053D31', '#047857', '#5EEAD4'] },
  { key: 'pearl', name: 'Minimalist Pearl & Warm Gold', hint: 'White space and soft gold: clinics, salons, spas', swatch: ['#FAF8F3', '#FFFFFF', '#8A6520', '#0F766E'] },
  { key: 'obsidian', name: 'Obsidian Pro Dark', hint: 'Calm dark for long shifts, bright actions and figures', swatch: ['#0A0E16', '#111723', '#5B9BFF', '#F5B83D'] },
]

export interface DashLayout { order: string[]; hidden: string[]; range?: string }
export interface Prefs { theme?: ThemeKey; sidebar?: 'open' | 'closed'; dashboard?: DashLayout; updated?: number }

const KEY = 'zt.prefs'
const readLocal = (): Prefs => { try { return JSON.parse(localStorage.getItem(KEY) ?? '{}') as Prefs } catch { return {} } }
const writeLocal = (p: Prefs) => { try { localStorage.setItem(KEY, JSON.stringify(p)) } catch { /* ignore */ } }
/** applied before React renders, so the first paint already has the user's theme */
export function applyThemeEarly() { document.documentElement.dataset.theme = readLocal().theme ?? 'auto' }

interface Ctx { prefs: Prefs; set: (patch: Partial<Prefs>) => void }
const PrefsCtx = createContext<Ctx | null>(null)

/** Theme, sidebar and dashboard layout: instant on this device, and saved to the user's account so they follow them. */
export function PrefsProvider({ children }: { children: ReactNode }) {
  const s = useSession()
  const [prefs, setPrefs] = useState<Prefs>(readLocal)
  const loaded = useRef<string | null>(null)
  const timer = useRef<number | undefined>(undefined)
  const uid = s.session?.user.id, tid = s.tenant?.id

  useEffect(() => { document.documentElement.dataset.theme = prefs.theme ?? 'auto' }, [prefs.theme])

  // the account's saved preferences win over this device's when they are newer
  useEffect(() => {
    if (!uid || !tid || loaded.current === `${uid}:${tid}`) return
    loaded.current = `${uid}:${tid}`
    void supabase.from('user_prefs').select('prefs').eq('user_id', uid).eq('tenant_id', tid).maybeSingle().then(({ data }) => {
      const remote = (data?.prefs ?? null) as Prefs | null
      if (remote && (remote.updated ?? 0) > (readLocal().updated ?? 0)) { setPrefs(remote); writeLocal(remote) }
    })
  }, [uid, tid])

  const set = useCallback((patch: Partial<Prefs>) => {
    setPrefs((cur) => {
      const next = { ...cur, ...patch, updated: Date.now() }
      writeLocal(next)
      window.clearTimeout(timer.current)
      if (uid && tid) timer.current = window.setTimeout(() => { void supabase.from('user_prefs').upsert({ user_id: uid, tenant_id: tid, prefs: next, updated_at: new Date().toISOString() }) }, 600)
      return next
    })
  }, [uid, tid])

  const value = useMemo(() => ({ prefs, set }), [prefs, set])
  return <PrefsCtx.Provider value={value}>{children}</PrefsCtx.Provider>
}

export function usePrefs() {
  const c = useContext(PrefsCtx)
  if (!c) throw new Error('PrefsProvider missing')
  return c
}

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { ar } from './ar'

export type Lang = 'en' | 'ar'
type Ctx = { lang: Lang; dir: 'ltr' | 'rtl'; setLang: (l: Lang) => void; t: (s: string, vars?: Record<string, string | number>) => string }

const LangCtx = createContext<Ctx | null>(null)
const read = (): Lang => { try { return (localStorage.getItem('zt.lang') as Lang) || 'en' } catch { return 'en' } }

/** English text is the key; Arabic comes from the dictionary and falls back to English when a string is missing. */
export function LangProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(read)
  const dir = lang === 'ar' ? 'rtl' : 'ltr'
  useEffect(() => {
    document.documentElement.lang = lang
    document.documentElement.dir = dir
  }, [lang, dir])
  const setLang = useCallback((l: Lang) => { setLangState(l); try { localStorage.setItem('zt.lang', l) } catch { /* private mode */ } }, [])
  const t = useCallback((s: string, vars?: Record<string, string | number>) => {
    let out = lang === 'ar' ? ar[s] ?? s : s
    if (vars) for (const [k, v] of Object.entries(vars)) out = out.replaceAll(`{${k}}`, String(v))
    return out
  }, [lang])
  const value = useMemo(() => ({ lang, dir: dir as 'ltr' | 'rtl', setLang, t }), [lang, dir, setLang, t])
  return <LangCtx.Provider value={value}>{children}</LangCtx.Provider>
}

export function useT() {
  const c = useContext(LangCtx)
  if (!c) throw new Error('LangProvider missing')
  return c
}

/** Picks the Arabic or English name of a record. */
export function useName() {
  const { lang } = useT()
  return (r: { name: string; name_ar?: string | null } | null | undefined) => (r ? (lang === 'ar' && r.name_ar ? r.name_ar : r.name) : '')
}

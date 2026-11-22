import { Check, Palette } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { useT } from '../lib/i18n'
import { THEMES, usePrefs } from '../lib/prefs'

/** Live theme switcher: the whole app changes as you hover/choose; the choice is saved for this user. */
export function ThemePicker({ inline = false }: { inline?: boolean }) {
  const { t } = useT()
  const { prefs, set } = usePrefs()
  const [open, setOpen] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  const current = prefs.theme ?? 'auto'
  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false) }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', close); document.addEventListener('keydown', esc)
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc) }
  }, [open])
  const list = (
    <div className={inline ? 'theme-list inline' : 'theme-list'} role="radiogroup" aria-label={t('Theme')}>
      {THEMES.map((th) => (
        <button key={th.key} role="radio" aria-checked={current === th.key} className={`theme-opt ${current === th.key ? 'on' : ''}`} onClick={() => { set({ theme: th.key }); if (!inline) setOpen(false) }}>
          <span className="swatch" aria-hidden="true">{th.swatch.map((c) => <i key={c} style={{ background: c }} />)}</span>
          <span className="theme-txt"><b>{t(th.name)}</b><small>{t(th.hint)}</small></span>
          {current === th.key && <Check size={16} aria-hidden="true" />}
        </button>))}
    </div>
  )
  if (inline) return list
  return (
    <div className="theme-picker" ref={box}>
      <button className="icon tb-icon" aria-label={t('Theme')} aria-expanded={open} title={t('Theme')} onClick={() => setOpen(!open)}><Palette size={18} /></button>
      {open && <div className="popover">{list}</div>}
    </div>
  )
}

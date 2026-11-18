import { useState } from 'react'
import { Logo } from '../components/ui'
import { useT } from '../lib/i18n'
import { isConfigured, supabase } from '../lib/supabase'

export default function Login() {
  const { t, lang, setLang } = useT()
  const [mode, setMode] = useState<'signin' | 'signup'>('signin')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)

  async function submit(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setMsg(null)
    const r = mode === 'signin'
      ? await supabase.auth.signInWithPassword({ email, password })
      : await supabase.auth.signUp({ email, password, options: { emailRedirectTo: window.location.origin } })
    setBusy(false)
    if (r.error) setMsg({ ok: false, text: r.error.message })
    else if (mode === 'signup' && !r.data.session) setMsg({ ok: true, text: t('Check your e-mail to confirm your account, then sign in.') })
  }

  return (
    <div className="auth">
      <div className="auth-card">
        <div className="auth-brand"><Logo size={64} tile /><div><h1 className="wordmark">Z Trust</h1><span className="kufi">زد ترست</span></div></div>
        <p className="muted">{t('Every sale. Every shift. Trusted.')}</p>
        {!isConfigured && <p className="error">{t('Supabase is not configured. Copy .env.example to .env.local and add your project URL and anon key.')}</p>}
        <div className="tabs">
          <button className={mode === 'signin' ? 'on' : ''} onClick={() => setMode('signin')}>{t('Sign in')}</button>
          <button className={mode === 'signup' ? 'on' : ''} onClick={() => setMode('signup')}>{t('Start 7-day free trial')}</button>
        </div>
        <form className="stack" onSubmit={submit}>
          <label className="field"><span>{t('E-mail')}</span>
            <input id="login-email" type="email" required autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
          <label className="field"><span>{t('Password')}</span>
            <input id="login-password" type="password" required minLength={8} autoComplete={mode === 'signin' ? 'current-password' : 'new-password'}
                   value={password} onChange={(e) => setPassword(e.target.value)} /></label>
          {msg && <p className={msg.ok ? 'success' : 'error'}>{msg.text}</p>}
          <button className="primary big" disabled={busy}>{busy ? t('Please wait…') : mode === 'signin' ? t('Sign in') : t('Create account')}</button>
        </form>
        <button className="ghost small" onClick={() => setLang(lang === 'ar' ? 'en' : 'ar')}>{lang === 'ar' ? 'English' : 'العربية'}</button>
      </div>
    </div>
  )
}

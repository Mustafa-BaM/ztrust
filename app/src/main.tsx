import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { registerSW } from 'virtual:pwa-register'
import App from './App'
import { LangProvider } from './lib/i18n'
import { startHub } from './lib/hub'
import { flushOutbox } from './lib/offline'
import { SessionProvider } from './lib/session'
import './styles.css'
import './themes.css'
import { applyThemeEarly, PrefsProvider } from './lib/prefs'

applyThemeEarly()
registerSW({ immediate: true })
window.addEventListener('load', () => { void flushOutbox(); void startHub() })

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <LangProvider>
      <SessionProvider>
        <PrefsProvider>
          <BrowserRouter>
            <App />
          </BrowserRouter>
        </PrefsProvider>
      </SessionProvider>
    </LangProvider>
  </StrictMode>,
)

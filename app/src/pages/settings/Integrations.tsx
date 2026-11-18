import { Copy, KeyRound, Plus, Send, Trash2, Webhook } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Empty, Modal } from '../../components/ui'
import { useT } from '../../lib/i18n'
import { useSession } from '../../lib/session'
import { parseError, rpc, supabase } from '../../lib/supabase'

interface EventType { key: string; name_en: string; name_ar: string }
interface Endpoint { id: string; name: string; url: string; events: string[]; is_active: boolean; created_at: string; last_status: number | null; last_at: string | null; failures: number }
interface Delivery { id: number; event: string; status: string; attempts: number; response_code: number | null; last_error: string | null; created_at: string; sent_at: string | null; next_at: string }
interface ApiKey { id: string; name: string; prefix: string; scopes: string[]; created_at: string; last_used_at: string | null; revoked_at: string | null }

const SCOPES = ['items.read', 'stock.read', 'sales.read', 'customers.read'] as const
const SCOPE_LABEL: Record<string, string> = { 'items.read': 'Products', 'stock.read': 'Stock', 'sales.read': 'Sales', 'customers.read': 'Customers' }
const apiBase = `${(import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? 'http://localhost:54321'}/functions/v1/public-api/v1`

async function copy(text: string, el?: HTMLElement | null) {
  try { await navigator.clipboard.writeText(text) } catch {
    if (el) { const r = document.createRange(); r.selectNodeContents(el); const sel = window.getSelection(); sel?.removeAllRanges(); sel?.addRange(r) }
  }
}

/** Webhooks to n8n (or Make, Zapier, any HTTPS endpoint) and read-only API keys. */
export default function Integrations({ onOpenModules }: { onOpenModules: () => void }) {
  const { t } = useT()
  const s = useSession()
  if (!s.has('integrations')) {
    return (
      <section className="card">
        <h2>{t('Integrations are switched off')}</h2>
        <p className="muted">{t('Switch on “Integrations (webhooks & API)” to send events to n8n or any system, and to create API keys.')}</p>
        {s.role === 'owner' && <div><button className="primary" onClick={onOpenModules}>{t('Open modules')}</button></div>}
      </section>
    )
  }
  return <section className="stack"><Webhooks />{s.role === 'owner' && <ApiKeys />}<N8nGuide /></section>
}

function Webhooks() {
  const { t, lang } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [types, setTypes] = useState<EventType[]>([])
  const [list, setList] = useState<Endpoint[]>([])
  const [log, setLog] = useState<Delivery[]>([])
  const [sel, setSel] = useState<string | null>(null)
  const [adding, setAdding] = useState(false)
  const [secret, setSecret] = useState<string | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const nm = (x: EventType) => (lang === 'ar' ? x.name_ar : x.name_en)

  const load = useCallback(async () => {
    const [ty, ep] = await Promise.all([
      supabase.from('event_types').select('*').order('sort'),
      supabase.from('webhook_endpoints').select('id, name, url, events, is_active, created_at, last_status, last_at, failures').eq('tenant_id', tn.id).order('created_at'),
    ])
    setTypes((ty.data ?? []) as EventType[]); const eps = (ep.data ?? []) as Endpoint[]; setList(eps)
    setSel((cur) => cur && eps.some((e) => e.id === cur) ? cur : eps[0]?.id ?? null)
  }, [tn.id])
  useEffect(() => { void load() }, [load])
  const loadLog = useCallback(async () => {
    if (!sel) { setLog([]); return }
    const { data } = await supabase.from('event_outbox').select('id, event, status, attempts, response_code, last_error, created_at, sent_at, next_at').eq('endpoint_id', sel).order('id', { ascending: false }).limit(30)
    setLog((data ?? []) as Delivery[])
  }, [sel])
  useEffect(() => { void loadLog(); const id = window.setInterval(() => void loadLog(), 10_000); return () => clearInterval(id) }, [loadLog])

  const run = async (f: () => Promise<unknown>, ok: string) => {
    setMsg(null)
    try { await f(); setMsg({ ok: true, text: ok }); await load(); await loadLog() } catch (e) { const x = parseError(e); setMsg({ ok: false, text: x.kind === 'message' ? t(x.message) : t('Not allowed') }) }
  }

  return (
    <div className="card">
      <div className="row between wrap"><h2><Webhook size={18} aria-hidden="true" /> {t('Webhooks')}</h2>
        <button className="primary" onClick={() => setAdding(true)}><Plus size={16} />{t('Add webhook')}</button></div>
      <p className="muted small">{t('Z Trust sends each event as a signed POST request, and retries for about 15 hours if your system is down.')}</p>
      {msg && <p className={msg.ok ? 'success' : 'error'} role="status">{msg.text}</p>}
      {list.length === 0 ? <Empty title={t('No webhooks yet')} hint={t('Add the webhook URL from your n8n workflow to start receiving events.')} /> : (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>URL</th><th>{t('Events')}</th><th>{t('Last delivery')}</th><th>{t('Status')}</th><th /></tr></thead>
          <tbody>{list.map((e) => (
            <tr key={e.id} className={sel === e.id ? 'sel' : ''} onClick={() => setSel(e.id)}>
              <td><b>{e.name}</b></td><td className="small mono wrap-any">{e.url}</td>
              <td className="small">{e.events.map((k) => types.find((x) => x.key === k)).filter(Boolean).map((x) => nm(x!)).join(' · ')}</td>
              <td className="small">{e.last_at ? <>{e.last_status ?? '—'} · {new Date(e.last_at).toLocaleString()}</> : '—'}{e.failures > 0 && <span className="pill warn">{t('{n} failed in a row', { n: e.failures })}</span>}</td>
              <td><button role="switch" aria-checked={e.is_active} aria-label={t('Active')} className={`switch ${e.is_active ? 'on' : ''}`}
                onClick={(ev) => { ev.stopPropagation(); void run(() => rpc('save_webhook', { p_tenant: tn.id, p: { id: e.id, url: e.url, events: e.events, is_active: !e.is_active } }), e.is_active ? t('Webhook paused') : t('Webhook active')) }}><i /></button></td>
              <td><div className="row end nowrap">
                <button className="ghost small" onClick={(ev) => { ev.stopPropagation(); setSel(e.id); void run(() => rpc('test_webhook', { p_id: e.id }), t('Test event queued. It is sent within a minute.')) }}><Send size={14} />{t('Send test')}</button>
                <button className="ghost small danger" aria-label={t('Delete')} onClick={(ev) => { ev.stopPropagation(); void run(() => rpc('delete_webhook', { p_id: e.id }), t('Webhook deleted')) }}><Trash2 size={14} /></button>
              </div></td>
            </tr>))}</tbody>
        </table></div>)}

      {sel && (
        <>
          <h3>{t('Recent deliveries')}</h3>
          {log.length === 0 ? <p className="muted small">{t('Nothing sent yet.')}</p> : (
            <div className="table-wrap"><table className="list compact">
              <thead><tr><th>#</th><th>{t('Event')}</th><th>{t('Status')}</th><th className="num">{t('Tries')}</th><th>{t('Response')}</th><th>{t('Time')}</th></tr></thead>
              <tbody>{log.map((d) => (
                <tr key={d.id}><td className="mono small">{d.id}</td><td className="mono small">{d.event}</td>
                  <td><span className={`pill dl-${d.status}`}>{t({ pending: d.attempts ? 'Retrying' : 'Queued', sending: 'Sending', sent: 'Delivered', dead: 'Gave up' }[d.status] ?? d.status)}</span></td>
                  <td className="num">{d.attempts}</td><td className="small">{d.response_code ?? ''} {d.last_error && <span className="muted">{d.last_error}</span>}</td>
                  <td className="small">{new Date(d.sent_at ?? d.created_at).toLocaleString()}</td></tr>))}</tbody>
            </table></div>)}
        </>
      )}

      {adding && <AddWebhook types={types} onClose={() => setAdding(false)} onCreated={async (sec) => { setAdding(false); setSecret(sec); await load() }} />}
      {secret && (
        <Modal title={t('Signing secret')} onClose={() => setSecret(null)}>
          <div className="stack">
            <p>{t('Copy this secret now. It is shown only once. Your workflow uses it to check that requests really come from Z Trust.')}</p>
            <div className="linkbox"><code id="wh-secret">{secret}</code><button onClick={() => void copy(secret, document.getElementById('wh-secret'))}><Copy size={15} />{t('Copy')}</button></div>
            <div className="row end"><button className="primary" onClick={() => setSecret(null)}>{t('Done')}</button></div>
          </div>
        </Modal>
      )}
    </div>
  )
}

function AddWebhook({ types, onClose, onCreated }: { types: EventType[]; onClose: () => void; onCreated: (secret: string) => void }) {
  const { t, lang } = useT()
  const s = useSession()
  const [f, setF] = useState({ name: 'n8n', url: '', events: ['sale.completed'] as string[] })
  const [err, setErr] = useState<string | null>(null)
  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try { const r = await rpc<{ secret: string }>('save_webhook', { p_tenant: s.tenant!.id, p: f }); onCreated(r.secret) }
    catch (x) { const p = parseError(x); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) }
  }
  return (
    <Modal title={t('Add webhook')} onClose={onClose} wide>
      <form className="grid2" onSubmit={save}>
        <label className="field"><span>{t('Name')}</span><input id="wh-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>{t('Webhook URL')}</span><input id="wh-url" type="url" required placeholder="https://your-n8n.example/webhook/…" value={f.url} onChange={(e) => setF({ ...f, url: e.target.value })} /></label>
        <fieldset className="span2 events-pick"><legend>{t('Events to send')}</legend>
          {types.map((x) => (
            <label key={x.key} className="check"><input type="checkbox" checked={f.events.includes(x.key)}
              onChange={(e) => setF({ ...f, events: e.target.checked ? [...f.events, x.key] : f.events.filter((k) => k !== x.key) })} />
              {lang === 'ar' ? x.name_ar : x.name_en} <span className="muted small mono">{x.key}</span></label>))}
        </fieldset>
        {err && <p className="error span2">{err}</p>}
        <div className="row end span2"><button type="button" className="ghost" onClick={onClose}>{t('Cancel')}</button><button className="primary" disabled={!f.url || !f.events.length}>{t('Save webhook')}</button></div>
      </form>
    </Modal>
  )
}

function ApiKeys() {
  const { t } = useT()
  const s = useSession()
  const tn = s.tenant!
  const [keys, setKeys] = useState<ApiKey[]>([])
  const [name, setName] = useState('')
  const [scopes, setScopes] = useState<string[]>(['items.read', 'stock.read', 'sales.read'])
  const [created, setCreated] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const load = useCallback(async () => {
    const { data } = await supabase.from('api_keys').select('id, name, prefix, scopes, created_at, last_used_at, revoked_at').eq('tenant_id', tn.id).order('created_at', { ascending: false })
    setKeys((data ?? []) as ApiKey[])
  }, [tn.id])
  useEffect(() => { void load() }, [load])
  async function create(e: React.FormEvent) {
    e.preventDefault(); setErr(null)
    try { const r = await rpc<{ key: string }>('create_api_key', { p_tenant: tn.id, p_name: name || 'API key', p_scopes: scopes }); setCreated(r.key); setName(''); await load() }
    catch (x) { const p = parseError(x); setErr(p.kind === 'message' ? t(p.message) : t('Not allowed')) }
  }
  return (
    <div className="card">
      <h2><KeyRound size={18} aria-hidden="true" /> {t('API keys')}</h2>
      <p className="muted small">{t('Read-only access for n8n, Power BI, your ERP or a website. Each key sees only this business.')}</p>
      <form className="row wrap" onSubmit={create}>
        <input id="key-name" placeholder={t('Key name, e.g. n8n reports')} value={name} onChange={(e) => setName(e.target.value)} />
        {SCOPES.map((sc) => <label key={sc} className="check"><input type="checkbox" checked={scopes.includes(sc)} onChange={(e) => setScopes(e.target.checked ? [...scopes, sc] : scopes.filter((x) => x !== sc))} />{t(SCOPE_LABEL[sc])}</label>)}
        <button className="primary" disabled={!scopes.length}><Plus size={16} />{t('Create key')}</button>
      </form>
      {err && <p className="error">{err}</p>}
      {keys.length > 0 && (
        <div className="table-wrap"><table className="list">
          <thead><tr><th>{t('Name')}</th><th>{t('Key')}</th><th>{t('Can read')}</th><th>{t('Last used')}</th><th /></tr></thead>
          <tbody>{keys.map((k) => (
            <tr key={k.id} className={k.revoked_at ? 'muted' : ''}><td>{k.name}</td><td className="mono small">{k.prefix}_…</td>
              <td className="small">{k.scopes.map((x) => t(SCOPE_LABEL[x] ?? x)).join(' · ')}</td>
              <td className="small">{k.last_used_at ? new Date(k.last_used_at).toLocaleString() : '—'}</td>
              <td><div className="row end">{k.revoked_at ? <span className="pill cancelled">{t('Revoked')}</span>
                : <button className="ghost small danger" onClick={() => void rpc('revoke_api_key', { p_id: k.id }).then(load)}>{t('Revoke')}</button>}</div></td></tr>))}</tbody>
        </table></div>)}
      <p className="muted small">{t('Address')}: <code className="mono">{apiBase}/items</code> · <code className="mono">/stock</code> · <code className="mono">/sales?from=…&to=…</code> · <code className="mono">/customers</code></p>
      {created && (
        <Modal title={t('New API key')} onClose={() => setCreated(null)}>
          <div className="stack">
            <p>{t('Copy this key now. It is shown only once. Send it as “Authorization: Bearer <key>”.')}</p>
            <div className="linkbox"><code id="api-key">{created}</code><button onClick={() => void copy(created, document.getElementById('api-key'))}><Copy size={15} />{t('Copy')}</button></div>
            <div className="row end"><button className="primary" onClick={() => setCreated(null)}>{t('Done')}</button></div>
          </div>
        </Modal>
      )}
    </div>
  )
}

const VERIFY = `// n8n Code node: check the Z Trust signature (Webhook node → "Raw body" on)
const crypto = require('crypto');
const h = $input.first().json.headers;
const raw = $input.first().binary?.data ? Buffer.from($input.first().binary.data.data, 'base64').toString() : JSON.stringify($input.first().json.body);
const expected = 'sha256=' + crypto.createHmac('sha256', 'whsec_…').update(h['x-ztrust-timestamp'] + '.' + raw).digest('hex');
if (expected !== h['x-ztrust-signature'] || Date.now() / 1000 - Number(h['x-ztrust-timestamp']) > 300) throw new Error('Bad signature');
return $input.all();`

function N8nGuide() {
  const { t } = useT()
  return (
    <details className="card">
      <summary>{t('Connect n8n in three steps')}</summary>
      <ol className="steps-list">
        <li>{t('In n8n, add a Webhook trigger (POST) and copy its production URL.')}</li>
        <li>{t('Here, add a webhook with that URL, pick the events, and keep the signing secret.')}</li>
        <li>{t('Press “Send test”. The ping arrives in n8n within a minute; then build your flow (email, Google Sheets, WhatsApp, your ERP).')}</li>
      </ol>
      <p className="muted small">{t('Optional but recommended: verify the signature in a Code node.')}</p>
      <pre className="code-block"><code>{VERIFY}</code></pre>
    </details>
  )
}

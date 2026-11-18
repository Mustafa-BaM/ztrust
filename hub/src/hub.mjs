#!/usr/bin/env node
// Z Trust Branch Hub
// Run on one always-on device in the branch. POS and kitchen screens connect over the shop Wi-Fi;
// kitchen tickets flow and print even when the internet is down, and sync to the cloud when it returns.
//
// Config (env or hub.config.json next to the data folder):
//   SUPABASE_URL, SUPABASE_ANON_KEY  – the cloud project
//   HUB_TOKEN                        – from Settings → Kitchen stations → Branch hub
//   PORT (8787), APP_DIR (built web app to serve on the LAN), DATA_DIR (./data)
import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { WebSocketServer } from 'ws'
import { renderChit, sendRaw, toEscPos } from './escpos.mjs'

const VERSION = '0.1.0'
const DATA = path.resolve(process.env.DATA_DIR || './data')
fs.mkdirSync(DATA, { recursive: true })
const fileCfg = (() => { try { return JSON.parse(fs.readFileSync(path.join(DATA, 'hub.config.json'), 'utf8')) } catch { return {} } })()
const CFG = {
  url: process.env.SUPABASE_URL || fileCfg.SUPABASE_URL,
  key: process.env.SUPABASE_ANON_KEY || fileCfg.SUPABASE_ANON_KEY,
  token: process.env.HUB_TOKEN || fileCfg.HUB_TOKEN,
  port: Number(process.env.PORT || fileCfg.PORT || 8787),
  appDir: process.env.APP_DIR || fileCfg.APP_DIR || '',
}
if (!CFG.url || !CFG.key || !CFG.token) {
  console.error('Missing SUPABASE_URL, SUPABASE_ANON_KEY or HUB_TOKEN (env or data/hub.config.json).'); process.exit(1)
}

// ---------------------------------------------------------------- persistent state
const statePath = path.join(DATA, 'state.json')
const state = (() => { try { return JSON.parse(fs.readFileSync(statePath, 'utf8')) } catch { return {} } })()
state.pairingCode ??= String(crypto.randomInt(100000, 999999))
state.tickets ??= {}
state.config ??= null
let saveTimer = null
function save() {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => { const tmp = statePath + '.tmp'; fs.writeFileSync(tmp, JSON.stringify(state)); fs.renameSync(tmp, statePath) }, 150)
}
save()

let cloudOnline = false
const printers = {} // station_id → { ok, error, at }
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a)

// ---------------------------------------------------------------- cloud calls (plain REST, no SDK)
async function rpc(fn, args) {
  const r = await fetch(`${CFG.url}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: { apikey: CFG.key, Authorization: `Bearer ${CFG.key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args), signal: AbortSignal.timeout(8000),
  })
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${await r.text()}`)
  return r.json()
}
async function refreshConfig() {
  try { state.config = await rpc('hub_config', { p_token: CFG.token, p_version: VERSION }); cloudOnline = true; save() }
  catch (e) { cloudOnline = false; if (!state.config) log('cloud unreachable and no cached config yet:', e.message) }
}
async function syncTickets() {
  const dirty = Object.values(state.tickets).filter((t) => t.dirty)
  if (!dirty.length) return
  try {
    await rpc('hub_sync', { p_token: CFG.token, p_tickets: dirty.map(({ dirty: _d, ...t }) => t) })
    for (const t of dirty) if (state.tickets[t.id]?.updated_at === t.updated_at) state.tickets[t.id].dirty = false
    cloudOnline = true; save(); log(`synced ${dirty.length} ticket(s) to the cloud`)
  } catch (e) { cloudOnline = false; log('sync deferred:', e.message.slice(0, 120)) }
}
function prune() {
  const cutoff = Date.now() - 24 * 3600_000
  for (const [id, t] of Object.entries(state.tickets)) if (!t.dirty && ['served', 'cancelled'].includes(t.status) && Date.parse(t.updated_at) < cutoff) delete state.tickets[id]
}

// ---------------------------------------------------------------- printing
const stationOf = (id) => state.config?.stations?.find((s) => s.id === id)
async function printTicket(t, attempt = 1) {
  const st = stationOf(t.station_id)
  if (!st || !st.printer_ip || st.mode === 'kds') return
  try {
    const canvas = renderChit(t, st, st.printer_width)
    fs.writeFileSync(path.join(DATA, 'last-chit.png'), canvas.toBuffer('image/png'))
    await sendRaw(st.printer_ip, st.printer_port || 9100, toEscPos(canvas))
    printers[st.id] = { ok: true, at: new Date().toISOString() }
    log(`printed ${t.order_ref} on ${st.name} (${st.printer_ip})`)
  } catch (e) {
    printers[st.id] = { ok: false, error: e.message, at: new Date().toISOString() }
    log(`print failed on ${st.name}: ${e.message}${attempt < 20 ? ' – retrying' : ''}`)
    if (attempt < 20) setTimeout(() => void printTicket(t, attempt + 1), Math.min(30_000, 2000 * attempt))
  }
}

// ---------------------------------------------------------------- ticket rules (same as the database)
const MOVES = new Set(['new>preparing', 'new>ready', 'preparing>ready', 'ready>served', 'ready>preparing', 'served>ready', 'new>cancelled', 'preparing>cancelled'])
function setStatus(t, to) {
  if (!MOVES.has(`${t.status}>${to}`)) return false
  const now = new Date().toISOString()
  t.status = to
  if (to === 'preparing') { t.started_at ??= now; t.ready_at = null }
  if (to === 'ready') { t.ready_at = now; t.served_at = null }
  if (to === 'served') t.served_at = now
  return true
}
function upsertTicket(t) {
  if (!t?.id || !t.station_id || !Array.isArray(t.items)) return null
  const now = new Date().toISOString()
  const existing = state.tickets[t.id]
  if (existing) { if (t.order_ref && !String(t.order_ref).startsWith('OFF-')) existing.order_ref = t.order_ref; existing.updated_at = now; existing.dirty = true; return existing }
  const clean = {
    id: t.id, station_id: t.station_id, sale_client_id: t.sale_client_id ?? null, order_ref: String(t.order_ref ?? '—'), order_type: t.order_type ?? 'takeaway',
    table_no: t.table_no ?? null, customer_name: t.customer_name ?? null, note: t.note ?? null, status: 'new',
    created_at: t.created_at ?? now, started_at: null, ready_at: null, served_at: null, updated_at: now, dirty: true,
    items: t.items.map((i) => ({ id: i.id ?? crypto.randomUUID(), name: String(i.name ?? ''), name_ar: i.name_ar ?? null, qty: Number(i.qty) || 1, note: i.note ?? null, done: false })),
  }
  state.tickets[clean.id] = clean
  return clean
}

// ---------------------------------------------------------------- HTTP: API + the web app for LAN devices
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.woff2': 'font/woff2', '.ico': 'image/x-icon' }
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://hub')
  res.setHeader('Access-Control-Allow-Origin', '*')
  if (url.pathname === '/api/hub') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
    return res.end(JSON.stringify({
      ok: true, version: VERSION, name: state.config?.hub?.name ?? 'Branch hub', branch_id: state.config?.hub?.branch_id ?? null,
      tenant_id: state.config?.hub?.tenant_id ?? null, cloud_online: cloudOnline, clients: wss.clients.size,
      pending_sync: Object.values(state.tickets).filter((t) => t.dirty).length,
      printers: (state.config?.stations ?? []).filter((s) => s.printer_ip).map((s) => ({ station: s.name, ip: s.printer_ip, ...printers[s.id] })),
    }))
  }
  if (url.pathname === '/api/last-chit.png') {
    const f = path.join(DATA, 'last-chit.png')
    if (!fs.existsSync(f)) { res.writeHead(404); return res.end() }
    res.writeHead(200, { 'Content-Type': 'image/png' }); return fs.createReadStream(f).pipe(res)
  }
  if (!CFG.appDir) { res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('Z Trust hub is running.') }
  const root = path.resolve(CFG.appDir)
  let file = path.resolve(root, '.' + decodeURIComponent(url.pathname))
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(root, 'index.html')
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream', 'Cache-Control': file.endsWith('index.html') || file.endsWith('sw.js') ? 'no-cache' : 'public, max-age=31536000' })
  fs.createReadStream(file).pipe(res)
})

// ---------------------------------------------------------------- WebSocket: POS → hub → kitchen screens
const wss = new WebSocketServer({ server, path: '/ws' })
const broadcast = (msg) => { const s = JSON.stringify(msg); for (const c of wss.clients) if (c.paired && c.readyState === 1) c.send(s) }
const active = () => Object.values(state.tickets).filter((t) => !['served', 'cancelled'].includes(t.status) || Date.now() - Date.parse(t.updated_at) < 10 * 60_000)
  .map(({ dirty, ...t }) => ({ ...t, synced: !dirty }))

wss.on('connection', (ws, req) => {
  ws.paired = false
  const ip = req.socket.remoteAddress
  ws.on('message', (raw) => {
    let m; try { m = JSON.parse(raw) } catch { return }
    if (m.type === 'hello') {
      if (String(m.code) !== state.pairingCode) { ws.send(JSON.stringify({ type: 'error', error: 'pairing_code' })); return ws.close() }
      ws.paired = true; ws.role = m.role
      ws.send(JSON.stringify({ type: 'welcome', hub: state.config?.hub ?? null, cloud_online: cloudOnline, stations: state.config?.stations ?? [] }))
      ws.send(JSON.stringify({ type: 'snapshot', tickets: active() }))
      log(`${m.role ?? 'device'} connected from ${ip}`); return
    }
    if (!ws.paired) return
    if (m.type === 'ticket.new') {
      for (const t of m.tickets ?? [m.ticket]) {
        const isNew = !state.tickets[t?.id]
        const saved = upsertTicket(t)
        if (!saved) continue
        broadcast({ type: 'ticket', ticket: { ...saved, dirty: undefined } })
        if (isNew) void printTicket(saved)
      }
      save(); void syncTickets()
    } else if (m.type === 'ticket.status') {
      const t = state.tickets[m.id]
      if (t && setStatus(t, m.status)) { t.updated_at = new Date().toISOString(); t.dirty = true; save(); broadcast({ type: 'ticket', ticket: { ...t, dirty: undefined } }); void syncTickets() }
      else ws.send(JSON.stringify({ type: 'error', error: 'bad_transition', id: m.id }))
    } else if (m.type === 'item.toggle') {
      const t = state.tickets[m.id]; const it = t?.items.find((i) => i.id === m.item)
      if (it) { it.done = !it.done; t.updated_at = new Date().toISOString(); t.dirty = true; save(); broadcast({ type: 'ticket', ticket: { ...t, dirty: undefined } }) }
    } else if (m.type === 'ticket.print') {
      const t = state.tickets[m.id]; if (t) void printTicket(t)
    }
  })
})
setInterval(() => broadcast({ type: 'status', cloud_online: cloudOnline, pending_sync: Object.values(state.tickets).filter((t) => t.dirty).length }), 5000)

// ---------------------------------------------------------------- start
await refreshConfig()
setInterval(() => void refreshConfig(), 60_000)
setInterval(() => { void syncTickets(); prune() }, Number(process.env.SYNC_EVERY_MS || 10_000))
server.listen(CFG.port, '0.0.0.0', () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter((n) => n && n.family === 'IPv4' && !n.internal).map((n) => n.address)
  log(`Z Trust hub ${VERSION} · ${state.config?.hub?.name ?? 'not yet configured'} · cloud ${cloudOnline ? 'online' : 'offline'}`)
  log(`Open on tablets and POS: ${[...ips, 'localhost'].map((i) => `http://${i}:${CFG.port}`).join('  ')}`)
  log(`PAIRING CODE: ${state.pairingCode}`)
})

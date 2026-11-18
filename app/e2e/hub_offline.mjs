// E2E: Wi-Fi up, internet down. POS → Branch Hub → kitchen screen + network printer, then cloud sync when internet returns.
import { createRequire } from 'node:module'
import { execFileSync, spawn } from 'node:child_process'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
const require = createRequire(import.meta.url)
const { chromium } = require('playwright')

const DEV = process.env.APP_URL || 'http://localhost:5173'
const HUB = 'http://localhost:8787'
const SB = process.env.SUPABASE_URL || 'http://127.0.0.1:54321'
const KEY = process.env.SERVICE_KEY, ANON = process.env.ANON_KEY
const DB = process.env.DB_URL || 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
const SHOTS = process.env.SHOTS || './shots'
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..')
fs.mkdirSync(SHOTS, { recursive: true })
const run = Date.now(), PASS = 'Secret#2026', mail = (n) => `${n}${run}@example.com`
const log = (...a) => console.log('✓', ...a)
const sql = (q) => execFileSync('psql', [DB, '-Atc', q]).toString().trim()
const waitFor = async (fn, ms = 30000, label = 'condition') => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (await fn()) return; await new Promise((r) => setTimeout(r, 500)) } throw new Error(`timeout: ${label}`) }

// the shop's internet gateway: the hub reaches the cloud through it, and we can switch it off
let gatewayUp = true
const upstream = new URL(SB)
const links = new Set()
const gateway = net.createServer((client) => {
  if (!gatewayUp) return client.destroy()
  const up = net.connect(Number(upstream.port), upstream.hostname)
  links.add(client); links.add(up); client.on('close', () => { links.delete(client); links.delete(up) })
  client.pipe(up).pipe(client); client.on('error', () => up.destroy()); up.on('error', () => client.destroy())
}).listen(54399, '127.0.0.1')
const hubStatus = async () => (await fetch(`${HUB}/api/hub`)).json()

// fake kitchen printer on the LAN (raw ESC/POS on a TCP port, like port 9100)
let printed = Buffer.alloc(0)
const printer = net.createServer((sock) => sock.on('data', (d) => { printed = Buffer.concat([printed, d]) })).listen(9911, '127.0.0.1')

const browser = await chromium.launch()
const page = async () => { const c = await browser.newContext({ viewport: { width: 1366, height: 860 } }); const p = await c.newPage(); p.on('pageerror', (e) => console.log('PAGE ERROR', e.message)); return [c, p] }

// ---------- owner sets up a café with a kitchen printer and creates the hub token
const [, owner] = await page()
await owner.goto(DEV)
await owner.getByRole('button', { name: 'Start 7-day free trial' }).click()
await owner.fill('#login-email', mail('own')); await owner.fill('#login-password', PASS); await owner.getByRole('button', { name: 'Create account' }).click()
await owner.selectOption('#ob-country', 'KW'); await owner.getByRole('button', { name: 'Next' }).click()
await owner.getByRole('button', { name: /^Café/ }).click(); await owner.getByRole('button', { name: 'Next' }).click()
await owner.fill('#ob-name', 'Diwan Grill'); await owner.fill('#ob-name-ar', 'ديوان جريل'); await owner.getByRole('button', { name: 'Next' }).click()
await owner.fill('#ob-display', 'Omar'); await owner.fill('#ob-pin', '9999'); await owner.getByRole('button', { name: 'Open my business' }).click()
await owner.getByText('Open a shift to start selling').waitFor()
const tenant = sql(`select tenant_id from memberships m join auth.users u on u.id=m.user_id where u.email='${mail('own')}'`)
sql(`insert into items(tenant_id,name,name_ar,price,cost) values ('${tenant}','Mixed grill','مشاوي مشكلة',4500,1500),('${tenant}','Hummus','حمص',900,200)`)
await owner.getByRole('link', { name: 'Settings' }).click()
await owner.getByRole('button', { name: 'Kitchen stations' }).click()
const stationId = sql(`select id from kitchen_stations where tenant_id='${tenant}'`)
await owner.fill(`#st-ip-${stationId}`, '127.0.0.1'); await owner.locator(`#st-ip-${stationId}`).blur()
await owner.waitForTimeout(500)
sql(`update kitchen_stations set printer_port = 9911, mode = 'both' where id='${stationId}'`)
await owner.getByRole('button', { name: 'Create hub token' }).click()
const token = (await owner.locator('code.token').first().innerText()).trim()
log('owner configured station printer (network IP) and created a hub token')

// ---------- start the hub on "the counter PC"
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zt-hub-'))
let hubOut = ''
const hub = spawn('node', [path.join(ROOT, 'hub/src/hub.mjs')], {
  env: { ...process.env, SUPABASE_URL: 'http://127.0.0.1:54399', SUPABASE_ANON_KEY: ANON, HUB_TOKEN: token, PORT: '8787', APP_DIR: path.join(ROOT, 'app/dist'), DATA_DIR: dataDir, SYNC_EVERY_MS: '2000' },
})
hub.stdout.on('data', (d) => { hubOut += d.toString() }); hub.stderr.on('data', (d) => { hubOut += d.toString() })
await waitFor(() => /PAIRING CODE: (\d{6})/.test(hubOut), 20000, 'hub start')
const code = hubOut.match(/PAIRING CODE: (\d{6})/)[1]
log(`hub running on :8787, cloud online, pairing code ${code}`)

// ---------- kitchen tablet and POS open the app from the hub (same Wi-Fi)
const r = await fetch(`${SB}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: mail('chef'), password: PASS, email_confirm: true }) })
sql(`insert into memberships(tenant_id,user_id,role,display_name) values ('${tenant}','${(await r.json()).id}','kitchen','Chef Ravi')`)

const [kctx, kds] = await page()
await kds.goto(HUB); await kds.fill('#login-email', mail('chef')); await kds.fill('#login-password', PASS); await kds.locator('form button.primary').click()
await kds.locator('#pair-code').waitFor(); await kds.fill('#pair-code', code); await kds.getByRole('button', { name: 'Pair' }).click()
await kds.getByText('Local hub').waitFor()
const [pctx, pos] = await page()
await pos.goto(HUB); await pos.fill('#login-email', mail('own')); await pos.fill('#login-password', PASS); await pos.locator('form button.primary').click()
await pos.locator('#pair-code').waitFor(); await pos.fill('#pair-code', code); await pos.getByRole('button', { name: 'Pair' }).click()
await pos.getByRole('link', { name: 'Shift', exact: true }).click(); await pos.fill('#shift-float', '20'); await pos.getByRole('button', { name: 'Open shift' }).click()
await pos.getByText('Current shift').waitFor()
await pos.getByRole('link', { name: 'Sell' }).click(); await pos.getByRole('button', { name: 'Touch' }).click()
await pos.getByText('Kitchen via hub').waitFor()
log('POS and kitchen tablet paired with the hub')

// ---------- INTERNET DOWN (Wi-Fi still up): every call to the cloud fails, the hub stays reachable
const cut = (c) => c.route(`${SB}/**`, (route) => route.abort('internetdisconnected'))
await cut(kctx); await cut(pctx)
gatewayUp = false
for (const sock of links) sock.destroy()
log('internet cut for the whole shop: POS, kitchen tablet AND the hub cannot reach the cloud; Wi-Fi/LAN still up')

await pos.getByRole('button', { name: 'Dine-in' }).click(); await pos.fill('#pos-table', '5')
await pos.locator('.tile', { hasText: 'Mixed grill' }).click(); await pos.locator('.tile', { hasText: 'Mixed grill' }).click()
await pos.getByRole('button', { name: /^Note/ }).click(); await pos.fill('#line-note', 'بدون بصل، حار'); await pos.getByRole('button', { name: 'Save' }).click()
await pos.locator('.tile', { hasText: 'Hummus' }).click()
await pos.getByRole('button', { name: /Exact cash/ }).click()
await pos.getByText('Saved offline').waitFor()
await pos.getByRole('button', { name: 'New sale' }).click()
log('sale saved offline at the till (internet down)')

await kds.locator('.ticket', { hasText: 'Mixed grill' }).waitFor({ timeout: 8000 })
await kds.screenshot({ path: `${SHOTS}/h1-kds-offline.png` })
log('ticket appeared on the kitchen screen through the hub, with no internet')
await waitFor(() => printed.includes(Buffer.from([0x1d, 0x76, 0x30])), 10000, 'printer bytes')
log(`kitchen printer received ${printed.length} bytes of ESC/POS raster (Arabic rendered as image)`)
fs.copyFileSync(path.join(dataDir, 'last-chit.png'), `${SHOTS}/h2-printed-chit.png`)

await kds.locator('.ticket', { hasText: 'Mixed grill' }).getByRole('button', { name: 'Start' }).click()
await kds.locator('.kds-col.preparing .ticket', { hasText: 'Mixed grill' }).waitFor()
await kds.locator('.kds-col.preparing .ticket', { hasText: 'Mixed grill' }).getByRole('button', { name: 'Ready' }).click()
await kds.locator('.kds-col.ready .ticket', { hasText: 'Mixed grill' }).waitFor()
log('chef moved the ticket to Preparing → Ready while offline')
if (sql(`select count(*) from sales where tenant_id='${tenant}'`) !== '0') throw new Error('sale should not be in the cloud yet')
if (sql(`select count(*) from kitchen_tickets where tenant_id='${tenant}'`) !== '0') throw new Error('ticket should not be in the cloud yet')
await waitFor(async () => { const h = await hubStatus(); return h.cloud_online === false && h.pending_sync >= 1 }, 15000, 'hub offline state')
log(`hub reports: cloud offline, ${(await hubStatus()).pending_sync} ticket(s) waiting to sync`)

// ---------- INTERNET BACK
await kctx.unroute(`${SB}/**`); await pctx.unroute(`${SB}/**`)
gatewayUp = true
await pos.locator('.topbar .status').click()
await waitFor(() => sql(`select count(*) from sales where tenant_id='${tenant}'`) === '1', 30000, 'sale synced')
await waitFor(() => sql(`select coalesce(string_agg(status||'|'||coalesce(order_ref,'')||'|'||(sale_id is not null)::text, ','),'') from kitchen_tickets where tenant_id='${tenant}'`) === 'ready|B01-INV-000001|true', 30000, 'ticket synced')
const counts = sql(`select count(*) from kitchen_tickets where tenant_id='${tenant}'`)
log(`internet back: sale B01-INV-000001 synced; kitchen ticket synced by the hub, linked to the sale, status ready; tickets in cloud: ${counts} (no duplicates)`)
await kds.screenshot({ path: `${SHOTS}/h3-kds-online.png` })

hub.kill(); printer.close(); gateway.close(); await browser.close()
console.log('E2E HUB OFFLINE PASSED')

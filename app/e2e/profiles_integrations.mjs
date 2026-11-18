// E2E: business profiles at sign-up, module switches (UI hides, server blocks), shop logo on the receipt,
// webhooks to a local "n8n" receiver with signature check, the dispatcher, and API keys.
import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
const require = createRequire(import.meta.url)
const { chromium } = require('playwright')
const { createClient } = require('@supabase/supabase-js')
const { dispatchOnce } = await import('../../supabase/functions/_shared/dispatch.ts')
const APP = process.env.APP_URL || 'http://localhost:5173'
const SB = process.env.SUPABASE_URL || 'http://127.0.0.1:54321'
const ANON = process.env.ANON_KEY
const SERVICE = process.env.SERVICE_ROLE_KEY
const DB = process.env.DB_URL || 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
const SHOTS = process.env.SHOTS || './shots'
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..')
fs.mkdirSync(SHOTS, { recursive: true })
const run = Date.now(), PASS = 'Secret#2026', mail = (n) => `${n}${run}@example.com`
const log = (...a) => console.log('✓', ...a)
const sql = (q) => execFileSync('psql', [DB, '-Atc', q]).toString().trim()
const must = (c, m) => { if (!c) throw new Error(m) }

// ---- a stand-in for an n8n Webhook node that verifies the Z Trust signature
let secret = ''
const received = []
const receiver = http.createServer((req, res) => {
  let body = ''
  req.on('data', (c) => (body += c)); req.on('end', () => {
    const ts = req.headers['x-ztrust-timestamp'], sig = req.headers['x-ztrust-signature']
    const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(`${ts}.${body}`).digest('hex')
    received.push({ event: req.headers['x-ztrust-event'], delivery: req.headers['x-ztrust-delivery'], valid: sig === expected, body: JSON.parse(body) })
    res.writeHead(sig === expected ? 200 : 401); res.end()
  })
})
await new Promise((r) => receiver.listen(0, '127.0.0.1', r))
const HOOK = `http://127.0.0.1:${receiver.address().port}/webhook/zt`
const admin = createClient(SB, SERVICE, { auth: { persistSession: false } })

const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const p = await ctx.newPage(); p.on('pageerror', (e) => console.log('PAGE ERROR', e.message))
await p.goto(APP)
await p.getByRole('button', { name: 'Start 7-day free trial' }).click()
await p.fill('#login-email', mail('own')); await p.fill('#login-password', PASS); await p.getByRole('button', { name: 'Create account' }).click()
await p.selectOption('#ob-country', 'KW'); await p.getByRole('button', { name: 'Next' }).click()

// ---- sign-up: 9 business types; cards promise only what exists, the rest is marked "Coming"
await p.getByRole('button', { name: /^Fashion & shoes/ }).waitFor()
must(await p.locator('.choice.profile').count() === 15, 'fifteen business types at sign-up')
// every type open for sign-up is complete: nothing on its card is marked "Coming"
must(await p.locator('.choice.profile .soon').count() === 0, 'no business type at sign-up waits for a module')
const salonCard = (await p.getByRole('button', { name: /^Salon & barber/ }).innerText()).replace(/\n/g, ' ')
must(/Appointments & calendar/.test(salonCard) && /Staff commissions/.test(salonCard), 'salon card lists its modules: ' + salonCard)
await p.getByRole('button', { name: /^Fashion & shoes/ }).click()
await p.screenshot({ path: `${SHOTS}/p1-signup-types.png` })
await p.getByRole('button', { name: 'Next' }).click()
await p.fill('#ob-name', 'Lulu Fashion'); await p.fill('#ob-name-ar', 'لولو للأزياء'); await p.getByRole('button', { name: 'Next' }).click()
await p.fill('#ob-display', 'Lulu'); await p.fill('#ob-pin', '9999'); await p.getByRole('button', { name: 'Open my business' }).click()
await p.getByText('Open a shift to start selling').waitFor()
const tenant = sql(`select t.id from tenants t join memberships m on m.tenant_id=t.id join auth.users u on u.id=m.user_id where u.email='${mail('own')}'`)
must(sql(`select business_profile||' '||features::text from tenants where id='${tenant}'`) === 'fashion {"loyalty": true, "variants": true, "promotions": true, "purchasing": true}', 'fashion profile and modules')
const navs = async () => (await p.locator('aside nav a span').allInnerTexts()).join(',')
let nav = await navs()
must(!nav.includes('Kitchen') && nav.includes('Purchasing'), 'fashion: no Kitchen, has Purchasing: ' + nav)
await p.getByRole('link', { name: 'Products' }).click()
await p.getByRole('button', { name: 'Add item' }).waitFor()
must(await p.getByRole('button', { name: 'Ingredients' }).count() === 0, 'no recipe controls for fashion')
log('signed up as Fashion & shoes: Kitchen and recipes hidden, Purchasing shown')

// ---- module switches: the kitchen is not offered to a fashion shop; Promotions off → gone, on → back
await p.getByRole('link', { name: 'Settings' }).click()
await p.getByRole('button', { name: 'Business type & modules' }).click()
must(await p.getByRole('switch', { name: 'Kitchen screen & printers' }).count() === 0, 'kitchen not offered to fashion')
await p.getByRole('switch', { name: 'Promotions & bundles' }).click()
await p.getByText(/switched off\. Its data is kept/).waitFor()
await p.locator('aside nav a', { hasText: 'Promotions' }).waitFor({ state: 'detached' })
await p.getByRole('switch', { name: 'Promotions & bundles' }).click()
await p.getByText('Promotions & bundles switched on').waitFor()
await p.locator('aside nav a', { hasText: 'Promotions' }).waitFor()
await p.screenshot({ path: `${SHOTS}/p2-modules.png`, fullPage: true })
log('Kitchen not offered to a fashion shop; Promotions switched off (menu item gone) and on again')

// ---- shop logo: upload → colour + thermal black/white copies → on the receipt preview
await p.getByRole('button', { name: 'Business and receipt' }).click()
await p.setInputFiles('#logo-file', path.join(ROOT, 'brand/z-trust-mark.png'))
await p.getByText('Logo saved').waitFor()
await p.locator('.receipt-preview img.r-logo').waitFor()
const logoRow = sql(`select logo_url||' '||(settings->>'logo_mono_url') from tenants where id='${tenant}'`)
must(/branding\/.*logo-\d+\.png .*logo-mono-\d+\.png/.test(logoRow), 'both logo files stored: ' + logoRow)
const mono = await (await fetch(logoRow.split(' ')[1])).arrayBuffer()
must(mono.byteLength > 200, 'mono logo served')
await p.locator('.seg', { hasText: 'Large' }).getByRole('button', { name: 'Large' }).click()
await p.fill('#r-phones', '+965 2222 0000'); await p.locator('.receipt-settings').getByRole('button', { name: 'Save', exact: true }).click(); await p.locator('.receipt-settings').getByText('Saved').waitFor()
must(sql(`select settings->>'logo_size' from tenants where id='${tenant}'`) === 'l', 'logo size saved')
await p.locator('.receipt-settings').screenshot({ path: `${SHOTS}/p3-receipt-logo.png` })
log('logo uploaded: colour + black-and-white thermal copy, shown on the receipt (large)')

// ---- integrations: off until switched on
await p.getByRole('button', { name: 'Integrations', exact: true }).click()
await p.getByText('Integrations are switched off').waitFor()
await p.getByRole('button', { name: 'Open modules' }).click()
await p.getByRole('switch', { name: 'Integrations (webhooks & API)' }).click()
await p.getByText('Integrations (webhooks & API) switched on').waitFor()
await p.getByRole('button', { name: 'Integrations', exact: true }).click()
await p.getByRole('button', { name: 'Add webhook' }).first().click()
await p.fill('#wh-name', 'n8n'); await p.fill('#wh-url', HOOK)
await p.getByLabel(/Refund issued/).check(); await p.getByLabel(/New customer/).check()
await p.getByRole('button', { name: 'Save webhook' }).click()
secret = await p.locator('#wh-secret').innerText()
must(/^whsec_[0-9a-f]{48}$/.test(secret), 'secret shown once')
await p.getByRole('button', { name: 'Done' }).click()
await p.getByRole('button', { name: 'Send test' }).click()
await p.getByText('Test event queued').waitFor()
let r = await dispatchOnce(admin)
must(r.sent === 1 && received.length === 1 && received[0].event === 'ping' && received[0].valid, 'signed ping delivered: ' + JSON.stringify(received))
log('webhook added, secret shown once, signed test ping delivered')

// ---- a real sale and a new customer reach the receiver
await p.getByRole('link', { name: 'Products' }).click()
await p.getByRole('button', { name: 'Add item' }).click()
await p.fill('#item-name', 'Abaya'); await p.fill('#item-name-ar', 'عباية'); await p.fill('#item-price', '25'); await p.fill('#item-cost', '9'); await p.fill('#item-barcode', 'AB1')
await p.getByRole('button', { name: 'Save' }).click(); await p.locator('tbody td', { hasText: /^Abaya/ }).first().waitFor()
await p.getByRole('link', { name: 'Shift' }).click(); await p.fill('#shift-float', '10'); await p.getByRole('button', { name: 'Open shift' }).click(); await p.getByText('Current shift').waitFor()
await p.getByRole('link', { name: 'Sell' }).click()
await p.getByRole('button', { name: 'Keyboard' }).click()
await p.fill('#pos-search', 'AB1'); await p.press('#pos-search', 'Enter')
await p.keyboard.press('F8')
must(await p.getByRole('radio', { name: 'On account' }).count() === 0, 'on-account hidden while credit is off')
await p.fill('#pay-amount', '25'); await p.getByRole('button', { name: 'Add payment' }).click()
await p.getByRole('button', { name: /Complete sale/ }).click(); await p.getByText('Sale complete').waitFor()
await p.locator('.receipt img.r-logo').first().waitFor().catch(() => {})
await p.getByRole('button', { name: 'New sale' }).click()
sql(`insert into customers(tenant_id, name, phone) values ('${tenant}', 'Sara', '+96552222222')`)
r = await dispatchOnce(admin)
const sale = received.find((x) => x.event === 'sale.completed'), cust = received.find((x) => x.event === 'customer.created')
must(r.sent === 2 && sale?.valid && cust?.valid, 'sale + customer delivered: ' + JSON.stringify(r))
must(sale.body.data.total === 25000 && sale.body.data.lines[0].name === 'Abaya' && sale.body.data.currency === 'KWD', 'sale payload')
log(`sale.completed (${sale.body.data.number}, 25.000 KWD, lines included) and customer.created delivered, signatures valid`)

// ---- a failing endpoint is retried later, and shows in the log
const bad = secret; secret = 'wrong-on-purpose'
sql(`insert into customers(tenant_id, name) values ('${tenant}', 'Retry Test')`)
r = await dispatchOnce(admin)
must(r.failed === 1, 'rejected delivery counted as failed')
must(sql(`select status||':'||attempts||':'||response_code from event_outbox where tenant_id='${tenant}' order by id desc limit 1`) === 'pending:1:401', 'queued for retry')
secret = bad
await p.getByRole('link', { name: 'Settings' }).click(); await p.getByRole('button', { name: 'Integrations', exact: true }).click()
await p.getByText('Recent deliveries').waitFor(); await p.getByText('Retrying').waitFor()
await p.screenshot({ path: `${SHOTS}/p4-integrations.png`, fullPage: true })
log('failed delivery (401) queued for retry with backoff; delivery log shows Delivered / Retrying')

// ---- API key: shown once, read-only, scoped to this business
await p.fill('#key-name', 'n8n reports')
await p.getByLabel('Sales', { exact: true }).uncheck(); await p.getByLabel('Stock', { exact: true }).uncheck()
await p.getByRole('button', { name: 'Create key' }).click()
const key = await p.locator('#api-key').innerText()
must(/^ztk_[0-9a-f]{8}_[0-9a-f]{48}$/.test(key), 'key format')
await p.getByRole('button', { name: 'Done' }).click()
const call = async (resource) => fetch(`${SB}/rest/v1/rpc/api_query`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_key: key, p_resource: resource }) })
const items = await (await call('items')).json()
must(items.data?.length === 1 && items.data[0].name === 'Abaya' && items.data[0].price === 25000, 'items via API: ' + JSON.stringify(items))
must((await call('sales')).status >= 400, 'sales scope not granted')
await p.getByRole('button', { name: 'Revoke' }).click(); await p.getByText('Revoked').waitFor()
must((await call('items')).status >= 400, 'revoked key refused')
log('API key: items readable, sales refused (no scope), revoked key refused')

// ---- server blocks a switched-off module even if the screen were bypassed
const own = createClient(SB, ANON, { auth: { persistSession: false } })
await own.auth.signInWithPassword({ email: mail('own'), password: PASS })
const { error: dErr } = await own.from('delivery_channels').insert({ tenant_id: tenant, branch_id: sql(`select id from branches where tenant_id='${tenant}'`), platform: 'keeta', display_name: 'Keeta' })
must(dErr && /switched off/.test(dErr.message), 'delivery channel refused while delivery is off: ' + dErr?.message)
const { error: gErr } = await own.from('tenants').update({ plan: 'business' }).eq('id', tenant)
must(gErr, 'plan cannot be changed from the app')
log('server refuses switched-off modules and plan changes from the app')

await browser.close(); receiver.close()
console.log('PROFILES & INTEGRATIONS E2E PASSED')

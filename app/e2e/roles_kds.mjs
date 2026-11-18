// E2E: role packages, KDS and purchasing with separate staff logins.
// Needs local Supabase (supabase start) and the dev server. Env: APP_URL, SUPABASE_URL, SERVICE_KEY, DB_URL, SHOTS
import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
const require = createRequire(import.meta.url)
const { chromium } = require('playwright')

const APP = process.env.APP_URL || 'http://localhost:5173'
const SB = process.env.SUPABASE_URL || 'http://127.0.0.1:54321'
const KEY = process.env.SERVICE_KEY
const DB = process.env.DB_URL || 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
const SHOTS = process.env.SHOTS || './shots'
fs.mkdirSync(SHOTS, { recursive: true })
const run = Date.now()
const mail = (n) => `${n}${run}@example.com`
const PASS = 'Secret#2026'
const log = (...a) => console.log('✓', ...a)
const sql = (q) => execFileSync('psql', [DB, '-Atc', q]).toString().trim()

async function createUser(email) {
  const r = await fetch(`${SB}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: PASS, email_confirm: true }) })
  const j = await r.json(); if (!j.id) throw new Error(JSON.stringify(j)); return j.id
}
async function login(browser, email, viewport = { width: 1366, height: 860 }) {
  const ctx = await browser.newContext({ viewport }); const page = await ctx.newPage()
  page.on('pageerror', (e) => console.log('PAGE ERROR', e.message))
  await page.goto(APP); await page.fill('#login-email', email); await page.fill('#login-password', PASS)
  await page.getByRole('button', { name: 'Sign in' }).last().click()
  return page
}

const browser = await chromium.launch()

// ---------- owner: café in Kuwait
const owner = await (await browser.newContext({ viewport: { width: 1366, height: 860 } })).newPage()
owner.on('pageerror', (e) => console.log('PAGE ERROR', e.message))
await owner.goto(APP)
await owner.getByRole('button', { name: 'Start 7-day free trial' }).click()
await owner.fill('#login-email', mail('owner')); await owner.fill('#login-password', PASS)
await owner.getByRole('button', { name: 'Create account' }).click()
await owner.selectOption('#ob-country', 'KW'); await owner.getByRole('button', { name: 'Next' }).click()
await owner.getByRole('button', { name: /Café or restaurant/ }).click(); await owner.getByRole('button', { name: 'Next' }).click()
await owner.fill('#ob-name', 'Bait Coffee'); await owner.fill('#ob-name-ar', 'بيت القهوة'); await owner.getByRole('button', { name: 'Next' }).click()
await owner.fill('#ob-display', 'Omar'); await owner.fill('#ob-pin', '9999'); await owner.getByRole('button', { name: 'Open my business' }).click()
await owner.getByText('Open a shift to start selling').waitFor()
const tenant = sql(`select tenant_id from memberships m join auth.users u on u.id=m.user_id where u.email='${mail('owner')}'`)
log('owner onboarded, tenant', tenant.slice(0, 8))

// products in two categories
await owner.getByRole('link', { name: 'Products' }).click()
for (const [n, ar, price, cost, cat] of [['Latte', 'لاتيه', '1.500', '0.400', 'Coffee'], ['Burger', 'برجر', '3.000', '1.000', 'Food']]) {
  await owner.getByRole('button', { name: 'Add item' }).click()
  await owner.fill('#item-name', n); await owner.fill('#item-name-ar', ar); await owner.fill('#item-price', price); await owner.fill('#item-cost', cost)
  if (n === 'Latte') await owner.fill('#item-newcat', cat); else await owner.fill('#item-newcat', cat)
  await owner.getByRole('button', { name: 'Save' }).click(); await owner.getByRole('cell', { name: n, exact: true }).waitFor()
}

// kitchen stations: add Bar, route Coffee → Bar
await owner.getByRole('link', { name: 'Settings' }).click()
await owner.getByRole('button', { name: 'Kitchen stations' }).click()
await owner.fill('#st-new', 'Bar'); await owner.getByRole('button', { name: 'Add', exact: true }).click()
await owner.locator('input[id^="st-name-"]').nth(1).waitFor()
const coffeeId = sql(`select id from categories where tenant_id='${tenant}' and name='Coffee'`)
const barId = sql(`select id from kitchen_stations where tenant_id='${tenant}' and name='Bar'`)
await owner.selectOption(`#route-${coffeeId}`, barId)
await owner.waitForTimeout(400)
await owner.screenshot({ path: `${SHOTS}/k1-stations.png` })
log('stations: Kitchen (default) + Bar; Coffee routed to Bar')

// role packages screen + custom role
await owner.getByRole('button', { name: 'Roles & permissions' }).click()
await owner.getByRole('button', { name: /^Cashier/ }).click()
await owner.locator('#lim-sale\\.discount').waitFor()
await owner.screenshot({ path: `${SHOTS}/k2-roles-cashier.png` })
await owner.getByRole('button', { name: 'New role' }).click()
await owner.fill('#nr-en', 'Night cashier'); await owner.fill('#nr-ar', 'كاشير ليلي'); await owner.selectOption('#nr-tpl', 'cashier')
await owner.getByRole('button', { name: 'Create role' }).click()
await owner.getByRole('heading', { name: 'Night cashier' }).waitFor()
await owner.locator('#lim-sale\\.discount').fill('0'); await owner.locator('#lim-sale\\.discount').blur()
await owner.waitForTimeout(500)
const nightLimit = sql(`select limit_value from role_permissions where tenant_id='${tenant}' and role like 'night_cashier%' and permission='sale.discount'`)
if (nightLimit !== '0') throw new Error(`custom role limit not saved: ${nightLimit}`)
log('custom role "Night cashier" created from Cashier template, discount limit set to 0%')

// staff accounts (invite e-mail runs in an Edge Function; here we create the accounts directly)
const staff = { kitchen: ['karim', '4444'], purchasing: ['pari', '2222'], manager: ['mona', '1111'], storekeeper: ['saad', '3333'] }
for (const [role, [name, pin]] of Object.entries(staff)) {
  const id = await createUser(mail(name))
  sql(`insert into memberships(tenant_id,user_id,role,display_name,pin_hash) values ('${tenant}','${id}','${role}','${name[0].toUpperCase() + name.slice(1)}', extensions.crypt('${pin}', extensions.gen_salt('bf')))`)
}
log('staff: Karim (kitchen), Pari (purchasing), Mona (manager), Saad (storekeeper)')

// ---------- owner sells dine-in with a kitchen note
await owner.getByRole('link', { name: 'Shift' }).click(); await owner.fill('#shift-float', '5'); await owner.getByRole('button', { name: 'Open shift' }).click()
await owner.getByText('Current shift').waitFor()
await owner.getByRole('link', { name: 'Sell' }).click()
await owner.getByRole('button', { name: 'Touch' }).click()
await owner.getByRole('button', { name: 'Dine-in' }).click(); await owner.fill('#pos-table', '7')
await owner.locator('.tile', { hasText: 'Latte' }).click(); await owner.locator('.tile', { hasText: 'Latte' }).click()
await owner.locator('.tile', { hasText: 'Burger' }).click()
await owner.getByRole('button', { name: /^Note/ }).click()
await owner.getByRole('button', { name: 'No onion' }).click(); await owner.getByRole('button', { name: 'Save' }).click()
await owner.screenshot({ path: `${SHOTS}/k3-pos-dinein.png` })
await owner.getByRole('button', { name: /^Pay/ }).click(); await owner.getByRole('button', { name: 'Add payment' }).click()
await owner.getByRole('button', { name: /Complete sale/ }).click(); await owner.getByText('Sale complete').waitFor()
await owner.getByRole('button', { name: 'New sale' }).click()
log('sale sent: table 7, 2× Latte, 1× Burger (no onion)')

// ---------- kitchen screen (Karim)
const kitchen = await login(browser, mail('karim'), { width: 1280, height: 800 })
await kitchen.getByText('All stations').waitFor()
const nav = await kitchen.locator('.side nav a').allInnerTexts()
if (nav.join(',') !== 'Kitchen') throw new Error(`kitchen nav should be only Kitchen, got ${nav}`)
await kitchen.locator('.ticket').nth(1).waitFor()
if (await kitchen.locator('.ticket').count() !== 2) throw new Error('expected 2 tickets (Bar + Kitchen)')
await kitchen.getByText('» no onion', { exact: false }).or(kitchen.getByText('No onion')).first().waitFor()
await kitchen.screenshot({ path: `${SHOTS}/k4-kds-new.png` })
const barTicket = kitchen.locator('.ticket', { hasText: 'Latte' })
await barTicket.getByRole('button', { name: 'Start' }).click()
await kitchen.locator('.kds-col.preparing .ticket', { hasText: 'Latte' }).waitFor()
await kitchen.locator('.kds-col.preparing .ticket', { hasText: 'Latte' }).getByRole('button', { name: 'Ready' }).click()
await kitchen.locator('.kds-col.ready .ticket', { hasText: 'Latte' }).waitFor()
await kitchen.locator('.kds-col.new .ticket', { hasText: 'Burger' }).getByRole('button', { name: 'Start' }).click()
await kitchen.locator('.kds-col.preparing .ticket', { hasText: 'Burger' }).waitFor()
await kitchen.screenshot({ path: `${SHOTS}/k5-kds-flow.png` })
const st = sql(`select string_agg(s.name||':'||t.status, ',' order by s.name) from kitchen_tickets t join kitchen_stations s on s.id=t.station_id where t.tenant_id='${tenant}'`)
if (st !== 'Bar:ready,Kitchen:preparing') throw new Error(`ticket states ${st}`)
log('KDS: Bar ticket → ready, Kitchen ticket → preparing; kitchen login sees only the Kitchen screen')

// ---------- purchasing officer (Pari)
const pur = await login(browser, mail('pari'))
await pur.getByRole('heading', { name: 'Purchasing' }).waitFor()
await pur.getByRole('button', { name: 'Suppliers' }).click()
await pur.getByRole('button', { name: 'Add supplier' }).click()
await pur.fill('#sup-name', 'Gulf Foods'); await pur.fill('#sup-phone', '+96522000000'); await pur.getByRole('button', { name: 'Save' }).click()
await pur.getByRole('cell', { name: 'Gulf Foods' }).waitFor()
await pur.getByRole('button', { name: 'Purchase orders' }).click()
await pur.getByRole('button', { name: 'New purchase order' }).click()
const burgerId = sql(`select id from items where tenant_id='${tenant}' and name='Burger'`)
await pur.selectOption('#po-item-0', burgerId); await pur.fill('#po-qty-0', '10'); await pur.fill('#po-cost-0', '1.2')
await pur.getByRole('button', { name: 'Save draft' }).click()
await pur.getByRole('cell', { name: /PO-000001/ }).click()
await pur.locator('.modal').getByRole('button', { name: 'Approve', exact: true }).click()
await pur.getByText('Manager approval').waitFor()
await pur.fill('#approver-pin', '2222'); await pur.getByRole('dialog', { name: 'Manager approval' }).getByRole('button', { name: 'Approve', exact: true }).click()
await pur.getByText('That PIN cannot approve this').waitFor()
log('purchasing officer cannot approve own PO (own PIN refused)')
await pur.fill('#approver-pin', '1111'); await pur.getByRole('dialog', { name: 'Manager approval' }).getByRole('button', { name: 'Approve', exact: true }).click()
await pur.locator('.modal .pill', { hasText: 'Approved' }).waitFor()
await pur.screenshot({ path: `${SHOTS}/k6-po-approved.png` })
if (await pur.getByRole('button', { name: 'Receive goods' }).count()) throw new Error('purchasing must not see Receive')
log('PO approved with manager Mona\'s PIN; purchasing has no Receive button')

// ---------- storekeeper (Saad) receives
const store = await login(browser, mail('saad'))
await store.getByRole('heading', { name: 'Purchasing' }).waitFor()
const snav = await store.locator('.side nav a').allInnerTexts()
if (snav.includes('Sell')) throw new Error('storekeeper must not sell')
await store.getByRole('cell', { name: /PO-000001/ }).click()
await store.getByRole('button', { name: 'Receive goods' }).click()
await store.getByRole('button', { name: 'Receive everything outstanding' }).click()
await store.fill('#rcv-ref', 'GF-INV-77')
await store.screenshot({ path: `${SHOTS}/k7-receive.png` })
await store.getByRole('button', { name: 'Confirm receipt' }).click()
await store.locator('.modal .pill', { hasText: 'Received' }).waitFor()
const qty = sql(`select sum(qty) from stock_movements where item_id='${burgerId}'`)
const ap = sql(`select sum(credit) from journal_lines jl join accounts a on a.id=jl.account_id where a.tenant_id='${tenant}' and a.system_key='ap'`)
if (Number(qty) !== 9 || ap !== '12000') throw new Error(`stock ${qty} ap ${ap}`)
log(`storekeeper received 10 burgers → stock 9 (1 sold), AP 12.000 KWD to Gulf Foods; nav: ${snav.join(', ')}`)

// Arabic roles screen
await owner.getByRole('button', { name: 'العربية' }).click()
await owner.getByRole('link', { name: 'الإعدادات' }).click()
await owner.getByRole('button', { name: 'الأدوار والصلاحيات' }).click()
await owner.getByRole('button', { name: /أمين مخزن/ }).click()
await owner.waitForTimeout(400)
await owner.screenshot({ path: `${SHOTS}/k8-roles-ar.png` })

await browser.close()
console.log('E2E ROLES + KDS + PURCHASING PASSED')

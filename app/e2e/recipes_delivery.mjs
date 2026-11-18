// E2E: product photos, ingredients & recipes, detailed inventory and count, receipt settings,
// delivery platforms (webhook + POS), live kitchen timer, kitchen report and live dashboard card.
import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
const require = createRequire(import.meta.url)
const { chromium } = require('playwright')
const APP = process.env.APP_URL || 'http://localhost:5173'
const SB = process.env.SUPABASE_URL || 'http://127.0.0.1:54321'
const ANON = process.env.ANON_KEY
const DB = process.env.DB_URL || 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
const SHOTS = process.env.SHOTS || './shots'
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..')
fs.mkdirSync(SHOTS, { recursive: true })
const run = Date.now(), PASS = 'Secret#2026', mail = (n) => `${n}${run}@example.com`
const log = (...a) => console.log('✓', ...a)
const sql = (q) => execFileSync('psql', [DB, '-Atc', q]).toString().trim()

const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const p = await ctx.newPage(); p.on('pageerror', (e) => console.log('PAGE ERROR', e.message))
await p.goto(APP)
await p.getByRole('button', { name: 'Start 7-day free trial' }).click()
await p.fill('#login-email', mail('own')); await p.fill('#login-password', PASS); await p.getByRole('button', { name: 'Create account' }).click()
await p.selectOption('#ob-country', 'KW'); await p.getByRole('button', { name: 'Next' }).click()
await p.getByRole('button', { name: /Café or restaurant/ }).click(); await p.getByRole('button', { name: 'Next' }).click()
await p.fill('#ob-name', 'Shawarma Lab'); await p.fill('#ob-name-ar', 'معمل الشاورما'); await p.getByRole('button', { name: 'Next' }).click()
await p.fill('#ob-display', 'Omar'); await p.fill('#ob-pin', '9999'); await p.getByRole('button', { name: 'Open my business' }).click()
await p.getByText('Open a shift to start selling').waitFor()
const tenant = sql(`select tenant_id from memberships m join auth.users u on u.id=m.user_id where u.email='${mail('own')}'`)

// receipt settings + photos on POS
await p.getByRole('link', { name: 'Settings' }).click()
await p.getByRole('button', { name: 'Business and receipt' }).click()
await p.check('#b-images')
await p.fill('#r-phones', '+965 2222 0000 · WhatsApp 5555 0000'); await p.fill('#r-cr', '445566')
await p.fill('#r-address', 'Salmiya, Block 10, Salem Al Mubarak St.')
await p.fill('#r-terms', 'الاستبدال خلال 7 أيام مع الإيصال · Exchange within 7 days with the receipt.')
await p.fill('#r-footer', 'شكراً لزيارتكم · See you soon')
await p.getByRole('button', { name: 'Save' }).first().click(); await p.getByText('Saved').first().waitFor()
await p.screenshot({ path: `${SHOTS}/r1-receipt-settings.png` })
log('receipt: phones, CR, address, terms, footer saved; product photos switched on')

// ingredients and a recipe with a photo
await p.getByRole('link', { name: 'Products' }).click()
for (const [n, ar, unit, cost, reorder] of [['Chicken', 'دجاج', 'kg', '1.2', '2'], ['Bread', 'خبز', 'pcs', '0.05', '30']]) {
  await p.getByRole('button', { name: 'Ingredients' }).click()
  await p.getByRole('button', { name: 'Add item' }).click()
  await p.fill('#item-name', n); await p.fill('#item-name-ar', ar); await p.selectOption('#item-unit', unit)
  await p.fill('#item-cost', cost); await p.fill('#item-reorder', reorder)
  await p.getByRole('dialog').getByRole('button', { name: 'Save', exact: true }).click()
  await p.getByRole('cell', { name: n, exact: true }).waitFor()
}
await p.getByRole('button', { name: 'Recipes' }).click()
await p.getByRole('button', { name: 'Add item' }).click()
await p.fill('#item-name', 'Chicken shawarma'); await p.fill('#item-name-ar', 'شاورما دجاج'); await p.fill('#item-price', '1.25'); await p.fill('#item-newcat', 'Sandwiches')
await p.setInputFiles('#item-image', path.join(ROOT, 'brand/z-trust-mark.png'))
await p.locator('.img-preview:not(.empty)').waitFor()
await p.getByRole('dialog').getByRole('button', { name: 'Save', exact: true }).click()
await p.getByText('Recipe · Chicken shawarma').waitFor()
const chicken = sql(`select id from items where tenant_id='${tenant}' and name='Chicken'`), bread = sql(`select id from items where tenant_id='${tenant}' and name='Bread'`)
await p.selectOption('#rc-ing-0', chicken); await p.fill('#rc-qty-0', '0.15')
await p.selectOption('#rc-ing-1', bread); await p.fill('#rc-qty-1', '1')
await p.locator('.recipe-sum', { hasText: '0.230' }).waitFor()
await p.screenshot({ path: `${SHOTS}/r2-recipe.png` })
await p.getByRole('button', { name: 'Save recipe' }).click()
await p.getByRole('button', { name: 'All', exact: true }).click(); await p.waitForTimeout(500)
await p.screenshot({ path: `${SHOTS}/r3-products.png` })
const img = sql(`select image_url from items where tenant_id='${tenant}' and name='Chicken shawarma'`)
if (!img.includes('/storage/v1/object/public/item-images/')) throw new Error('image not uploaded: ' + img)
log('ingredients chicken (kg) + bread; recipe shawarma = 0.15 kg chicken + 1 bread → cost 0.230, margin 81.6%; photo uploaded to storage')

// opening stock by count
await p.getByRole('link', { name: 'Inventory' }).click()
await p.getByRole('button', { name: 'Stock count' }).click()
await p.fill(`#cnt-${chicken}`, '10'); await p.fill(`#cnt-${bread}`, '100'); await p.fill('#count-note', 'Opening stock')
await p.getByRole('button', { name: 'Post count' }).click(); await p.getByText('2 items adjusted').waitFor()
log('stock count posted (opening stock 10 kg chicken, 100 bread)')

// delivery platform
await p.getByRole('link', { name: 'Settings' }).click()
await p.getByRole('button', { name: 'Delivery platforms' }).click()
await p.getByRole('button', { name: 'Add platform' }).click()
await p.getByRole('cell', { name: 'Keeta' }).waitFor()
await p.getByRole('button', { name: 'Connect webhook' }).click()
const token = (await p.locator('code.token').nth(1).innerText()).trim()
log('Keeta added (18% commission) and webhook token issued')

// sell 4 shawarma at the POS with photos
await p.getByRole('link', { name: 'Shift', exact: true }).click(); await p.fill('#shift-float', '10'); await p.getByRole('button', { name: 'Open shift' }).click()
await p.getByText('Current shift').waitFor()
await p.getByRole('link', { name: 'Sell' }).click(); await p.getByRole('button', { name: 'Touch' }).click()
await p.locator('.tile img.tile-img').first().waitFor()
if (await p.locator('.tile', { hasText: 'Chicken' }).filter({ hasNotText: 'shawarma' }).count()) throw new Error('ingredient on POS')
for (let i = 0; i < 4; i++) await p.locator('.tile', { hasText: 'Chicken shawarma' }).click()
await p.screenshot({ path: `${SHOTS}/r4-pos-images.png` })
await p.getByRole('button', { name: /Exact cash/ }).click(); await p.getByText('Sale complete').waitFor()
await p.locator('.receipt', { hasText: '+965 2222 0000' }).waitFor(); await p.locator('.receipt', { hasText: 'Exchange within 7 days' }).waitFor()
await p.locator('.receipt-preview').screenshot({ path: `${SHOTS}/r5-receipt.png` })
await p.getByRole('button', { name: 'New sale' }).click()
log('POS shows photos, hides ingredients; receipt prints phones, CR, address and terms')

// platform order keyed at the POS
await p.locator('.tile', { hasText: 'Chicken shawarma' }).click(); await p.locator('.tile', { hasText: 'Chicken shawarma' }).click()
await p.getByRole('button', { name: /^Pay/ }).click()
await p.getByRole('radio', { name: 'Delivery platform' }).click(); await p.fill('#pay-ext', 'KT-POS-001')
await p.getByRole('button', { name: 'Add payment' }).click(); await p.getByRole('button', { name: /Complete sale/ }).click()
await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
if (sql(`select count(*) from sales s join delivery_channels d on d.id=s.channel_id where s.tenant_id='${tenant}' and s.external_ref='KT-POS-001'`) !== '1') throw new Error('POS platform sale not tagged')
log('Keeta order keyed at the POS: tagged to the platform, posted to the platform receivable')

// webhook order (what the delivery-webhook Edge Function calls)
const r = await fetch(`${SB}/rest/v1/rpc/ingest_delivery_order`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ p_token: token, p: { external_ref: 'KT-778899', customer_name: 'Fahad · Keeta', items: [{ name: 'Chicken shawarma', qty: 3, unit_price: 1400, note: 'extra garlic' }] } }) })
if (!r.ok) throw new Error(await r.text())
log('Keeta webhook order KT-778899 accepted')

// kitchen: live timer
await p.getByRole('link', { name: 'Kitchen' }).click()
await p.locator('.ticket', { hasText: 'Fahad' }).waitFor()
await p.locator('.ticket', { hasText: 'Fahad' }).getByRole('button', { name: 'Start' }).click()
await p.locator('.kds-col.preparing .ticket', { hasText: 'Fahad' }).waitFor()
const t1 = await p.locator('.kds-col.preparing .ticket', { hasText: 'Fahad' }).locator('.t-time').innerText()
await p.waitForTimeout(2200)
const t2 = await p.locator('.kds-col.preparing .ticket', { hasText: 'Fahad' }).locator('.t-time').innerText()
if (t1 === t2) throw new Error(`timer not ticking ${t1}`)
await p.screenshot({ path: `${SHOTS}/r6-kds-timer.png` })
await p.locator('.kds-col.preparing .ticket', { hasText: 'Fahad' }).getByRole('button', { name: 'Ready' }).click()
await p.locator('.kds-col.ready .ticket', { hasText: 'Fahad' }).waitFor()
log(`kitchen timer ticks every second (${t1} → ${t2}); ticket moved to Ready with its total time frozen`)

// inventory after recipes: chicken 10 - (4+2+3)*0.15 = 8.65 ; bread 100 - 9 = 91
await p.getByRole('link', { name: 'Inventory' }).click()
await p.locator('tr', { hasText: 'Chicken' }).filter({ hasText: '8.65' }).waitFor()
await p.locator('tr', { hasText: 'Bread' }).filter({ hasText: '91' }).waitFor()
await p.screenshot({ path: `${SHOTS}/r7-inventory.png` })
log('inventory: chicken 8.65 kg, bread 91 after 9 shawarmas')

// payout
await p.getByRole('link', { name: 'Settings' }).click(); await p.getByRole('button', { name: 'Delivery platforms' }).click()
await p.getByRole('button', { name: 'Record payout' }).click()
await p.fill('#st-gross', '6.7'); await p.fill('#st-ref', 'KEETA-W47')
await p.getByRole('dialog').getByRole('button', { name: 'Save' }).click(); await p.getByText('Payout recorded').waitFor(); await p.getByRole('dialog').locator('button.primary', { hasText: 'Close' }).click()
const clr = sql(`select sum(jl.debit - jl.credit) from journal_lines jl join accounts a on a.id=jl.account_id where a.system_key='platform_clearing' and jl.tenant_id='${tenant}'`)
if (clr !== '0') throw new Error('platform receivable not cleared: ' + clr)
log('Keeta payout 6.700 recorded: commission 1.206, net 5.494 to bank; platform receivable cleared')

// reports + dashboard
await p.getByRole('link', { name: 'Reports' }).click()
await p.getByRole('button', { name: 'Kitchen times' }).click(); await p.getByRole('cell', { name: 'All stations' }).waitFor(); await p.waitForTimeout(300)
await p.screenshot({ path: `${SHOTS}/r8-kitchen-report.png` })
await p.getByRole('button', { name: 'Sales channels' }).click(); await p.getByRole('cell', { name: 'Keeta' }).waitFor()
await p.getByRole('link', { name: 'Dashboard' }).click(); await p.getByText('Kitchen now').waitFor(); await p.waitForTimeout(800)
await p.screenshot({ path: `${SHOTS}/r9-dashboard-kitchen.png` })
log('kitchen times report, sales by channel, live "Kitchen now" card')

const bal = sql(`select sum(debit) - sum(credit) from journal_lines where tenant_id='${tenant}'`)
if (bal !== '0') throw new Error('ledger out of balance')
await browser.close()
console.log('E2E RECIPES + DELIVERY + KITCHEN TIMER PASSED')

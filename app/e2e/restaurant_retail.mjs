// E2E: restaurant & retail wave — quantity tiers, loyalty tier + punch card at the till, delivery zone fee, coursing on the KDS,
// store checklist, menu engineering, digital receipt link, payroll deductions.
import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
const require = createRequire(import.meta.url)
const { chromium } = require('playwright')
const APP = process.env.APP_URL || 'http://localhost:5173'
const DB = process.env.DB_URL || 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
const SHOTS = process.env.SHOTS || './shots'
fs.mkdirSync(SHOTS, { recursive: true })
const run = Date.now(), PASS = 'Secret#2026'
const mail = (n) => `${n}${run}@example.com`
const log = (...a) => console.log('✓', ...a)
const sql = (q) => execFileSync('psql', [DB, '-Atc', q]).toString().trim()
const assert = (c, m) => { if (!c) throw new Error('ASSERT: ' + m) }

const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } })
const p = await ctx.newPage()
p.on('pageerror', (e) => console.log('PAGE ERROR', e.message))
await p.addInitScript(() => { window.print = () => setTimeout(() => window.dispatchEvent(new Event('afterprint')), 50) })

await p.goto(APP)
await p.getByRole('button', { name: 'Start 7-day free trial' }).click()
await p.fill('#login-email', mail('own')); await p.fill('#login-password', PASS); await p.getByRole('button', { name: 'Create account' }).click()
await p.selectOption('#ob-country', 'KW'); await p.getByRole('button', { name: 'Next' }).click()
await p.getByRole('button', { name: /^Restaurant/ }).click(); await p.getByRole('button', { name: 'Next' }).click()
await p.fill('#ob-name', 'Bait Burger'); await p.getByRole('button', { name: 'Next' }).click()
await p.fill('#ob-display', 'Nora'); await p.fill('#ob-pin', '9999'); await p.getByRole('button', { name: 'Open my business' }).click()
await p.getByText('Open a shift to start selling').waitFor()
const T = sql(`select tenant_id from memberships m join auth.users u on u.id=m.user_id where u.email='${mail('own')}'`)
sql(`update tenants set features = features || '{"own_delivery":true,"loyalty":true,"promotions":true}', settings = settings || '{"loyalty_earn":1}' where id='${T}'`)
sql(`insert into items(tenant_id,name,price,cost,course) values ('${T}','Soup',1000,300,1),('${T}','Burger',3000,1200,2),('${T}','Coffee',1000,200,null)`)
sql(`insert into customers(tenant_id,name,phone) values ('${T}','Fahad','+96550000001')`)
await p.reload(); await p.locator('aside nav').waitFor()

// ---- promotions page: quantity tiers, a loyalty tier, a punch card
await p.getByRole('link', { name: 'Promotions' }).click()
await p.getByRole('button', { name: 'New promotion' }).click()
await p.getByRole('button', { name: /^Quantity tiers/ }).click()
await p.fill('#promo-name', 'Burger tiers'); await p.fill('#tier-at-0', '3'); await p.fill('#tier-pct-0', '10')
await p.getByRole('dialog').getByRole('button', { name: 'Save' }).click()
await p.getByText(/3\+ → 10%/).waitFor()
await p.fill('#tier-name', 'Gold'); await p.fill('#tier-min', '0'); await p.fill('#tier-mult', '2'); await p.getByRole('button', { name: 'Add tier' }).last().click()
await p.getByText('points ×2').waitFor()
await p.fill('#pc-name', 'Coffee card'); await p.fill('#pc-needed', '3')
const coffee = sql(`select id from items where tenant_id='${T}' and name='Coffee'`)
await p.selectOption('#pc-scope', `i:${coffee}`); await p.selectOption('#pc-reward', coffee)
await p.getByRole('button', { name: 'Add punch card' }).click(); await p.getByText('3 punches').waitFor()
await p.screenshot({ path: `${SHOTS}/rr-1-promotions-loyalty.png`, fullPage: true })
log('promotions: quantity tiers, Gold tier ×2 points, coffee punch card 3 → free coffee')

// ---- settings: delivery zone and opening checklist
await p.getByRole('link', { name: 'Settings' }).click()
await p.getByRole('button', { name: 'Business and receipt' }).click()
await p.fill('#zone-name', 'Salmiya'); await p.fill('#zone-fee', '0.5'); await p.fill('#zone-min', '2'); await p.getByRole('button', { name: 'Add zone' }).click()
await p.getByText('Salmiya', { exact: true }).waitFor()
await p.fill('#ck-name', 'Opening'); await p.fill('#ck-items', 'Lights on\nFloat counted'); await p.getByRole('button', { name: 'Add checklist' }).click()
await p.getByText('Lights on · Float counted').waitFor()
log('settings: delivery zone Salmiya (fee 0.500, min 2.000), opening checklist')

// ---- shift + checklist
await p.getByRole('link', { name: 'Shift', exact: true }).click(); await p.fill('#shift-float', '20'); await p.getByRole('button', { name: 'Open shift' }).click()
await p.getByText('Current shift').waitFor()
await p.getByLabel('Lights on').click(); await p.waitForTimeout(600); await p.getByLabel('Float counted').click(); await p.waitForTimeout(800)
assert(sql(`select count(*) from checklist_runs where tenant_id='${T}' and completed_at is not null`) === '1', 'checklist completed')
log('shift: opening checklist ticked (who and when kept)')

// ---- POS: customer with Gold tier, 3 coffees → punch card full → free coffee
await p.getByRole('link', { name: 'Sell' }).click()
await p.getByRole('button', { name: 'Touch' }).click().catch(() => {})
await p.getByRole('button', { name: /Walk-in customer/ }).click(); await p.fill('#cust-search', 'Fahad'); await p.getByRole('button', { name: /^Fahad/ }).click()
await p.locator('.badge.tier', { hasText: 'Gold' }).waitFor()
for (let i = 0; i < 3; i++) await p.locator('.tile', { hasText: 'Coffee' }).click()
await p.getByRole('button', { name: /^Card/ }).click(); await p.getByText('Sale complete').waitFor()
await p.getByText('Digital receipt').waitFor()
const token = sql(`select public_token from sales where tenant_id='${T}' order by created_at desc limit 1`)
await p.getByRole('button', { name: 'New sale' }).click()
assert(sql(`select sum(points) from loyalty_ledger where tenant_id='${T}'`) === '5', 'Gold: 2.700 (after the 10% tier) × 2 = 5 points')
await p.getByRole('button', { name: /Walk-in customer/ }).click(); await p.fill('#cust-search', 'Fahad'); await p.getByRole('button', { name: /^Fahad/ }).click()
await p.getByRole('button', { name: /Coffee card · 3\/3 · Redeem/ }).click()
await p.getByText('Punch card').first().waitFor()
await p.screenshot({ path: `${SHOTS}/rr-2-pos-punch-card.png` })
await p.getByRole('button', { name: /^Confirm/ }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
assert(sql(`select coalesce(sum(punches),0) from punch_moves where tenant_id='${T}'`) === '0', 'card used')
log('POS: 3 coffees get the 10% quantity tier (2.700), Gold doubles points (5); the card fills; 4th coffee free')

// ---- delivery with zone fee, courses held in the kitchen
await p.getByRole('button', { name: /Walk-in customer/ }).click(); await p.fill('#cust-search', 'Fahad'); await p.getByRole('button', { name: /^Fahad/ }).click()
await p.locator('.tile', { hasText: 'Soup' }).click(); await p.locator('.tile', { hasText: 'Burger' }).click()
await p.getByRole('button', { name: /^Own delivery/ }).click()
await p.fill('#dl-address', 'Block 1, Street 2'); await p.selectOption('#dl-zone', { index: 1 })
await p.getByRole('dialog').getByRole('button', { name: 'Save' }).click()
await p.getByText(/Delivery fee · Salmiya/).waitFor()
await p.screenshot({ path: `${SHOTS}/rr-3-delivery-zone.png` })
await p.getByRole('button', { name: /Exact cash/ }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
assert(sql(`select fee from deliveries where tenant_id='${T}'`) === '500', 'zone fee on the delivery')
await p.getByRole('link', { name: 'Kitchen' }).click()
await p.getByText('waiting').first().waitFor()
await p.screenshot({ path: `${SHOTS}/rr-4-kds-courses.png` })
await p.getByRole('button', { name: /^Fire/ }).first().click(); await p.waitForTimeout(800)
assert(sql(`select count(*) from kitchen_ticket_items i join kitchen_tickets k on k.id=i.ticket_id where k.tenant_id='${T}' and i.held`) === '0', 'mains fired')
log('delivery: zone fee 0.500 added; KDS holds mains until "Fire Mains"')

// ---- menu engineering, public receipt, payroll deductions
await p.getByRole('link', { name: 'Reports' }).click(); await p.getByRole('button', { name: 'Menu engineering' }).click()
await p.getByRole('cell', { name: /Star|Plowhorse|Puzzle|Dog/ }).first().waitFor()
await p.screenshot({ path: `${SHOTS}/rr-5-menu-engineering.png` })
const pub = await (await browser.newContext()).newPage()
await pub.goto(`${APP}/r/${token}`); await pub.getByText('2.700').first().waitFor()
await pub.screenshot({ path: `${SHOTS}/rr-6-digital-receipt.png` })
sql(`insert into employees(tenant_id,name,basic_salary,allowances,insurance_pct,insurance_employer_pct,fixed_deduction,fixed_deduction_label) values ('${T}','Ali',400000,100000,10.5,11.5,20000,'Housing')`)
await p.getByRole('link', { name: 'HR & payroll' }).click(); await p.getByRole('tab', { name: 'Payroll' }).click(); await p.getByRole('button', { name: 'Prepare payroll' }).click()
await p.getByRole('columnheader', { name: 'Total deductions' }).waitFor(); await p.getByText('−62.000').first().waitFor()
await p.screenshot({ path: `${SHOTS}/rr-7-payroll-deductions.png` })
log('menu engineering classes; public receipt link opens without login; payroll shows insurance 42.000 + housing 20.000 = 62.000 deductions')

assert(sql(`select sum(debit)=sum(credit) from journal_lines where tenant_id='${T}'`) === 't', 'ledger balanced')
console.log('E2E RESTAURANT & RETAIL PASSED')
await browser.close()

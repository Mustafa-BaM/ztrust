// E2E for the growth additions:
//   gym: membership sold, then check-in from the customer card
//   café: QR table order → staff accepts → kitchen; kiosk order → paid at the till; customer display follows the cart;
//         gift card sold and spent; own delivery with cash on delivery → driver → cash handed in;
//         reservations and waitlist; branch transfer; production; attendance by geofence
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
const log = (...a) => console.log('✓', ...a)
const sql = (q) => execFileSync('psql', [DB, '-Atc', q]).toString().trim()
const must = (c, m) => { if (!c) throw new Error(m) }
const BRANCH_GEO = { latitude: 29.3375, longitude: 47.9406 }   // a point in Kuwait City

const browser = await chromium.launch()
async function business(profile, name, who) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, permissions: ['geolocation'], geolocation: BRANCH_GEO })
  const p = await ctx.newPage(); p.on('pageerror', (e) => console.log('PAGE ERROR', e.message))
  await p.goto(APP)
  await p.getByRole('button', { name: 'Start 7-day free trial' }).click()
  const email = `${profile.replace(/\W/g, '').toLowerCase()}g${run}@example.com`
  await p.fill('#login-email', email); await p.fill('#login-password', PASS); await p.getByRole('button', { name: 'Create account' }).click()
  await p.selectOption('#ob-country', 'KW'); await p.getByRole('button', { name: 'Next' }).click()
  await p.getByRole('button', { name: new RegExp('^' + profile.replace(/[&]/g, '.')) }).click(); await p.getByRole('button', { name: 'Next' }).click()
  await p.fill('#ob-name', name); await p.getByRole('button', { name: 'Next' }).click()
  await p.fill('#ob-display', who); await p.fill('#ob-pin', '9999'); await p.getByRole('button', { name: 'Open my business' }).click()
  await p.getByText('Open a shift to start selling').waitFor()
  const tenant = sql(`select t.id from tenants t join memberships m on m.tenant_id=t.id join auth.users u on u.id=m.user_id where u.email='${email}'`)
  return { p, ctx, tenant }
}
async function openShift(p) { await p.getByRole('link', { name: 'Shift' }).click(); await p.fill('#shift-float', '10'); await p.getByRole('button', { name: 'Open shift' }).click(); await p.getByText('Current shift').waitFor() }
async function addItem(p, f) {
  await p.getByRole('link', { name: 'Products' }).click(); await p.getByRole('button', { name: 'Add item' }).click()
  if (f.type) await p.locator('.type-seg button', { hasText: f.type }).click()
  await p.fill('#item-name', f.name); if (f.price) await p.fill('#item-price', f.price)
  if (f.cost) await p.fill('#item-cost', f.cost)
  if (f.pkg) { await p.selectOption('#pkg-kind', f.pkg.kind); await p.fill('#pkg-days', f.pkg.days) }
  await p.getByRole('button', { name: 'Save', exact: true }).click(); await p.locator('tbody td', { hasText: new RegExp('^' + f.name) }).first().waitFor()
}
async function modules(p, names) {
  await p.getByRole('link', { name: 'Settings' }).click(); await p.getByRole('button', { name: 'Business type & modules' }).click()
  for (const n of names) { await p.getByRole('switch', { name: n }).click(); await p.getByText(`${n} switched on`).waitFor() }
}

// ======================================================================= gym: membership + check-in
{
  const { p, ctx, tenant } = await business('Gym & fitness', 'Iron Gym', 'Saud')
  await addItem(p, { name: 'Monthly membership', price: '25.000', type: 'Package', pkg: { kind: 'unlimited', days: '30' } })
  await openShift(p)
  await p.getByRole('link', { name: 'Sell' }).click(); await p.getByRole('button', { name: 'Touch' }).click()
  await p.getByRole('button', { name: /Walk-in customer/ }).click(); await p.fill('#cust-new-name', 'Faris'); await p.getByRole('dialog').getByRole('button', { name: 'Add', exact: true }).click()
  await p.locator('.tile', { hasText: 'Monthly membership' }).click(); await p.getByRole('button', { name: 'Card' }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
  await p.getByRole('link', { name: 'Customers' }).click(); await p.getByRole('cell', { name: 'Faris' }).click()
  await p.getByRole('button', { name: 'Check in' }).click(); await p.getByText(/Checked in · visit 1/).waitFor()
  await p.screenshot({ path: `${SHOTS}/g1-gym-checkin.png` })
  must(sql(`select count(*) from package_uses u join customer_packages c on c.id=u.package_id where c.tenant_id='${tenant}'`) === '1', 'visit recorded')
  log('gym: monthly membership sold, member checked in (visit 1)')
  await ctx.close()
}

// ======================================================================= café
const { p, ctx, tenant } = await business('Café', 'Qahwa Lab', 'Omar')
await modules(p, ['QR table ordering & kiosk', 'Own delivery drivers', 'Customer display', 'Gift cards', 'Reservations & waitlist', 'Tables & floor plan', 'Production (central kitchen)', 'Staff attendance', 'Branch transfers'])
const slug = `qahwa-${run}`
await p.getByRole('button', { name: 'Business and receipt' }).click()
await p.fill('#book-slug', slug)
await p.fill('#br-lat', String(BRANCH_GEO.latitude)); await p.fill('#br-lng', String(BRANCH_GEO.longitude)); await p.fill('#br-radius', '150')
await p.locator('.card', { hasText: 'Selling rules' }).getByRole('button', { name: 'Save' }).click(); await p.locator('.card', { hasText: 'Selling rules' }).getByText('Saved').waitFor()
await p.getByRole('button', { name: 'Tables', exact: true }).click(); await p.fill('#tb-name', 'T1-T4'); await p.getByRole('button', { name: 'Add', exact: true }).click(); await p.getByRole('cell', { name: 'T4' }).waitFor()
await p.getByRole('button', { name: 'Staff', exact: true }).click(); await p.getByLabel('Driver').check()
await addItem(p, { name: 'Latte', price: '1.500', cost: '0.400' })
await addItem(p, { name: 'Gift card', price: '10.000', type: 'Gift card' })
log('café: QR ordering, own delivery, display, gift cards, reservations, tables, production and attendance switched on')

// ---- a guest orders from table T1 by QR
const token = sql(`select qr_token from dining_tables where tenant_id='${tenant}' and name='T1'`)
const guest = await browser.newPage({ viewport: { width: 390, height: 844 } })
await guest.goto(`${APP}/order/${slug}?t=${token}`)
await guest.getByRole('button', { name: /Latte/ }).click(); await guest.getByRole('button', { name: /Latte/ }).click()
await guest.getByRole('button', { name: /View order/ }).click(); await guest.fill('#ord-name', 'Ali')
await guest.screenshot({ path: `${SHOTS}/g2-qr-order.png` })
await guest.getByRole('button', { name: /Send order/ }).click(); await guest.getByText('Your order number').waitFor()
await openShift(p)
await p.getByRole('link', { name: 'Sell' }).click(); await p.getByRole('button', { name: 'Touch' }).click()
await p.getByRole('button', { name: /Online orders/ }).click()
await p.screenshot({ path: `${SHOTS}/g3-online-orders.png` })
await p.getByRole('button', { name: 'Accept and send to kitchen' }).click(); await p.getByText('No orders waiting.').waitFor(); await p.keyboard.press('Escape')
must(sql(`select count(*) from kitchen_tickets where tenant_id='${tenant}'`) === '1', 'QR order in the kitchen')
must(sql(`select jsonb_array_length(lines) from open_orders where tenant_id='${tenant}' and status='open'`) === '1', 'QR order on table T1')
await guest.getByText('Confirmed and sent to the kitchen.').waitFor({ timeout: 20000 })
log('QR: guest ordered 2 lattes from T1, staff accepted, kitchen ticket created, guest sees “confirmed”')

// ---- kiosk order, paid at the till; the customer display follows the cart
const kiosk = await browser.newPage({ viewport: { width: 1080, height: 1400 } })
await kiosk.goto(`${APP}/order/${slug}?kiosk=1`)
await kiosk.getByRole('button', { name: /Latte/ }).click(); await kiosk.getByRole('button', { name: /View order/ }).click()
await kiosk.getByRole('button', { name: /Order and pay at the counter/ }).click(); await kiosk.getByText('Please pay at the counter').waitFor()
const display = await ctx.newPage(); await display.goto(`${APP}/display`)
await p.getByRole('button', { name: /Online orders/ }).click(); await p.getByRole('button', { name: 'Take payment' }).click()
await display.getByText('1.500').first().waitFor()
await display.screenshot({ path: `${SHOTS}/g4-customer-display.png` })
await p.getByRole('button', { name: 'Exact cash' }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
must(sql(`select status from online_orders where tenant_id='${tenant}' and source='kiosk'`) === 'paid', 'kiosk order paid')
log('kiosk order taken at the till and paid; customer display showed the cart live')

// ---- gift card: sold, then spent
await p.locator('.tile', { hasText: 'Gift card' }).click(); await p.fill('#gc-amount', '10'); await p.getByRole('button', { name: 'Add to sale' }).click()
await p.getByRole('button', { name: 'Exact cash' }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
const code = sql(`select code from gift_cards where tenant_id='${tenant}'`)
must(/^GC[0-9A-F]{10}$/.test(code), 'gift card code ' + code)
await p.locator('.tile', { hasText: 'Latte' }).click(); await p.getByRole('button', { name: /^Pay/ }).click()
await p.getByRole('radio', { name: 'Gift card' }).click(); await p.fill('#pay-gift', code); await p.locator('#pay-gift').blur(); await p.getByText(/Balance/).waitFor()
await p.getByRole('button', { name: 'Add payment' }).click(); await p.getByRole('button', { name: /Complete sale/ }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
must(sql(`select balance from gift_cards where code='${code}'`) === '8500', 'gift card 10.000 − 1.500 = 8.500')
log(`gift card ${code} sold for 10.000 (no VAT, held as a liability) and used for a latte: balance 8.500`)

// ---- own delivery, cash on delivery, driver, cash handed in
await p.getByRole('button', { name: /Walk-in customer/ }).click(); await p.fill('#cust-search', '+96550007777'); await p.fill('#cust-new-name', 'Mona'); await p.getByRole('dialog').getByRole('button', { name: 'Add', exact: true }).click()
await p.locator('.tile', { hasText: 'Latte' }).click(); await p.locator('.tile', { hasText: 'Latte' }).click()
await p.getByRole('button', { name: 'Own delivery' }).click(); await p.fill('#dl-address', 'Salmiya, block 10, street 5, house 12')
await p.getByRole('button', { name: 'Save', exact: true }).click()
await p.getByRole('button', { name: /^Pay/ }).click(); await p.getByRole('radio', { name: 'Cash on delivery' }).click(); await p.getByRole('button', { name: 'Add payment' }).click()
await p.getByRole('button', { name: /Complete sale/ }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
await p.getByRole('link', { name: 'Deliveries' }).click()
await p.getByLabel('Driver').selectOption({ label: 'Omar' })
await p.getByRole('button', { name: 'My deliveries' }).click(); await p.getByRole('button', { name: 'Picked up' }).click(); await p.getByRole('button', { name: 'Delivered' }).click()
await p.getByRole('button', { name: 'All deliveries' }).click(); await p.getByRole('button', { name: 'Receive cash' }).click(); await p.getByText('Cash received into the drawer').waitFor()
await p.screenshot({ path: `${SHOTS}/g5-deliveries.png` })
must(sql(`select coalesce(sum(jl.debit-jl.credit),0) from journal_lines jl join accounts a on a.id=jl.account_id where a.system_key='cod_clearing' and jl.tenant_id='${tenant}'`) === '0', 'cash with drivers cleared')
log('own delivery: cash on delivery 3.000, assigned, picked up, delivered, cash handed into the drawer')

// ---- reservations & waitlist
await p.getByRole('link', { name: 'Reservations' }).click(); await p.getByRole('button', { name: 'New reservation' }).click()
await p.fill('#rs-name', 'Khalid'); await p.fill('#rs-party', '4'); await p.selectOption('#rs-table', { index: 1 }); await p.getByRole('button', { name: 'Save', exact: true }).click()
await p.getByRole('cell', { name: /Khalid/ }).waitFor()
await p.fill('#wl-name', 'Sara'); await p.fill('#wl-phone', '+96550008888'); await p.locator('form', { has: p.locator('#wl-name') }).getByRole('button', { name: 'Add' }).click(); await p.getByText('1. Sara').waitFor()
await p.screenshot({ path: `${SHOTS}/g6-reservations.png` })
await p.getByRole('button', { name: 'Seat' }).first().click()
log('reservation for 4 at a table, waitlist with “table ready” on WhatsApp')

// ---- branch transfer and production
sql(`insert into branches(tenant_id, code, name, timezone) values ('${tenant}', 'B02', 'Avenues', 'Asia/Kuwait')`)
const latte = sql(`select id from items where tenant_id='${tenant}' and name='Latte'`), b1 = sql(`select id from branches where tenant_id='${tenant}' and code='B01'`)
sql(`update items set track_stock = true where id='${latte}'; insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost) values ('${tenant}','${b1}','${latte}', 20, 'receipt', 400)`)
await p.reload(); await p.getByRole('link', { name: 'Inventory' }).click(); await p.getByRole('button', { name: 'Transfers' }).click()
await p.selectOption('#tr-to', { label: 'Avenues' }); await p.getByLabel('Item').selectOption({ label: 'Latte' }); await p.getByLabel('Qty').fill('5')
await p.getByRole('button', { name: 'Send transfer' }).click(); await p.getByText('Transfer sent').waitFor()
await p.selectOption('#branch-select', { label: 'Avenues' }); await p.getByRole('button', { name: 'Transfers' }).click()
await p.getByRole('button', { name: 'Confirm arrival' }).click(); await p.getByText('Received into stock').waitFor()
const b2 = sql(`select id from branches where tenant_id='${tenant}' and code='B02'`)
must(sql(`select sum(qty) from stock_movements where item_id='${latte}' and branch_id='${b2}'`) === '5.000', 'arrived in Avenues')
await p.selectOption('#branch-select', { label: 'Main branch' })
const flour = sql(`insert into items(tenant_id, name, item_type, unit, cost, price) values ('${tenant}', 'Flour', 'ingredient', 'kg', 300, 0) returning id`).split('\n')[0]
const bread = sql(`insert into items(tenant_id, name, price, cost) values ('${tenant}', 'Bread loaf', 750, 0) returning id`).split('\n')[0]
sql(`insert into recipe_lines(tenant_id, item_id, ingredient_id, qty) values ('${tenant}', '${bread}', '${flour}', 0.5); insert into stock_movements(tenant_id, branch_id, item_id, qty, reason, unit_cost) values ('${tenant}','${b1}','${flour}', 20, 'receipt', 300)`)
await p.reload(); await p.getByRole('button', { name: 'Production' }).click()
await p.selectOption('#prod-item', { label: 'Bread loaf' }); await p.fill('#prod-qty', '10'); await p.getByRole('button', { name: 'Record production' }).click()
await p.getByText(/10 × Bread loaf produced · cost 0.150 each/).waitFor()
must(sql(`select sum(qty) from stock_movements where item_id='${flour}'`) === '15.000', 'flour used 5 kg')
log('transfer of 5 lattes to Avenues confirmed on arrival; 10 loaves produced from 5 kg flour at 0.150 each')

// ---- attendance: inside the circle works, outside is refused
await p.getByRole('link', { name: 'Attendance' }).click(); await p.getByRole('button', { name: /Clock in/ }).click(); await p.locator('.clock-card [role=status]').waitFor(); console.log('clock:', await p.locator('.clock-card [role=status]').innerText()); await p.getByText('Clocked in').waitFor()
await p.screenshot({ path: `${SHOTS}/g7-attendance.png` })
await ctx.setGeolocation({ latitude: 29.3759, longitude: 47.9774 })   // ~5 km away
await p.getByRole('button', { name: /Clock out/ }).click(); await p.getByText(/You are \d+ m from the branch/).waitFor()
log('attendance: clock-in at the branch accepted; clock-out 5 km away refused')

must(sql(`select sum(debit)-sum(credit) from journal_lines where tenant_id='${tenant}'`) === '0', 'ledger balanced')
await browser.close()
console.log('GROWTH E2E PASSED')

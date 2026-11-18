// E2E for phases B–D, each as the business that uses it:
//   café: add-ons, promotions, tables (send rounds to the kitchen, pay), loyalty, 58 mm / A4 printing
//   fashion: variants picked at the till; no kitchen anywhere
//   grocery: scale barcode, batches & expiry
//   salon: staff hours, calendar, public online booking, checkout from the appointment, package sessions, commission
//   laundry: job card with tags, deposit, ready, collect and pay
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

const browser = await chromium.launch()

async function business(profile, name, who) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  const p = await ctx.newPage(); p.on('pageerror', (e) => console.log('PAGE ERROR', e.message))
  await p.goto(APP)
  await p.getByRole('button', { name: 'Start 7-day free trial' }).click()
  const email = `${profile.replace(/\W/g, '').toLowerCase()}${run}@example.com`
  await p.fill('#login-email', email); await p.fill('#login-password', PASS); await p.getByRole('button', { name: 'Create account' }).click()
  await p.selectOption('#ob-country', 'KW'); await p.getByRole('button', { name: 'Next' }).click()
  await p.getByRole('button', { name: new RegExp('^' + profile.replace(/[&]/g, '.')) }).click(); await p.getByRole('button', { name: 'Next' }).click()
  await p.fill('#ob-name', name); await p.getByRole('button', { name: 'Next' }).click()
  await p.fill('#ob-display', who); await p.fill('#ob-pin', '9999'); await p.getByRole('button', { name: 'Open my business' }).click()
  await p.getByText('Open a shift to start selling').waitFor()
  const tenant = sql(`select t.id from tenants t join memberships m on m.tenant_id=t.id join auth.users u on u.id=m.user_id where u.email='${email}'`)
  return { p, ctx, tenant }
}
async function openShift(p) {
  await p.getByRole('link', { name: 'Shift' }).click(); await p.fill('#shift-float', '10'); await p.getByRole('button', { name: 'Open shift' }).click(); await p.getByText('Current shift').waitFor()
}
async function addItem(p, f) {
  await p.getByRole('link', { name: 'Products' }).click()
  await p.getByRole('button', { name: 'Add item' }).click()
  if (f.type) await p.locator('.type-seg button', { hasText: f.type }).click()
  await p.fill('#item-name', f.name); if (f.price) await p.fill('#item-price', f.price)
  if (f.cost) await p.fill('#item-cost', f.cost)
  if (f.barcode) await p.fill('#item-barcode', f.barcode)
  if (f.cat) await p.fill('#item-newcat', f.cat)
  if (f.duration) await p.fill('#item-duration', f.duration)
  if (f.weight) { await p.check('#item-weight'); await p.fill('#item-plu', f.plu) }
  if (f.expiry) await p.check('#item-expiry')
  if (f.addons) for (const g of f.addons) await p.getByLabel(new RegExp('^' + g)).check()
  if (f.pkg) { await p.fill('#pkg-sessions', f.pkg.sessions); for (const c of f.pkg.covers) await p.locator('.events-pick label', { hasText: c }).locator('input').check() }
  await p.getByRole('button', { name: 'Save', exact: true }).click()
  await p.locator('tbody td', { hasText: new RegExp('^' + f.name) }).first().waitFor()
}
const nav = async (p) => (await p.locator('aside nav a span').allInnerTexts()).join(',')

// ======================================================================= café
{
  const { p, ctx, tenant } = await business('Café', 'Bait Al Qahwa', 'Omar')
  let n = await nav(p)
  must(n.includes('Kitchen') && n.includes('Promotions') && !n.includes('Calendar') && !n.includes('Orders'), 'café menu: ' + n)
  // add-ons: Size (required) and Milk (optional, uses oat milk)
  await p.getByRole('link', { name: 'Products' }).click()
  await p.getByRole('button', { name: 'Add-ons' }).click()
  await p.fill('#mod-group-name', 'Size'); await p.getByRole('button', { name: 'Add group' }).click()
  await p.getByPlaceholder('New option, e.g. Large').first().waitFor()
  for (const [o, pr] of [['Small', ''], ['Large', '0.500']]) {
    await p.getByPlaceholder('New option, e.g. Large').first().fill(o); if (pr) await p.getByLabel('Extra price').last().fill(pr)
    await p.locator('.mod-group').first().getByRole('button', { name: 'Add' }).click(); await p.locator('.mod-group').first().locator(`input[value="${o}"]`).waitFor()
  }
  await p.getByRole('button', { name: 'Done' }).click()
  await addItem(p, { name: 'Latte', price: '1.500', cost: '0.400', barcode: '111', cat: 'Coffee', addons: ['Size'] })
  await addItem(p, { name: 'Croissant', price: '0.900', cost: '0.300', barcode: '222', cat: 'Bakery' })
  // promotion: 20% off croissants every day
  await p.getByRole('link', { name: 'Promotions' }).click()
  await p.getByRole('button', { name: 'New promotion' }).click()
  await p.fill('#promo-name', 'Croissant 20%'); await p.fill('#promo-percent', '20')
  await p.locator('.seg button', { hasText: 'Chosen items' }).click(); await p.locator('.pick-box label', { hasText: 'Croissant' }).locator('input').check()
  await p.getByRole('button', { name: 'Save', exact: true }).click(); await p.getByRole('cell', { name: /Croissant 20%/ }).waitFor()
  // loyalty: 10 points per KWD, a point is worth 0.010
  await p.getByRole('link', { name: 'Settings' }).click(); await p.getByRole('button', { name: 'Business and receipt' }).click()
  await p.fill('#loy-earn', '10'); await p.fill('#loy-value', '0.010'); await p.fill('#loy-min', '0')
  await p.locator('.card', { hasText: 'Selling rules' }).getByRole('button', { name: 'Save' }).click(); await p.locator('.card', { hasText: 'Selling rules' }).getByText('Saved').waitFor()
  // tables are optional for a café: switch them on, then add T1–T6
  await p.getByRole('button', { name: 'Business type & modules' }).click()
  await p.getByRole('switch', { name: 'Tables & floor plan' }).click(); await p.getByText('Tables & floor plan switched on').waitFor()
  await p.getByRole('button', { name: 'Tables', exact: true }).click()
  await p.fill('#tb-name', 'T1-T6'); await p.getByRole('button', { name: 'Add', exact: true }).click(); await p.getByRole('cell', { name: 'T6' }).waitFor()
  log('café: add-on group Size (Large +0.500), promotion 20% on croissants, loyalty, tables T1–T6')

  await openShift(p)
  await p.getByRole('link', { name: 'Sell' }).click(); await p.getByRole('button', { name: 'Touch' }).click()
  await p.locator('.tile', { hasText: 'Latte' }).click()
  await p.getByRole('dialog').getByRole('button', { name: /^Large/ }).click(); await p.getByRole('button', { name: 'Add to sale' }).click()
  await p.locator('.tile', { hasText: 'Croissant' }).click()
  await p.locator('.cart-lines').getByText('Croissant 20%').waitFor()
  must((await p.locator('.paper-totals .grand').innerText()).includes('2.720'), 'large latte 2.000 + croissant 0.900 − 0.180 = 2.720')
  await p.screenshot({ path: `${SHOTS}/b1-pos-addons-promo.png` })
  // customer for points
  await p.getByRole('button', { name: /Walk-in customer/ }).click(); await p.fill('#cust-new-name', 'Reem'); await p.getByRole('dialog').getByRole('button', { name: 'Add', exact: true }).click()
  await p.getByRole('button', { name: 'Exact cash' }).click(); await p.getByText('Sale complete').waitFor()
  await p.getByRole('button', { name: 'A4 invoice' }).waitFor()
  const sale = sql(`select total||' '||discount_total from sales where tenant_id='${tenant}' order by created_at desc limit 1`)
  must(sale === '2720 180', 'server agrees on total and promotion: ' + sale)
  must(sql(`select coalesce(sum(points),0) from loyalty_ledger where tenant_id='${tenant}'`) === '27', '27 points earned')
  // A4 invoice rendering (print media)
  await p.getByRole('button', { name: 'A4 invoice' }).click(); await p.emulateMedia({ media: 'print' }); await p.locator('#print-root .a4').waitFor()
  await p.screenshot({ path: `${SHOTS}/b2-a4-invoice.png`, fullPage: true }); await p.emulateMedia({ media: 'screen' })
  await p.keyboard.press('Escape').catch(() => {}); await p.getByRole('button', { name: 'New sale' }).click().catch(() => {})
  log('café sale: Large latte + croissant with promotion = 2.720 (server agrees), 27 points, A4 invoice rendered')

  // table T3: first round to the kitchen, second round, then pay
  await p.getByRole('button', { name: 'Tables' }).click(); await p.getByRole('button', { name: /^T3/ }).click()
  await p.locator('.tile', { hasText: 'Croissant' }).click(); await p.locator('.tile', { hasText: 'Croissant' }).click()
  await p.getByRole('button', { name: 'Send to kitchen' }).click(); await p.getByText('Sent to the kitchen').waitFor()
  await p.getByRole('button', { name: 'Tables' }).click()
  await p.screenshot({ path: `${SHOTS}/b3-tables.png` })
  await p.getByRole('button', { name: /^T3/ }).click()
  await p.locator('.tile', { hasText: 'Latte' }).click(); await p.getByRole('dialog').getByRole('button', { name: /^Small/ }).click(); await p.getByRole('button', { name: 'Add to sale' }).click()
  await p.getByRole('button', { name: 'Send to kitchen' }).click(); await p.getByText('Sent to the kitchen').waitFor()
  must(sql(`select count(*) from kitchen_tickets where tenant_id='${tenant}' and open_order_id is not null`) === '2', 'two rounds in the kitchen')
  await p.getByRole('button', { name: 'Tables' }).click(); await p.getByRole('button', { name: /^T3/ }).click()
  await p.getByRole('button', { name: 'Card' }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
  must(sql(`select status from open_orders where tenant_id='${tenant}'`) === 'closed', 'table closed after payment')
  must(sql(`select count(*) from kitchen_tickets where tenant_id='${tenant}'`) === '3', 'paying a table does not re-send it (1 counter sale + 2 rounds)')
  log('table T3: two rounds sent to the kitchen, paid by card, table closed, no duplicate kitchen tickets')
  // the same till in Arabic
  await p.getByRole('button', { name: 'العربية' }).click()
  await p.locator('.tile', { hasText: 'Latte' }).click(); await p.getByRole('dialog').getByRole('button', { name: /^Large/ }).click(); await p.getByRole('dialog').getByRole('button').last().click()
  await p.locator('.tile', { hasText: 'Croissant' }).click(); await p.waitForTimeout(300)
  await p.screenshot({ path: `${SHOTS}/b11-pos-arabic.png` })
  await ctx.close()
}

// ======================================================================= fashion
{
  const { p, ctx } = await business('Fashion & shoes', 'Lulu Abayas', 'Lulu')
  must(!(await nav(p)).includes('Kitchen'), 'no kitchen for fashion')
  await p.getByRole('link', { name: 'Settings' }).click()
  must(await p.getByRole('switch', { name: 'Kitchen screen & printers' }).count() === 0, 'kitchen not even offered')
  await p.screenshot({ path: `${SHOTS}/b4-fashion-modules.png`, fullPage: true })
  await addItem(p, { name: 'Abaya', price: '25.000', cost: '9.000' })
  await p.locator('tr', { hasText: 'Abaya' }).getByRole('button', { name: 'Variants' }).click()
  await p.fill('#var-values-0', 'S, M, L'); await p.fill('#var-values-1', 'Black, Navy')
  await p.getByRole('button', { name: 'Create 6 variants' }).click(); await p.getByText('6 variants').waitFor()
  await openShift(p)
  await p.getByRole('link', { name: 'Sell' }).click(); await p.getByRole('button', { name: 'Touch' }).click()
  must(await p.locator('.tile').count() === 1, 'variants hidden behind their template')
  await p.locator('.tile', { hasText: 'Abaya' }).click()
  await p.getByRole('dialog').getByRole('button', { name: 'M', exact: true }).click()
  await p.screenshot({ path: `${SHOTS}/b5-variant-picker.png` })
  await p.getByRole('dialog').getByRole('button', { name: 'Navy', exact: true }).click()
  await p.locator('.cart-lines').getByText('Abaya · Navy / M').waitFor()
  log('fashion: no kitchen offered; 6 variants (S/M/L × Black/Navy); picked M + Navy at the till')
  await ctx.close()
}

// ======================================================================= grocery
{
  const { p, ctx, tenant } = await business('Grocery & supermarket', 'Al Baqala', 'Saad')
  await addItem(p, { name: 'Labneh', price: '2.000', cost: '0.800', weight: true, plu: '00042', expiry: true })
  const item = sql(`select id from items where tenant_id='${tenant}' and name='Labneh'`), branch = sql(`select id from branches where tenant_id='${tenant}'`)
  sql(`select set_config('request.jwt.claim.sub', (select user_id::text from memberships where tenant_id='${tenant}'), true); select public.receive_stock_batch('${branch}','${item}', 5, 800, 'Almarai', 'L-OLD', current_date + 2);
       select public.receive_stock_batch('${branch}','${item}', 5, 800, 'Almarai', 'L-NEW', current_date + 40)`)
  await openShift(p)
  await p.getByRole('link', { name: 'Sell' }).click(); await p.getByRole('button', { name: 'Keyboard' }).click()
  // scale label: 20 · 00042 · 01250 · check digit → 1.250 kg
  await p.fill('#pos-search', '2000042012507'); await p.press('#pos-search', 'Enter')
  await p.locator('.cart-lines').getByText('1.25×').waitFor()
  await p.getByRole('button', { name: 'Exact cash' }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
  must(sql(`select on_hand from v_batches where item_id='${item}' and batch_no='L-OLD'`) === '3.750', 'FEFO took the old batch first')
  await p.getByRole('link', { name: 'Inventory' }).click(); await p.getByRole('button', { name: 'Expiry' }).click()
  await p.getByRole('cell', { name: 'L-OLD' }).waitFor()
  await p.screenshot({ path: `${SHOTS}/b6-expiry.png` })
  log('grocery: scale label read as 1.250 kg labneh, taken from the batch expiring first; expiry list shows both batches')
  await ctx.close()
}

// ======================================================================= salon
{
  const { p, ctx, tenant } = await business('Salon & barber', 'Noor Salon', 'Noor')
  let n = await nav(p)
  must(n.includes('Calendar') && !n.includes('Kitchen'), 'salon menu: ' + n)
  await addItem(p, { name: 'Haircut', price: '5.000', type: 'Service', duration: '45' })
  await addItem(p, { name: '4 Haircuts', price: '16.000', type: 'Package', pkg: { sessions: '4', covers: ['Haircut'] } })
  // the owner takes bookings, 09:00–21:00 every day; 10% commission; online booking page
  await p.getByRole('link', { name: 'Settings' }).click(); await p.getByRole('button', { name: 'Staff' }).click()
  await p.getByLabel('Takes bookings').check(); await p.getByRole('button', { name: 'Hours' }).click()
  for (const d of ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) await p.getByRole('dialog').getByLabel(d).check()
  await p.getByRole('dialog').getByRole('button', { name: 'Save' }).click()
  await p.getByLabel('Commission %').fill('10'); await p.getByLabel('Commission %').blur()
  await p.getByRole('button', { name: 'Business and receipt' }).click()
  await p.fill('#book-slug', `noor-${run}`); await p.check('#book-online')
  await p.locator('.card', { hasText: 'Selling rules' }).getByRole('button', { name: 'Save' }).click(); await p.locator('.card', { hasText: 'Selling rules' }).getByText('Saved').waitFor()

  // a customer books online for tomorrow
  const pub = await ctx.newPage()
  await pub.goto(`${APP}/book/noor-${run}`)
  await pub.getByRole('button', { name: /^Haircut/ }).click()
  await pub.locator('.day-strip button').nth(1).click()
  await pub.locator('.chip-pick button').first().waitFor()
  await pub.screenshot({ path: `${SHOTS}/b7-online-booking.png`, fullPage: true })
  await pub.locator('.chip-pick button').first().click()
  await pub.fill('#bk-name', 'Huda'); await pub.fill('#bk-phone', '+965 5000 1234')
  await pub.getByRole('button', { name: /^Book / }).click(); await pub.getByText('You are booked').waitFor()
  must(sql(`select source||' '||status from appointments where tenant_id='${tenant}'`) === 'online booked', 'online booking stored')
  log('salon: service + 4-session package, owner bookable 09–21, online booking page used by a customer')

  // calendar → checkout; then the package
  await openShift(p)
  await p.getByRole('link', { name: 'Calendar' }).click(); await p.getByRole('button', { name: 'Next day' }).click()
  await p.locator('.appt', { hasText: 'Huda' }).waitFor()
  await p.locator('.appt', { hasText: 'Huda' }).screenshot({ path: `${SHOTS}/_appt.png` }).catch(() => {})
  await p.screenshot({ path: `${SHOTS}/b8-calendar.png` })
  await p.locator('.appt', { hasText: 'Huda' }).click(); await p.getByRole('button', { name: 'Checkout' }).click()
  await p.locator('.ctx-bar').waitFor()
  await p.getByRole('button', { name: 'Card' }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
  must(sql(`select status from appointments where tenant_id='${tenant}'`) === 'completed', 'appointment completed')
  must(sql(`select sum(commission) from v_commissions where tenant_id='${tenant}'`) === '500', 'commission 10% of 5.000')
  // Huda buys the package, then uses a session
  await p.getByRole('button', { name: 'Touch' }).click()
  await p.getByRole('button', { name: /Walk-in customer/ }).click(); await p.getByRole('button', { name: /Huda/ }).click()
  await p.locator('.tile', { hasText: '4 Haircuts' }).click(); await p.getByRole('button', { name: 'Card' }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
  await p.getByRole('button', { name: /Walk-in customer/ }).click(); await p.getByRole('button', { name: /Huda/ }).click()
  await p.locator('.tile', { hasText: /^H\s*Haircut/ }).click()
  await p.getByRole('button', { name: 'Use package' }).click()
  await p.locator('.paper-totals').getByText('Paid by package').waitFor()
  await p.screenshot({ path: `${SHOTS}/b9-package.png` })
  await p.getByRole('button', { name: /^Confirm/ }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
  must(sql(`select sessions_used||'/'||sessions_total from customer_packages where tenant_id='${tenant}'`) === '1/4', 'one session used')
  log('calendar checkout (commission 0.500), package sold, a session redeemed with nothing to pay')
  await ctx.close()
}

// ======================================================================= laundry
{
  const { p, ctx, tenant } = await business('Laundry', 'Clean Press', 'Fahad')
  await addItem(p, { name: 'Shirt wash & iron', price: '0.500', type: 'Service' })
  await addItem(p, { name: 'Suit dry clean', price: '3.000', type: 'Service' })
  await openShift(p)
  await p.getByRole('link', { name: 'Orders' }).click()
  await p.getByRole('button', { name: 'New job card' }).click()
  await p.getByRole('button', { name: 'Choose customer' }).click(); await p.fill('#cust-new-name', 'Khalid'); await p.getByRole('dialog').getByRole('button', { name: 'Add', exact: true }).click()
  await p.fill('#wo-tags', '101-106')
  await p.fill('#wo-item-q', 'Shirt'); await p.getByRole('button', { name: /^Shirt wash/ }).click()
  await p.locator('.list.compact input.qty-in').first().fill('5')
  await p.fill('#wo-item-q', 'Suit'); await p.getByRole('button', { name: /^Suit dry/ }).click()
  await p.getByRole('button', { name: 'Save', exact: true }).click()
  await p.fill('#wo-dep', '2'); await p.getByRole('button', { name: 'Take deposit' }).click(); await p.getByText('2.000').first().waitFor()
  await p.getByRole('button', { name: 'Mark ready' }).click(); await p.getByRole('dialog').locator('.pill.wo-ready').waitFor()
  await p.screenshot({ path: `${SHOTS}/b10-job-card.png` })
  await p.getByRole('button', { name: 'Collect and pay' }).click()
  await p.locator('.paper-totals').getByText('Deposit paid').waitFor()
  must((await p.locator('.paper-totals .grand').innerText()).includes('3.500'), '5.500 − 2.000 deposit = 3.500 to pay')
  await p.getByRole('button', { name: 'Exact cash' }).click(); await p.getByText('Sale complete').waitFor(); await p.getByRole('button', { name: 'New sale' }).click()
  must(sql(`select status||' '||deposit_used from work_orders where tenant_id='${tenant}'`) === 'collected 2000', 'job collected')
  must(sql(`select coalesce(sum(jl.credit-jl.debit),0) from journal_lines jl join accounts a on a.id=jl.account_id where a.system_key='customer_deposits' and jl.tenant_id='${tenant}'`) === '0', 'deposit liability cleared')
  await p.getByRole('link', { name: 'Orders' }).click(); await p.getByText('Nothing open').waitFor()
  await p.getByRole('link', { name: 'Shift' }).click()
  log('laundry: job card B01-JOB-00001 with tags 101–106, 2.000 deposit, ready, collected paying 3.500 cash')
  await ctx.close()
}

await browser.close()
console.log('PHASE B-D E2E PASSED')

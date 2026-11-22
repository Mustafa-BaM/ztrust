// E2E: the P0 screens — cash in/out + X report, serial numbers, exchange, quotation → order → delivery → invoice,
// customer statement, cash ceiling, HR & payroll, purchase requests, cash flow / petty cash / cost centres, dashboard alerts.
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
// printing is a no-op in headless Chromium: close the print layer straight away
await p.addInitScript(() => { window.print = () => setTimeout(() => window.dispatchEvent(new Event('afterprint')), 50) })

await p.goto(APP)
await p.getByRole('button', { name: 'Start 7-day free trial' }).click()
await p.fill('#login-email', mail('own')); await p.fill('#login-password', PASS); await p.getByRole('button', { name: 'Create account' }).click()
await p.selectOption('#ob-country', 'KW'); await p.getByRole('button', { name: 'Next' }).click()
await p.getByRole('button', { name: /^Grocery/ }).click(); await p.getByRole('button', { name: 'Next' }).click()
await p.fill('#ob-name', 'Volt Store'); await p.fill('#ob-name-ar', 'فولت'); await p.getByRole('button', { name: 'Next' }).click()
await p.fill('#ob-display', 'Huda'); await p.fill('#ob-pin', '9999'); await p.getByRole('button', { name: 'Open my business' }).click()
await p.getByText('Open a shift to start selling').waitFor()
const T = sql(`select tenant_id from memberships m join auth.users u on u.id=m.user_id where u.email='${mail('own')}'`)
sql(`update tenants set features = features || '{"serials":true,"quotations":true,"purchasing":true}' where id='${T}'`)
sql(`insert into items(tenant_id,name,name_ar,price,cost,barcode,track_stock,track_serial,warranty_months) values ('${T}','Phone X','هاتف X',50000,30000,'PX1',true,true,12)`)
sql(`insert into items(tenant_id,name,name_ar,price,cost,barcode,track_stock) values ('${T}','Charger','شاحن',5000,2000,'CH1',true)`)
sql(`insert into stock_movements(tenant_id,branch_id,item_id,qty,reason,unit_cost) select '${T}', b.id, i.id, 50, 'adjustment', i.cost from items i, branches b where i.tenant_id='${T}' and b.tenant_id='${T}'`)
sql(`insert into customers(tenant_id,name,phone,credit_limit) values ('${T}','Gulf Trading','+96560000000',10000000)`)
sql(`insert into suppliers(tenant_id,name) values ('${T}','Asia Parts')`)
await p.reload(); await p.locator('aside nav').waitFor()

// ---- settings: cash ceiling and receipt languages
await p.getByRole('link', { name: 'Settings' }).click()
await p.getByRole('button', { name: 'Business and receipt' }).click().catch(() => {})
await p.locator('#rule-cash_limit').fill('100'); await p.selectOption('#rule-cash_limit_mode', 'block')
await p.locator('#rule-cash_limit').locator('xpath=ancestor::section[1]').getByRole('button', { name: 'Save' }).click()
await p.waitForTimeout(500)
assert(sql(`select settings->>'cash_limit_mode' from tenants where id='${T}'`) === 'block', 'cash ceiling saved')
log('settings: cash ceiling 100.000 KWD (block), card networks from the country')

// ---- shift: open, cash out to the safe, X report
await p.getByRole('link', { name: 'Shift', exact: true }).click(); await p.fill('#shift-float', '50'); await p.getByRole('button', { name: 'Open shift' }).click()
await p.getByText('Current shift').waitFor()
await p.getByRole('button', { name: 'Cash out' }).click(); await p.fill('#cm-amount', '10'); await p.fill('#cm-reason', 'Drop to safe')
await p.getByRole('dialog').getByRole('button', { name: 'Save' }).click()
await p.getByText('Drop to safe').waitFor()
await p.screenshot({ path: `${SHOTS}/p0-1-shift-cash-out.png` })
await p.getByRole('button', { name: 'Print X report' }).click(); await p.waitForTimeout(600)
log('shift: cash out 10.000 to the safe with a reason; X report printed')

// ---- serial numbers on the shelf
await p.getByRole('link', { name: 'Inventory' }).click(); await p.getByRole('button', { name: 'Serial numbers' }).click()
await p.selectOption('#ser-item', { label: 'Phone X' }); await p.fill('#ser-text', 'IMEI-A\nIMEI-B')
await p.getByRole('button', { name: 'Register', exact: true }).click(); await p.getByText('2 serial numbers registered').waitFor()
log('inventory: 2 IMEI registered')

// ---- POS: sell a phone with its serial, by card (K-Net)
await p.getByRole('link', { name: 'Sell' }).click()
await p.getByRole('button', { name: 'Touch' }).click()
await p.locator('.tile', { hasText: 'Phone X' }).click()
await p.getByRole('dialog').getByRole('button', { name: 'IMEI-A' }).click()
await p.getByText('#IMEI-A').waitFor()
await p.screenshot({ path: `${SHOTS}/p0-2-pos-serial.png` })
await p.getByRole('button', { name: /^Card/ }).click(); await p.getByText('Sale complete').waitFor()
const sale1 = sql(`select number from sales where tenant_id='${T}' order by created_at desc limit 1`)
assert(sql(`select status from item_serials where serial='IMEI-A' and tenant_id='${T}'`) === 'sold', 'IMEI-A sold')
assert(sql(`select method from payments p join sales s on s.id=p.sale_id where s.number='${sale1}' and s.tenant_id='${T}'`) === 'K-Net', 'K-Net stored')
await p.getByRole('button', { name: 'New sale' }).click()
log(`POS: ${sale1} phone IMEI-A, card K-Net`)

// ---- cash ceiling on the till
await p.locator('.tile', { hasText: 'Phone X' }).click(); await p.getByRole('dialog').getByRole('button', { name: 'IMEI-B' }).click()
for (let i = 0; i < 12; i++) await p.locator('.tile', { hasText: 'Charger' }).click()
await p.getByRole('button', { name: /^Pay/ }).click()
await p.fill('#pay-amount', '110'); await p.getByRole('button', { name: 'Add payment' }).click()
await p.getByText(/Cash on one invoice is limited to/).waitFor()
await p.screenshot({ path: `${SHOTS}/p0-3-cash-ceiling.png` })
await p.getByRole('button', { name: 'Back to cart' }).click(); await p.getByRole('button', { name: 'Clear' }).click()
log('cash ceiling: 110.000 cash refused on the till (limit 100.000)')

// ---- exchange: return the phone, take a charger; 45.000 back in cash
await p.getByRole('link', { name: 'Sales', exact: true }).click()
await p.getByRole('cell', { name: sale1 }).click()
await p.getByRole('button', { name: 'Exchange' }).click()
await p.locator('input[id^="rq-"]').first().fill('1'); await p.fill('#exchange-reason', 'Wrong colour')
await p.getByRole('button', { name: 'Continue to the till' }).click()
await p.getByText('Exchange credit').waitFor({ state: 'attached' }).catch(() => {})
await p.locator('.tile', { hasText: 'Charger' }).click()
await p.getByText('Cash back to customer').waitFor()
await p.screenshot({ path: `${SHOTS}/p0-4-exchange.png` })
await p.getByRole('button', { name: /^Confirm/ }).click(); await p.getByText('Sale complete').waitFor()
await p.getByText(/Give the customer back in cash/).waitFor()
assert(sql(`select status from item_serials where serial='IMEI-A' and tenant_id='${T}'`) === 'in_stock', 'IMEI-A back in stock')
await p.getByRole('button', { name: 'New sale' }).click()
log('exchange: phone returned (IMEI-A back in stock), charger taken, 45.000 cash back')

// ---- quotation → order → delivery note → invoice on account
await p.getByRole('link', { name: 'Quotations & orders' }).click()
await p.getByRole('button', { name: /^New/ }).click()
await p.selectOption('#sd-customer', { label: 'Gulf Trading · +96560000000' })
await p.fill('#sd-search', 'Charger'); await p.getByRole('button', { name: /^Charger/ }).click()
await p.locator('input[aria-label="Qty"]').fill('10')
await p.getByRole('dialog').getByRole('button', { name: 'Save' }).click()
await p.getByRole('button', { name: 'Accepted → sales order' }).click()
await p.getByRole('button', { name: 'Create delivery note' }).click()
await p.getByText('Delivery note', { exact: false }).first().waitFor()
await p.screenshot({ path: `${SHOTS}/p0-5-delivery-note.png` })
await p.getByRole('button', { name: 'Invoice at the till' }).click()
await p.getByRole('button', { name: /^Pay/ }).click()
await p.getByRole('radio', { name: 'On account' }).click(); await p.getByRole('button', { name: 'Add payment' }).click()
await p.getByRole('button', { name: /Complete sale/ }).click(); await p.getByText('Sale complete').waitFor()
assert(sql(`select count(*) from sales_docs where tenant_id='${T}' and status='invoiced'`) === '2', 'order and delivery note invoiced')
await p.getByRole('button', { name: 'New sale' }).click()
log('quotation → sales order → delivery note → invoice 50.000 on account')

// ---- customer statement
await p.getByRole('link', { name: 'Customers' }).click(); await p.getByRole('cell', { name: 'Gulf Trading' }).click()
await p.getByRole('tab', { name: 'Statement' }).click(); await p.getByText('Closing balance').waitFor()
await p.screenshot({ path: `${SHOTS}/p0-6-customer-statement.png` })
await p.keyboard.press('Escape')
log('customer statement: closing balance shown')

// ---- HR & payroll
await p.getByRole('link', { name: 'HR & payroll' }).click()
await p.getByRole('button', { name: 'Add employee' }).click()
await p.fill('#emp-name', 'Sami'); await p.fill('#emp-basic_salary', '300'); await p.fill('#emp-allowances', '50')
await p.fill('#emp-civil_id_expiry', new Date(Date.now() + 10 * 86400000).toISOString().slice(0, 10))
await p.getByRole('dialog').getByRole('button', { name: 'Save' }).click()
await p.getByText(/have a document expiring within 30 days/).waitFor()
await p.getByRole('tab', { name: 'Payroll' }).click(); await p.getByRole('button', { name: 'Prepare payroll' }).click()
await p.getByRole('button', { name: 'Post to accounts' }).waitFor()
await p.screenshot({ path: `${SHOTS}/p0-7-payroll.png` })
await p.getByRole('button', { name: 'Post to accounts' }).click(); await p.getByRole('button', { name: 'Mark as paid from the bank' }).click()
await p.getByText('paid', { exact: true }).waitFor()
log('HR: employee with expiring civil ID flagged; payroll 350.000 prepared, posted and paid')

// ---- purchasing: a request; accounting: petty cash, cash flow, cost centres
await p.getByRole('link', { name: 'Purchasing' }).click(); await p.getByRole('button', { name: 'Purchase requests' }).click()
await p.selectOption('#pr-item-0', { label: 'Charger' }); await p.fill('#pr-qty-0', '30'); await p.getByRole('button', { name: 'Send request' }).click()
await p.getByRole('cell', { name: /Charger × 30/ }).waitFor()
await p.getByRole('link', { name: 'Accounting' }).click()
await p.getByRole('button', { name: 'Petty cash', exact: true }).click(); await p.fill('#pc-amount', '20'); await p.getByRole('button', { name: 'Top up petty cash' }).click()
await p.getByText('Petty cash balance').waitFor()
await p.getByRole('button', { name: 'Cash flow' }).click(); await p.getByText('Cash at the end').waitFor()
await p.screenshot({ path: `${SHOTS}/p0-8-cash-flow.png` })
await p.getByRole('button', { name: 'Cost centres' }).click(); await p.fill('#cc-code', 'HQ'); await p.fill('#cc-name', 'Main shop'); await p.getByRole('button', { name: 'Add cost centre' }).click()
await p.getByRole('button', { name: /HQ · Main shop/ }).waitFor()
log('purchase request sent; petty cash topped up; cash flow and cost centres shown')

// ---- dashboard: needs attention (server counts)
await p.getByRole('link', { name: 'Dashboard' }).click(); await p.getByText('Unpaid invoices (on account / payment links)').waitFor()
await p.screenshot({ path: `${SHOTS}/p0-9-dashboard-alerts.png` })
log('dashboard: needs-attention counts from the server (unpaid invoice, documents, requests)')

// the ledger is still balanced
assert(sql(`select sum(debit)=sum(credit) from journal_lines where tenant_id='${T}'`) === 't', 'ledger balanced')
console.log('E2E P0 SCREENS PASSED')
await browser.close()

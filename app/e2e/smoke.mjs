// End-to-end smoke test against a running app + local Supabase.
// Usage: APP_URL=http://localhost:5173 SHOTS=./shots node e2e/smoke.mjs
import { createRequire } from 'node:module'
const { chromium } = createRequire(import.meta.url)('playwright')
import fs from 'node:fs'

const APP = process.env.APP_URL || 'http://localhost:5173'
const SHOTS = process.env.SHOTS || './shots'
fs.mkdirSync(SHOTS, { recursive: true })
const email = `owner${Date.now()}@example.com`
const log = (...a) => console.log('✓', ...a)

const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: { width: 1366, height: 860 } })
const page = await ctx.newPage()
page.on('pageerror', (e) => console.log('PAGE ERROR', e.message))

await page.goto(APP)
await page.getByRole('button', { name: 'Start 7-day free trial' }).click()
await page.fill('#login-email', email)
await page.fill('#login-password', 'Secret#2026')
await page.getByRole('button', { name: 'Create account' }).click()
await page.getByText('Set up your business').waitFor()
log('signed up')

await page.selectOption('#ob-country', 'KW')
await page.getByRole('button', { name: 'Next' }).click()
await page.getByRole('button', { name: /Café or restaurant/ }).click()
await page.getByRole('button', { name: 'Next' }).click()
await page.fill('#ob-name', 'Faisal Coffee')
await page.fill('#ob-name-ar', 'قهوة فيصل')
await page.fill('#ob-branch', 'Salmiya')
await page.getByRole('button', { name: 'Next' }).click()
await page.fill('#ob-display', 'Faisal')
await page.fill('#ob-pin', '9999')
await page.getByRole('button', { name: 'Open my business' }).click()
await page.getByText('Open a shift to start selling').waitFor()
log('business created (Kuwait, KWD 3 decimals)')

// products
await page.getByRole('link', { name: 'Products' }).click()
for (const [n, ar, price, cost, bc] of [['Latte', 'لاتيه', '1.500', '0.400', '111'], ['Croissant', 'كرواسون', '0.900', '0.300', '222'], ['Spanish Latte', 'سبانش لاتيه', '1.750', '0.450', '333']]) {
  await page.getByRole('button', { name: 'Add item' }).click()
  await page.fill('#item-name', n); await page.fill('#item-name-ar', ar); await page.fill('#item-price', price)
  await page.fill('#item-cost', cost); await page.fill('#item-barcode', bc); await page.fill('#item-newcat', n === 'Croissant' ? 'Bakery' : '')
  if (n === 'Latte') await page.fill('#item-newcat', 'Coffee')
  await page.getByRole('button', { name: 'Save' }).click()
  await page.locator('tbody td', { hasText: new RegExp('^' + n) }).first().waitFor()
}
log('3 products added')

// shift
await page.getByRole('link', { name: 'Shift' }).click()
await page.fill('#shift-float', '10')
await page.getByRole('button', { name: 'Open shift' }).click()
await page.getByText('Current shift').waitFor()
log('shift opened with 10.000 float')

// sale 1: keyboard mode, scan 2×111 + 222, cash 5 → change
await page.getByRole('link', { name: 'Sell' }).click()
await page.getByRole('button', { name: 'Keyboard' }).click()
await page.fill('#pos-search', '2*111'); await page.press('#pos-search', 'Enter')
await page.fill('#pos-search', '222'); await page.press('#pos-search', 'Enter')
await page.getByText('3.900').first().waitFor()
await page.screenshot({ path: `${SHOTS}/1-pos-keyboard.png` })
await page.keyboard.press('F8')
await page.fill('#pay-amount', '5')
await page.getByRole('button', { name: 'Add payment' }).click()
await page.getByRole('button', { name: /Complete sale/ }).click()
await page.getByText('Sale complete').waitFor()
const change1 = await page.locator('.change b').innerText()
if (!change1.includes('1.100')) throw new Error(`expected change 1.100, got ${change1}`)
await page.screenshot({ path: `${SHOTS}/2-sale-complete.png` })
await page.getByRole('button', { name: 'New sale' }).click()
log('sale 1: 3.900 paid cash 5.000, change', change1)

// sale 2: touch mode, split cash + card with 10% line discount
await page.getByRole('button', { name: 'Touch' }).click()
await page.locator('.tile', { hasText: 'Spanish Latte' }).click()
await page.locator('.tile', { hasText: 'Spanish Latte' }).click()
await page.getByRole('button', { name: /^Discount/ }).click()
await page.fill('#discount-value', '10')
await page.getByRole('button', { name: 'Apply' }).click()
await page.screenshot({ path: `${SHOTS}/3-pos-touch.png` })
await page.getByRole('button', { name: /^Pay/ }).click()
await page.fill('#pay-amount', '1')
await page.getByRole('button', { name: 'Add payment' }).click()
await page.getByRole('radio', { name: 'Card' }).click()
await page.fill('#pay-ref', 'AUTH123')
await page.getByRole('button', { name: 'Add payment' }).click()
await page.screenshot({ path: `${SHOTS}/4-split-payment.png` })
await page.getByRole('button', { name: /Complete sale/ }).click()
await page.getByText('Sale complete').waitFor()
await page.getByRole('button', { name: 'New sale' }).click()
log('sale 2: 3.150 after 10% discount, split cash 1.000 + card 2.150')

// sale 3: offline
await ctx.setOffline(true)
await page.locator('.tile', { hasText: 'Croissant' }).click()
await page.getByRole('button', { name: /^Pay/ }).click()
await page.getByRole('button', { name: 'Add payment' }).click()
await page.getByRole('button', { name: /Complete sale/ }).click()
await page.getByText('Saved offline').waitFor()
await page.screenshot({ path: `${SHOTS}/5-offline-sale.png` })
await page.getByRole('button', { name: 'New sale' }).click()
await page.getByText('1 waiting to sync').waitFor()
log('sale 3 stored offline')
await ctx.setOffline(false)
await page.evaluate(() => window.dispatchEvent(new Event('online')))
await page.getByText('waiting to sync').waitFor({ state: 'detached', timeout: 20000 })
log('offline sale synced')

// refund the first line of sale 1 (Croissant 0.900; lines are listed by name). Owner needs no PIN.
await page.getByRole('link', { name: 'Sales' }).click()
await page.getByRole('cell', { name: 'B01-INV-000001' }).click()
await page.getByRole('button', { name: 'Refund items' }).click()
await page.locator('input[id^="rq-"]').first().fill('1')
await page.fill('#refund-reason', 'Customer changed mind')
await page.getByRole('button', { name: 'Issue refund' }).click()
await page.getByText('partially_refunded').first().waitFor()
await page.screenshot({ path: `${SHOTS}/6-refund.png` })
await page.keyboard.press('Escape')
await page.getByRole('cell', { name: 'B01-CN-000001' }).waitFor()
await page.getByRole('cell', { name: 'B01-INV-000003' }).waitFor()
log('refund issued as credit note B01-CN-000001; offline sale became B01-INV-000003')

// dashboard + reports
await page.getByRole('link', { name: 'Dashboard' }).click()
await page.locator('.kpi2-label', { hasText: 'Net sales' }).waitFor()
await page.waitForTimeout(800)
await page.screenshot({ path: `${SHOTS}/7-dashboard.png` })
const net = await page.locator('.kpi2', { hasText: 'Net sales' }).locator('.kpi2-value').innerText()
if (!net.includes('7.050')) throw new Error(`expected net 7.050, got ${net}`)
log('dashboard net sales', net)
await page.getByRole('link', { name: 'Reports' }).click()
await page.getByRole('button', { name: 'Trial balance' }).click()
await page.getByRole('cell', { name: 'Sales', exact: true }).waitFor()
await page.screenshot({ path: `${SHOTS}/8-trial-balance.png` })

// Arabic RTL
await page.getByRole('button', { name: 'العربية' }).click()
await page.getByRole('link', { name: 'البيع' }).click()
await page.waitForTimeout(500)
const dir = await page.evaluate(() => document.documentElement.dir)
if (dir !== 'rtl') throw new Error('expected rtl')
await page.screenshot({ path: `${SHOTS}/9-pos-arabic.png` })
log('Arabic RTL POS')

// close shift: expected 10 + 3.900 + 1.000 + 0.900 − 0.900 = 14.900; we count 14.300 → short 0.600
await page.getByRole('link', { name: 'الوردية' }).click()
await page.fill('#shift-counted', '14.3')
await page.getByRole('button', { name: 'إغلاق الوردية وطباعة تقرير Z' }).click()
await page.getByText('تقرير Z').waitFor()
const variance = await page.locator('.zreport dd').last().innerText()
await page.screenshot({ path: `${SHOTS}/10-z-report.png` })
if (!variance.includes('0.600')) throw new Error(`expected short 0.600, got ${variance}`)
log('shift closed, over/short =', variance)

await browser.close()
console.log('E2E SMOKE PASSED')

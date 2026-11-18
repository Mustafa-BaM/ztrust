// E2E: audit-ready accounting with an accountant login (maker) and the owner (checker).
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
const run = Date.now(), PASS = 'Secret#2026'
const mail = (n) => `${n}${run}@example.com`
const log = (...a) => console.log('✓', ...a)
const sql = (q) => execFileSync('psql', [DB, '-Atc', q]).toString().trim()

const browser = await chromium.launch()
const newPage = async () => { const c = await browser.newContext({ viewport: { width: 1366, height: 900 }, acceptDownloads: true }); const p = await c.newPage(); p.on('pageerror', (e) => console.log('PAGE ERROR', e.message)); return p }

// owner: Saudi retailer, VAT 15% inclusive
const owner = await newPage()
await owner.goto(APP)
await owner.getByRole('button', { name: 'Start 7-day free trial' }).click()
await owner.fill('#login-email', mail('own')); await owner.fill('#login-password', PASS); await owner.getByRole('button', { name: 'Create account' }).click()
await owner.selectOption('#ob-country', 'SA'); await owner.getByRole('button', { name: 'Next' }).click()
await owner.getByRole('button', { name: /^Grocery/ }).click(); await owner.getByRole('button', { name: 'Next' }).click()
await owner.fill('#ob-name', 'Riyadh Style'); await owner.fill('#ob-name-ar', 'رياض ستايل'); await owner.fill('#ob-tax', '310123456700003'); await owner.getByRole('button', { name: 'Next' }).click()
await owner.fill('#ob-display', 'Huda'); await owner.fill('#ob-pin', '9999'); await owner.getByRole('button', { name: 'Open my business' }).click()
await owner.getByText('Open a shift to start selling').waitFor()
const tenant = sql(`select tenant_id from memberships m join auth.users u on u.id=m.user_id where u.email='${mail('own')}'`)
sql(`insert into items(tenant_id,name,name_ar,price,cost,barcode) values ('${tenant}','Abaya','عباية',46000,20000,'900')`)
await owner.getByRole('link', { name: 'Shift', exact: true }).click(); await owner.fill('#shift-float', '500'); await owner.getByRole('button', { name: 'Open shift' }).click()
await owner.getByText('Current shift').waitFor()
await owner.getByRole('link', { name: 'Sell' }).click()
await owner.getByRole('button', { name: 'Keyboard' }).click()
await owner.fill('#pos-search', '2*900'); await owner.press('#pos-search', 'Enter')
await owner.getByRole('button', { name: /Exact cash/ }).click(); await owner.getByText('Sale complete').waitFor()
await owner.getByRole('button', { name: 'New sale' }).click()
log('owner sold 2 abayas: 920.00 SAR incl. 120.00 VAT (one-tap exact cash)')

// accountant account
const r = await fetch(`${SB}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: mail('aisha'), password: PASS, email_confirm: true }) })
const uid = (await r.json()).id
sql(`insert into memberships(tenant_id,user_id,role,display_name,pin_hash) values ('${tenant}','${uid}','accountant','Aisha', extensions.crypt('6666', extensions.gen_salt('bf')))`)

const acc = await newPage()
await acc.goto(APP); await acc.fill('#login-email', mail('aisha')); await acc.fill('#login-password', PASS); await acc.getByRole('button', { name: 'Sign in' }).last().click()
await acc.getByText('Ledger verified').waitFor()
log(`accountant lands on Accounting; nav: ${(await acc.locator('.side nav a').allInnerTexts()).join(', ')}`)

// expense with input VAT
await acc.getByRole('button', { name: 'Expenses' }).click()
await acc.getByRole('button', { name: 'Record expense' }).click()
await acc.fill('#ex-desc', 'Shop rent November'); await acc.fill('#ex-total', '1150'); await acc.fill('#ex-ref', 'LEASE-11')
await acc.getByRole('dialog').getByRole('button', { name: 'Save' }).click()
await acc.getByRole('cell', { name: /Shop rent November/ }).waitFor()
log('expense: rent 1,150.00 incl. 150.00 input VAT, paid from bank')

// manual journal: opening capital, maker-checker
await acc.getByRole('button', { name: 'Journal', exact: true }).click()
await acc.getByRole('button', { name: 'New journal entry' }).click()
await acc.fill('#jf-memo', 'Opening capital deposited'); await acc.fill('#jf-ref', 'BANK-STMT-001')
const bankId = sql(`select id from accounts where tenant_id='${tenant}' and system_key='bank'`), capId = sql(`select id from accounts where tenant_id='${tenant}' and system_key='equity'`)
await acc.selectOption('#jf-acc-0', bankId); await acc.fill('#jf-dr-0', '50000')
await acc.selectOption('#jf-acc-1', capId); await acc.fill('#jf-cr-1', '50000')
await acc.getByText('Balanced', { exact: true }).waitFor()
await acc.screenshot({ path: `${SHOTS}/a1-journal-form.png` })
await acc.getByRole('button', { name: 'Save draft' }).click()
await acc.getByText('Waiting for approval').waitFor()
await acc.getByRole('button', { name: 'Approve and post' }).click()
await acc.getByText('Manager approval').waitFor()
await acc.fill('#approver-pin', '6666'); await acc.getByRole('dialog', { name: 'Manager approval' }).getByRole('button', { name: 'Approve', exact: true }).click()
await acc.getByText('That PIN cannot approve this').waitFor()
log('accountant cannot post own journal (own PIN refused)')
await acc.fill('#approver-pin', '9999'); await acc.getByRole('dialog', { name: 'Manager approval' }).getByRole('button', { name: 'Approve', exact: true }).click()
await acc.getByText('Waiting for approval').waitFor({ state: 'detached' })
await acc.getByRole('cell', { name: /Opening capital deposited/ }).click()
await acc.waitForTimeout(300)
await acc.screenshot({ path: `${SHOTS}/a2-journal.png` })
log('journal posted with the owner PIN; entry shows approver and hash')

// statements
await acc.getByRole('button', { name: 'Statements' }).click()
await acc.getByText('Net profit').waitFor()
await acc.screenshot({ path: `${SHOTS}/a3-income-statement.png` })
await acc.locator('.filters .seg').getByRole('button', { name: 'Balance sheet' }).click()
await acc.getByText('✓ Balanced').waitFor()
await acc.screenshot({ path: `${SHOTS}/a4-balance-sheet.png` })
await acc.locator('.filters .seg').getByRole('button', { name: 'VAT return' }).click()
await acc.getByText('VAT refundable').or(acc.getByText('VAT payable')).first().waitFor()
const vatText = await acc.locator('.st-total.strong').innerText()
log('P&L, balanced balance sheet, VAT return:', vatText.replace(/\s+/g, ' '))

// periods: the running month cannot be closed; a closed month refuses journals; owner reopens with reason
await acc.getByRole('button', { name: 'Periods' }).click()
const cur = acc.locator('.period').first()
await cur.getByText('In progress').waitFor()
if (await cur.getByRole('button', { name: 'Close period' }).count()) throw new Error('running month must not be closable')
await acc.locator('.period').nth(1).getByRole('button', { name: 'Close period' }).click()
await acc.locator('.period').nth(1).getByText('Closed').waitFor()
await acc.screenshot({ path: `${SHOTS}/a6-periods.png` })
const lm = new Date(); lm.setDate(1); lm.setMonth(lm.getMonth() - 1); lm.setDate(15)
await acc.getByRole('button', { name: 'Journal', exact: true }).click()
await acc.getByRole('button', { name: 'New journal entry' }).click()
await acc.fill('#jf-date', lm.toISOString().slice(0, 10)); await acc.fill('#jf-memo', 'Late accrual')
const genId = sql(`select id from accounts where tenant_id='${tenant}' and system_key='exp_general'`), accrId = sql(`select id from accounts where tenant_id='${tenant}' and system_key='accruals'`)
await acc.selectOption('#jf-acc-0', genId); await acc.fill('#jf-dr-0', '100'); await acc.selectOption('#jf-acc-1', accrId); await acc.fill('#jf-cr-1', '100')
await acc.getByRole('button', { name: 'Save draft' }).click()
await acc.getByText('This accounting period is closed').waitFor()
await acc.getByRole('button', { name: 'Cancel' }).click()
log('running month cannot be closed; last month closed; a journal dated in it is refused with a clear message')
await owner.getByRole('link', { name: 'Accounting' }).click()
await owner.getByRole('button', { name: 'Periods' }).click()
await owner.getByRole('button', { name: 'Reopen' }).first().click()
await owner.fill('#rd-reason', 'Late supplier invoice'); await owner.getByRole('button', { name: 'Confirm' }).click()
await owner.locator('.period.closed').first().waitFor({ state: 'detached' })
log('owner reopened last month with a reason (audited)')

// overview + audit pack
await acc.getByRole('button', { name: 'Overview' }).click()
await acc.getByRole('button', { name: 'Verify again' }).click()
await acc.getByText('Ledger verified').waitFor()
await acc.screenshot({ path: `${SHOTS}/a5-overview.png` })
const [dl] = await Promise.all([acc.waitForEvent('download'), acc.getByRole('button', { name: 'Download audit pack' }).click()])
const zipPath = `${SHOTS}/audit-pack.zip`; await dl.saveAs(zipPath)
const listing = execFileSync('unzip', ['-l', zipPath]).toString()
for (const f of ['journal_lines.csv', 'trial_balance.csv', 'chart_of_accounts.csv', 'audit_log.csv', 'verification.json', 'README.txt']) if (!listing.includes(f)) throw new Error('missing ' + f)
log('audit pack downloaded with journal, trial balance, chart, audit log, verification')

const v = sql(`select (select count(*) from journal_entries where tenant_id='${tenant}') || ' entries, ' || (select count(*) from audit_log where tenant_id='${tenant}' and action like 'period.%') || ' period actions'`)
log(v)
await browser.close()
console.log('E2E ACCOUNTING PASSED')

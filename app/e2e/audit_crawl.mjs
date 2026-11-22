// Audit crawl: every screen for several business types, in English and Arabic, at desktop / tablet / small widths.
// Reports page errors, console errors, failed API calls (4xx/5xx) and horizontal overflow.
import { createRequire } from 'node:module'
import fs from 'node:fs'
const require = createRequire(import.meta.url)
const { chromium } = require('playwright')
const APP = process.env.APP_URL || 'http://localhost:5173'
const OUT = process.env.OUT || './audit'
fs.mkdirSync(OUT, { recursive: true })
const ACCOUNTS = (process.env.ACCOUNTS || 'cafe@demo.ztrust,salon@demo.ztrust,grocery@demo.ztrust,laundry@demo.ztrust').split(',')
const SIZES = [[1440, 900, 'desktop'], [1024, 768, 'tablet'], [800, 1280, 'portrait']]
const findings = []
const browser = await chromium.launch()
for (const email of ACCOUNTS) {
  for (const lang of ['en', 'ar']) {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
    const p = await ctx.newPage()
    let where = 'login'
    p.on('pageerror', (e) => findings.push({ email, lang, where, kind: 'pageerror', msg: e.message }))
    p.on('console', (m) => { if (m.type() === 'error' && !/favicon|Download the React DevTools/.test(m.text())) findings.push({ email, lang, where, kind: 'console', msg: m.text().slice(0, 300) }) })
    p.on('response', (r) => { if (r.status() >= 400 && /\/sb\//.test(r.url())) findings.push({ email, lang, where, kind: `http ${r.status()}`, msg: r.url().replace(/.*\/sb/, '').slice(0, 200) }) })
    await p.goto(APP); await p.evaluate((l) => localStorage.setItem('zt.lang', l), lang); await p.goto(APP)
    await p.getByRole('button', { name: /Sign in|تسجيل الدخول/ }).first().click().catch(() => {})
    await p.fill('#login-email', email); await p.fill('#login-password', 'Secret#2026')
    await p.locator('form button[type=submit], form button.primary').last().click()
    await p.locator('aside nav').waitFor({ timeout: 20000 })
    const links = await p.locator('aside nav a').evaluateAll((as) => as.map((a) => a.getAttribute('href')))
    for (const href of [...links, '/display']) {
      for (const [w, h, size] of SIZES) {
        where = `${href} @${size}`
        await p.setViewportSize({ width: w, height: h })
        await p.goto(APP + href); await p.waitForTimeout(1200)
        const over = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
        if (over > 2) findings.push({ email, lang, where, kind: 'overflow', msg: `page is ${over}px wider than the screen` })
        // tabs inside the screen
        if (size === 'desktop') {
          const tabs = await p.locator('.page .tabs button').count()
          for (let i = 0; i < tabs; i++) { where = `${href} tab ${i} @desktop`; await p.locator('.page .tabs button').nth(i).click().catch(() => {}); await p.waitForTimeout(700) }
        }
        if (size === 'desktop' && lang === 'ar') await p.screenshot({ path: `${OUT}/${email.split('@')[0]}${href.replace(/\//g, '_')}-${lang}.png` })
      }
    }
    await ctx.close()
  }
}
await browser.close()
fs.writeFileSync(`${OUT}/findings.json`, JSON.stringify(findings, null, 1))
const uniq = new Map(); for (const f of findings) { const k = `${f.kind}|${f.where.replace(/ @.*/, '')}|${f.msg}`; uniq.set(k, (uniq.get(k) ?? 0) + 1) }
for (const [k, n] of uniq) console.log(n, k)
console.log('AUDIT DONE', findings.length)

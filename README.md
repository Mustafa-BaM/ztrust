# Z Trust · MVP

POS + store back office on **React (Vite) + Supabase**. One catalog, one customer record, one stock count and one ledger.

## What this first slice does

| Area | Included |
|---|---|
| Onboarding | Sign-up, 7-day trial clock, country pack (currency, decimals, VAT, inclusive/exclusive), business type, first branch, owner PIN |
| POS | Touch mode and keyboard mode (F2 search · F3 customer · F4 qty · F6 discount · F8 pay · F9 hold), barcode / SKU scan, `3*` quantity prefix, Arabic-aware search, hold & recall |
| Payments | Split across cash (with change and quick notes), card, on account (credit limit), payment link, bank transfer, store credit |
| Controls | Permission matrix with limits (discount %, refund amount, cancel amount), manager PIN approval, every exception written to an append-only audit log |
| Refunds | Partial refund or full cancellation always issues a **credit note**; posted invoices can't be edited or deleted (enforced by triggers) |
| Offline | PWA service worker + IndexedDB catalog and outbox; sales replay safely thanks to a per-sale `client_id` idempotency key |
| Shift | Opening float, blind cash count, Z report, cash over/short posted to the ledger, "no sale" drawer log |
| Ledger | Double-entry, hash-chained journal posted automatically for sales, refunds, collections, payment links, stock and cash variance |
| Inventory | Stock by branch (append-only movements), receive with moving-average cost, adjustments |
| Reports | Role-based dashboard (owner picks widgets per role), sales by day/hour/item/cashier, payments, exceptions, VAT, trial balance, CSV export (Excel-ready Arabic) |
| Receipts | Bilingual 58/80 mm/A4 via the OS print dialog (works with any installed printer), ZATCA simplified-invoice QR (TLV) for Saudi Arabia |
| Languages | Arabic and English across the app with full RTL |
| Role packages | 12 templates (Owner, Branch manager, Shift supervisor, Cashier, Waiter, Kitchen/barista, Accountant, Purchasing officer, Storekeeper, HR, Auditor, Staff); the owner creates custom packages from any template and sets limits per permission |
| Kitchen (KDS) | Stations per branch, routing by category, one ticket per station created in the same transaction as the sale, New → Preparing → Ready → Served with recall, late-order colours, item tick-off, sound, kitchen chit printing, screen / printer / both per station |
| Accounting (audit-ready) | Gapless JV numbers and a verifiable SHA-256 hash chain over stored entries + lines (`verify_ledger` recomputes it and reports altered entries, chain breaks, gaps, unbalanced entries); statement-ready chart of accounts with custom accounts; manual journals with maker-checker and amount limits; reversing entries; month close/lock (finished months only, owner reopens with reason); expenses with input VAT; supplier payments; trial balance, account ledger, income statement, balance sheet (balance check), VAT return, AR/AP aging (FIFO); one-click audit pack (zip: journal lines with hashes, trial balance, chart, audit log, verification) |
| Design | Z/ز mark (one stroke reads as Latin Z and Arabic zay), ink icon rail, POS cart as a live receipt with one-tap exact cash/card, colour-coded categories, interactive dashboard (clickable KPIs with period comparison and sparklines, trend chart with crosshair and table view, payment mix, weekday × hour heatmap) |
| Restaurants & inventory | Item types: product, **recipe** (sold, consumes ingredients) and **ingredient** (stocked in kg/g/l/ml/pcs, never sold); every recipe sale deducts ingredients at moving-average cost and posts COGS; stock on hand with value, 30-day usage, days of cover and reorder alerts; stock card with running balance; stock counts post only the differences to stock and the ledger |
| Product photos | Optional per item (compressed to WebP, Supabase Storage), shown on the POS when enabled in Settings |
| Receipts | Phone numbers, address, CR, website, extra header, terms & conditions and closing message, with live preview |
| Delivery platforms | Keeta, Talabat, Jahez, HungerStation, Deliveroo, Careem, Noon Food, Mrsool, ToYou: per-branch channels with commission %, orders by webhook (`delivery-webhook` Edge Function, token per channel, idempotent) or keyed at the POS; platform receivable cleared by the payout (commission as expense); sales by channel |
| Kitchen timing | Live per-second timer on every ticket (waiting / preparing / ready-in) with a progress bar against the station target; kitchen times report (average wait, preparation, total, pickup, on-time %, slowest, by hour); live "Kitchen now" dashboard card |
| Purchasing | Suppliers, purchase orders, approval within amount limits with **segregation of duties** (creator can never approve), partial and full goods receipts, moving-average cost, accounts payable by supplier |

## Branch Hub (kitchen and printers without internet)

Like Loyverse, devices on the same shop Wi-Fi keep working together when the internet is down:

```
 POS tablets ─┐                         ┌─ kitchen screens (KDS)
              ├── shop Wi-Fi ── Hub ────┤
 waiters ─────┘                         └─ network kitchen printers (ESC/POS, port 9100)
                                 │
                       internet (when available) → Supabase cloud
```

1. Settings → Kitchen stations: set each station's printer IP, then **Create hub token**.
2. On an always-on device in the branch: `SUPABASE_URL=… SUPABASE_ANON_KEY=… HUB_TOKEN=… APP_DIR=./app/dist node hub/src/hub.mjs`
3. Open the address it prints (e.g. `http://192.168.1.20:8787`) on every POS and kitchen tablet and enter the pairing code once.

With the internet down, sales are queued on the POS, tickets go POS → hub → kitchen screens instantly, and kitchen chits print as images (Arabic shaped correctly) on network printers. When the internet returns, the POS sends the sales and the hub sends the kitchen tickets with their timings, linked to the sales, without duplicates.

## Business types, modules and integrations

- **Business types**: 18 profiles in the catalog (`business_profiles`), 9 open for sign-up: restaurant, café, fast food & cloud kitchen, grocery, fashion, stationery & gifts, perfume & oud, salon & barber, laundry. Each switches on the modules it needs; sign-up cards list only what exists today and mark the rest "Coming".
- **Modules** (`feature_modules`, `tenants.features`): kitchen, recipes, delivery, sell on account, purchasing, integrations are built; 16 more are planned and cannot be switched on yet. Owner switches them in Settings → Business type & modules. Off = hidden in the app **and** refused by the server (kitchen tickets, recipe lines, delivery channels and orders, purchase orders, on-account payments). Data is never deleted.
- **Tenant guard**: plan, trial, add-ons, currency, country and module switches cannot be changed by a direct table update; only through the owner functions (or billing with the service role).
- **Shop logo**: uploaded in Settings → Business and receipt; a colour copy (receipt preview, payment page) and a Floyd–Steinberg black-and-white copy at 576 dots for thermal printers. Show/hide and three sizes.
- **Webhooks** (Settings → Integrations): events `sale.completed`, `refund.created`, `order.ready`, `stock.low`, `shift.closed`, `customer.created`, `payment_link.paid` go to an outbox and are sent by `dispatch-events` with an HMAC-SHA256 signature (`X-ZTrust-Signature: sha256=…` over `<timestamp>.<body>`), retried after 1 min, 5 min, 30 min, 2 h and 12 h. Delivery log in the app. Works with n8n, Make, Zapier or any HTTPS endpoint.
- **API keys**: owner creates read-only keys (products, stock, sales, customers), shown once, stored hashed, revocable. `GET /functions/v1/public-api/v1/{items|stock|sales|customers}` with `Authorization: Bearer ztk_…`.
- **Paid add-ons** (`tenants.addons`, set by billing only): WhatsApp and the AI assistant are shown as "on request"; not built yet.

Deploy: `supabase functions deploy dispatch-events --no-verify-jwt` (secret `DISPATCH_SECRET`, schedule it every minute with pg_cron + pg_net) and `supabase functions deploy public-api --no-verify-jwt`.

## Phases B–D (all nine launch business types complete)

| Module | What it does |
|---|---|
| Add-ons | Groups (required / optional, max picks) with priced options that can use stock (oat milk 0.2 l). Chosen at the till; checked and priced by the server. |
| Variants | Size × colour matrix under a template; each variant has its own barcode, SKU and stock; the till asks for the size and colour. |
| Batches & expiry | Receive with batch number and expiry; sales take the batch that expires first (FEFO); expiry list and write-off to inventory adjustments. |
| Weighed items | Sold per kg; weight dialog on tap; scale labels (prefix + PLU + weight or price) read from the scanner. |
| Promotions | Percent, buy X get Y, bundle at a fixed price, amount off the bill; dates, weekdays, happy hour, coupons. Same engine on the till (`app/src/lib/promotions.ts`) and the server (`promo_allowance`); the server caps what the till claims. No PIN needed. |
| Appointments | Day calendar per staff member, working hours, no double booking (exclusion constraint), public booking page `/book/<slug>`, checkout from the appointment. |
| Commissions | Per service or per staff member, on net sales, refunds deducted; report in Reports. |
| Packages & memberships | Prepaid sessions sold as an item; net price held in deferred revenue and released per session; sessions paid automatically at checkout; `expire_packages` releases what is left at expiry. |
| Job cards & pre-orders | Intake with tags, reference, due time; deposits held as a liability; ready → event `job.ready`; collect and pay with the deposit applied automatically. |
| Tables | Floor plan, one open order per table, send rounds to the kitchen, voiding a sent line needs a PIN, split the bill. |
| Loyalty | Points on what was paid with money, redeemed as a tender (booked as loyalty expense), reversed on refunds. |

Printing: choose 80 mm, 58 mm or an A4 invoice at print time; receipt font (IBM Plex Mono / Sans Arabic, Cairo, Tajawal, Noto Naskh, Courier) and text size in Settings. Works from any browser's print dialog (Safari ignores the page size and uses its own page setup).

Known limits: deposits carry no VAT at the time of payment (Saudi rules tax advance payments — change before a KSA launch); loyalty redemptions are expensed rather than deferred (IFRS 15 would defer); unlimited memberships are recognised at sale; table orders, packages, deposits and points need internet; `expire_packages` must be scheduled (pg_cron).

## Growth additions

Open business types: 15 (adds bakery, florist, spa, car wash, gym and central market / co-op).

| Module | What it does |
|---|---|
| QR ordering & kiosk | Guests order from `/order/<shop>?t=<table code>`; staff accept into the table's open order and the kitchen. Kiosk `/order/<shop>?kiosk=1`: pay at the counter. Printable QR sheet per table. |
| Customer display | `/display` on the till's second screen follows the cart live (same device). |
| Gift cards | Sold at the till without VAT (liability), spent with the code; balances and expiry in Customers. |
| Reservations & waitlist | Table reservations without double booking, walk-in waitlist with a WhatsApp "table ready". |
| Branch transfers & production | Stock leaves one branch and arrives when confirmed (shortfall = transfer loss); production makes stocked items from their recipe. |
| Own delivery | Delivery address and driver at the till, cash on delivery held as "cash with drivers" until handed in to the drawer; driver's own list. |
| Attendance | Clock in/out from the phone within the branch radius; timesheet and CSV. |
| Memberships check-in | Unlimited memberships (gym, car wash) checked in from the customer card. |

## Design system, dashboard and POS (v4)

- **Four themes plus Automatic**, switched live from the top bar or Ctrl K and saved per user (`user_prefs`, newest wins over localStorage): Executive Navy & Slate, Modern Emerald & Glass, Minimalist Pearl & Warm Gold, Obsidian Pro Dark. Each theme sets colours, corner radius, elevation and the Arabic font (`app/src/themes.css`, tokens only). Numbers use `tabular-nums`.
- **Shell**: grouped sidebar that can be collapsed (Ctrl B, remembered), command palette (Ctrl K) that finds screens, actions, settings tabs, themes, customers, items, invoices and job cards, with deep links (`?c=`, `?q=`, `?new=1`, `?tab=`).
- **Dashboard**: each user can show, hide and reorder widgets (drag or arrows), reset to the role default; periods Today / 7 / 30 days / month / custom range with comparison; profit widget (gross profit and margin from item cost, net profit from the income statement with `finance.view`); "Needs attention" widget (out of stock, below reorder point, batches expiring in 7 days, unpaid invoices and links, waiting online orders, open tables, late or ready jobs, today's appointments, deliveries).
- **POS**: card network per country (KW: K-Net, Visa / Mastercard, Apple Pay; SA: mada, STC Pay…) stored on the payment and on the tender report; invoice discount (% or amount, spread over lines so discount limits and PIN approval still apply, F10); invoice note on the receipt and the sale; line notes for every business type; one-tap Park (F9) with recall chips; recalling a sale parks the one on screen.
- **Report accuracy** (migration 0018): gift card and package sales are prepaid, not sales (`prepaid_sold` column); deposits and delivery cash appear in the tender report. `supabase/tests/reconcile.sql` cross-checks ledger, VAT, revenue, invoices = lines = payments, batches, gift cards, tender report and sales report.
- `app/e2e/audit_crawl.mjs` opens every screen and tab in English and Arabic at 1440, 1024 and 800 px and reports errors, failed requests and overflow.

## ERP additions (P1 / P2), simple HR & payroll, global readiness

- **Shift**: cash in / cash out with a reason and approval (`cash_move`), expected cash includes them; printable X report (80 mm) and Z report.
- **POS**: price change needs `sale.price`; customer price lists applied on the till; serial / IMEI picked or scanned per unit (warranty dates); exchange from the sale (returned value pays the new items, difference back in cash); cash ceiling per invoice (setting: off / warn / block, also enforced by the server); card networks and banknotes from settings (country defaults).
- **Sales**: quotation → sales order → delivery note → invoice at the till (`/quotes`); customer statement and purchase history; debit notes; price lists.
- **Purchasing**: purchase requests; supplier invoice with three-way match (order price × received qty, variance needs approval, duplicates refused); returns to suppliers (with serials); supplier statements.
- **Finance**: cash flow (direct), bank statement import and matching, petty cash top-ups, account hierarchy, cost centres (branch default + per expense) with P&L per centre.
- **HR & payroll** (`/hr`): employees with document expiry, leave, advances, monthly payroll (basic, allowances, POS commissions, overtime, unpaid leave, advances), posting and payment, payslips, bank transfer CSV. Leave and end-of-service rules are settings (defaults to be confirmed against the applicable labour law).
- **Global**: business dates follow the branch / country time zone (`_today`), no fixed country time zone or date format in the UI, receipt languages are a setting, country rules live in Settings → Business → Payments & compliance.
- **Security**: migration 0023 removes the implicit PUBLIC execute on functions (anonymous key limited to the public pages, hub, webhooks and API keys).
- Tests: `supabase/tests/erp_p1p2_hr_flow.sql`, `app/e2e/p0_screens.mjs`.

## Run it

```bash
# 1. Database (local)
npx supabase start            # or link to a cloud project: npx supabase link --project-ref <ref>
npx supabase db reset         # applies supabase/migrations/*
# 2. App
cd app && cp .env.example .env.local   # fill URL + anon key printed by `supabase start`
npm install && npm run dev
```

Deploy the database to a cloud project with `npx supabase db push` **after reviewing the target project's existing schema**. These migrations create tables in `public` and assume a fresh project.

Edge functions: `supabase functions deploy invite-staff` and `supabase functions deploy payment-webhook --no-verify-jwt` (set `PAYMENT_WEBHOOK_SECRET`).

## Tests

```bash
supabase/tests/run.sh   # throwaway Postgres 16 · pos_flow + kitchen_purchasing_flow + accounting_flow (incl. tamper detection): applies migrations, runs the money-flow test (split tender, approvals, refunds, AR, payment link, shift variance, ledger balance, hash chain, tenant isolation, VAT-inclusive maths)
```

Browser tests (need `supabase start` + `npm run dev`; the hub test also needs `npm run build`) — `app/e2e/hub_offline.mjs` cuts the internet for the whole shop including the hub: `node app/e2e/smoke.mjs` and `SERVICE_KEY=… node app/e2e/roles_kds.mjs` and `SERVICE_KEY=… node app/e2e/accounting.mjs` and `SERVICE_ROLE_KEY=… ANON_KEY=… node --experimental-strip-types app/e2e/profiles_integrations.mjs` (runs a local signed-webhook receiver and the real dispatcher).

## Not in this slice yet

Payment gateway checkout (the link page and webhook are ready), ZATCA Phase 2 signing/reporting, direct ESC/POS printing (Print Bridge), serial/IMEI & warranty, quotations & B2B prices, consignment, gold-rate pricing, WhatsApp and the AI assistant add-ons, platform-specific webhook adapters (need each platform's partner API documentation), bank reconciliation, fixed-asset register and depreciation runs, year-end closing entry, consignment, biometric/geofence attendance, payroll, subscription billing, and on-premise packaging. These follow the roadmap phases.

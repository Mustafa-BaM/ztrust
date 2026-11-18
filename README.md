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

Browser tests (need `supabase start` + `npm run dev`; the hub test also needs `npm run build`) — `app/e2e/hub_offline.mjs` cuts the internet for the whole shop including the hub: `node app/e2e/smoke.mjs` and `SERVICE_KEY=… node app/e2e/roles_kds.mjs` and `SERVICE_KEY=… node app/e2e/accounting.mjs`.

## Not in this slice yet

Payment gateway checkout (the link page and webhook are ready), ZATCA Phase 2 signing/reporting, direct ESC/POS printing (Print Bridge), open checks / pay-later tables, structured modifiers/recipes/FEFO, bank reconciliation, fixed-asset register and depreciation runs, year-end closing entry, consignment, biometric/geofence attendance, payroll, subscription billing, integrations hub, and on-premise packaging. These follow the roadmap phases.

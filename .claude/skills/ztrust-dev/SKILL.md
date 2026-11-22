---
name: ztrust-dev
description: How to build, run, test and extend Z Trust (زد ترست), the GCC-first POS/ERP in this repo — React 19 + Vite + Supabase. Use for any change to the app, the database migrations, reports, accounting, POS, themes or translations in this repository.
---

# Z Trust development

## Owner preferences
- Reply in Arabic, executive style, technical terms in English. Finished outputs, not plans. Frank opinions.
- Never invent facts, laws or numbers. Kuwaiti labour-law or decree values are settings with a "verify with legal" note, never hard-coded truths.
- Do not rename, move or delete the owner's assets without approval. Check the existing schema before any migration.
- Screenshots are sent one by one (never zipped). Commit/push only to branch `z-trust-mvp`.

## Layout
- `app/` React 19 + Vite 7 + TS, react-router 7, PWA. Pages in `app/src/pages`, shared UI in `app/src/components`.
- `supabase/migrations/2026111800NNNN_*.sql` — numbered, append-only. Never edit an applied migration; add a new one.
- `supabase/tests/run.sh` (SQL suites on a throwaway PG16), `supabase/tests/reconcile.sql` (cross-checks: ledger, VAT, revenue, invoices = lines = payments, batches, gift cards, tender report, sales report).
- `app/e2e/*.mjs` Playwright browser tests; `app/e2e/audit_crawl.mjs` opens every route × tab × EN/AR × 3 widths.
- `hub/` branch hub (kitchen and printers offline).

## Run locally
```bash
pgrep dockerd || (nohup dockerd >/tmp/dockerd.log 2>&1 &)
npx -y supabase@2 start -x studio,imgproxy,realtime,edge-runtime,logflare,vector,supavisor,postgres-meta,mailpit
cd app && VITE_SUPABASE_URL=/sb VITE_PUBLIC_APP_URL= npx vite --host 0.0.0.0 --port 5173 --strictPort   # /sb proxies to 127.0.0.1:54321
```
Apply one migration to the running DB: `psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -f <file>` then `NOTIFY pgrst, 'reload schema'`.
Demo logins: `cafe@demo.ztrust` / `Secret#2026` (others seeded the same way).

## Tests (run all before committing)
- `bash supabase/tests/run.sh` → every suite prints `ALL … PASSED`.
- `psql … -f supabase/tests/reconcile.sql` → every check returns no rows.
- `cd app && npx tsc -b --noEmit && npm run build`.
- e2e: `ANON_KEY` from `app/.env.local`, `SERVICE_KEY`/`SERVICE_ROLE_KEY` from `npx supabase status -o env`; run
  `node --experimental-strip-types e2e/<name>.mjs` for smoke, roles_kds, accounting, recipes_delivery, modules_bcd, growth, profiles_integrations;
  hub_offline needs `npm run build` and `pkill -f hub/src/hub.mjs` first.
- Selectors use visible English labels; when a button label changes, update the e2e files.

## Database rules (learned the hard way)
- Money is integer minor units (`bigint`); KWD has 3 decimals. Front-end rounding (`pgRound`) must match Postgres `round`.
- New enum values go in their **own** migration file.
- Default privileges revoke EXECUTE: every new RPC needs `grant execute … to authenticated`.
- RLS on every table; reads via `can_see_branch(tenant_id, branch_id)` / `is_member`. Writes go through `security definer` RPCs that call `_require(tenant, perm, value, pin)`.
- Errors: `ZT401` approval needed (POS shows a PIN prompt), `ZT403` denied, `ZT422` validation, `ZT423` period closed.
- Accounting: post with `_post` / `_post_ex` (balanced or it raises); journal entries are hash-chained and sealed — never update journal lines. New system accounts: insert into `coa_template` **and** into `accounts` for existing tenants.
- New permissions: `permission_catalog` + `role_templates.perms` + `role_permissions` for existing roles (only the new ones).
- `tenants.plan/features/addons` are guarded; modules switch via `set_feature`.
- When replacing a big function (e.g. `complete_sale`), dump the live definition with `pg_get_functiondef`, patch it, and re-test the reconciliation.
- Gift cards and packages are prepaid liabilities, not sales (`v_daily_sales.prepaid_sold`).

## UI rules
- Themes: `data-theme` on `<html>` (auto, executive, emerald, pearl, obsidian), tokens only in `app/src/themes.css`; never hard-code colours.
- RTL-first: logical CSS properties, `flip-rtl` on directional icons, `tabular-nums` on numbers.
- Every new English string needs an Arabic entry in `app/src/lib/ar.ts` (English text is the key).
- Preferences per user: `usePrefs()` (localStorage `zt.prefs` + table `user_prefs`).
- Deep links: `?q=`, `?new=1`, `?c=`, `?tab=`; Ctrl K palette in `components/CommandPalette.tsx`.

## Deliverable
Finish with a short Arabic report: what changed, test results (with exact pass output), honest limits, then screenshots sent individually.

// Read-only REST API for integrations (n8n, ERP, BI). Authenticate with an API key created in Settings → Integrations.
//   GET /public-api/v1/items?limit=100
//   GET /public-api/v1/stock
//   GET /public-api/v1/sales?from=2026-11-01T00:00:00Z&to=2026-11-02T00:00:00Z&limit=500
//   GET /public-api/v1/customers
//   Header: Authorization: Bearer ztk_xxxxxxxx_...
// Amounts are integers in minor units (fils, halalas); the response says the currency and its decimals.
// Deploy: supabase functions deploy public-api --no-verify-jwt
import { createClient } from 'npm:@supabase/supabase-js@2'

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method !== 'GET') return json({ error: 'method not allowed' }, 405)
  const key = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!key.startsWith('ztk_')) return json({ error: 'missing API key' }, 401)
  const url = new URL(req.url)
  const m = url.pathname.match(/\/v1\/(items|stock|sales|customers)\/?$/)
  if (!m) return json({ error: 'unknown endpoint; use /v1/items, /v1/stock, /v1/sales or /v1/customers' }, 404)
  const params = Object.fromEntries(['limit', 'from', 'to'].flatMap((k) => (url.searchParams.has(k) ? [[k, url.searchParams.get(k)]] : [])))
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!)
  const { data, error } = await sb.rpc('api_query', { p_key: key, p_resource: m[1], p: params })
  if (error) return json({ error: error.message }, error.code === '42501' ? 403 : 400)
  return json(data)
})

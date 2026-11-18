// Receives orders from delivery platforms (Keeta, Talabat, Jahez, …) or from an integration partner.
// Authentication: header `x-channel-token` (created in Settings → Delivery platforms → Connect webhook).
// Each platform has an adapter that maps its payload to Z Trust's normalised order. The normalised
// format below is accepted from any platform today; platform-specific adapters are added as each
// platform's partner API documentation becomes available (their order APIs are not public).
// Deploy: supabase functions deploy delivery-webhook --no-verify-jwt
import { createClient } from 'npm:@supabase/supabase-js@2'

type Normalised = {
  external_ref: string
  customer_name?: string
  customer_phone?: string
  note?: string
  items: { item_id?: string; sku?: string; name: string; qty: number; unit_price: number; note?: string }[]
}

// unit prices arrive in the platform's major units (e.g. 1.250 KWD); Z Trust stores minor units
const minor = (v: unknown, decimals: number) => Math.round(Number(v) * 10 ** decimals)

const adapters: Record<string, (body: any, decimals: number) => Normalised> = {
  // Z Trust normalised format (also used by integration partners and tests)
  default: (b, d) => ({
    external_ref: String(b.external_ref ?? b.order_id ?? b.id),
    customer_name: b.customer_name ?? b.customer?.name, customer_phone: b.customer_phone ?? b.customer?.phone, note: b.note,
    items: (b.items ?? []).map((i: any) => ({ item_id: i.item_id, sku: i.sku ?? i.external_id, name: i.name, qty: Number(i.qty ?? i.quantity ?? 1),
      unit_price: i.unit_price_minor ?? minor(i.unit_price ?? i.price, d), note: i.note ?? i.comment })),
  }),
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })
  const token = req.headers.get('x-channel-token') ?? ''
  const platform = new URL(req.url).searchParams.get('platform') ?? 'default'
  const decimals = Number(new URL(req.url).searchParams.get('decimals') ?? 3)
  let order: Normalised
  try { order = (adapters[platform] ?? adapters.default)(await req.json(), decimals) }
  catch (e) { return new Response(JSON.stringify({ error: `bad payload: ${(e as Error).message}` }), { status: 400 }) }

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!)
  const { data, error } = await sb.rpc('ingest_delivery_order', { p_token: token, p: order })
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: error.code === '42501' ? 401 : 400 })
  // platforms expect a fast 200 with the merchant's reference and preparation time
  return new Response(JSON.stringify({ accepted: true, ...data }), { status: 200, headers: { 'Content-Type': 'application/json' } })
})

// Receives "payment succeeded" callbacks from the payment gateway and marks the payment link paid.
// MVP: a generic, shared-secret webhook. Each gateway (Tap, Checkout.com, MyFatoorah, Moyasar…) gets its own
// adapter that verifies the gateway's signature and maps its payload to { token, gateway_ref }.
// Deploy: supabase functions deploy payment-webhook --no-verify-jwt ; set secret PAYMENT_WEBHOOK_SECRET
import { createClient } from 'npm:@supabase/supabase-js@2'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })
  const secret = Deno.env.get('PAYMENT_WEBHOOK_SECRET')
  if (!secret || req.headers.get('x-webhook-secret') !== secret) return new Response('unauthorized', { status: 401 })

  const { token, gateway_ref, status } = await req.json()
  if (status && status !== 'paid') return new Response(JSON.stringify({ ignored: status }), { status: 200 })
  if (!token || !gateway_ref) return new Response('token and gateway_ref required', { status: 400 })

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data, error } = await admin.rpc('mark_payment_link_paid', { p_token: token, p_gateway_ref: gateway_ref })
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400 })
  return new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
})

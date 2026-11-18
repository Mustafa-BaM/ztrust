// Sends queued webhook events (n8n, Make, Zapier, any HTTPS endpoint). Run it every minute:
//   select cron.schedule('zt-dispatch', '* * * * *', $$ select net.http_post(
//     url := '<SUPABASE_URL>/functions/v1/dispatch-events', headers := '{"Authorization":"Bearer <DISPATCH_SECRET>"}'::jsonb) $$);
// Deploy: supabase functions deploy dispatch-events --no-verify-jwt ; set secret DISPATCH_SECRET
import { createClient } from 'npm:@supabase/supabase-js@2'
import { dispatchOnce } from '../_shared/dispatch.ts'

Deno.serve(async (req) => {
  const secret = Deno.env.get('DISPATCH_SECRET')
  if (!secret || req.headers.get('authorization') !== `Bearer ${secret}`) return new Response('unauthorized', { status: 401 })
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  // drain for up to ~50 s so one cron tick clears a burst
  const until = Date.now() + 50_000
  const total = { sent: 0, failed: 0 }
  while (Date.now() < until) {
    const r = await dispatchOnce(admin, { limit: 100 })
    total.sent += r.sent; total.failed += r.failed
    if (r.sent + r.failed === 0) break
  }
  return new Response(JSON.stringify(total), { headers: { 'Content-Type': 'application/json' } })
})

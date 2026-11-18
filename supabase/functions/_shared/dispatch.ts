// Delivers queued events (event_outbox) to the businesses' webhook URLs. Runtime-neutral: Web Crypto + fetch only,
// so the same code runs in the Edge Function and in the Node test.
//
// Every request carries:
//   X-ZTrust-Event        e.g. sale.completed
//   X-ZTrust-Delivery     the outbox id (use it to ignore duplicates; a delivery can arrive twice after a timeout)
//   X-ZTrust-Timestamp    unix seconds
//   X-ZTrust-Signature    sha256=<hex HMAC-SHA256 of "<timestamp>.<raw body>" with the endpoint's whsec_ secret>
// Receivers should reject timestamps older than 5 minutes.

export interface Claimed { id: number; event: string; payload: unknown; url: string; secret: string; attempts: number }
export interface Rpc { rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string } | null }> }

const enc = new TextEncoder()

export async function sign(secret: string, timestamp: number, body: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(`${timestamp}.${body}`))
  return 'sha256=' + [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

export async function deliver(e: Claimed, fetchFn: typeof fetch = fetch, timeoutMs = 10_000): Promise<{ ok: boolean; code: number | null; error: string | null }> {
  const body = JSON.stringify({ id: e.id, ...(e.payload as Record<string, unknown>) })
  const ts = Math.floor(Date.now() / 1000)
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetchFn(e.url, {
      method: 'POST', signal: ctrl.signal, redirect: 'manual',
      headers: { 'Content-Type': 'application/json', 'User-Agent': 'ZTrust-Webhooks/1', 'X-ZTrust-Event': e.event,
        'X-ZTrust-Delivery': String(e.id), 'X-ZTrust-Timestamp': String(ts), 'X-ZTrust-Signature': await sign(e.secret, ts, body) },
      body,
    })
    await res.body?.cancel().catch(() => {})
    return res.status >= 200 && res.status < 300 ? { ok: true, code: res.status, error: null } : { ok: false, code: res.status, error: `HTTP ${res.status}` }
  } catch (err) {
    return { ok: false, code: null, error: ctrl.signal.aborted ? `timeout after ${timeoutMs / 1000}s` : (err as Error).message }
  } finally { clearTimeout(timer) }
}

/** One pass: claim due events, send them in parallel (bounded), report each result. Returns counts. */
export async function dispatchOnce(sb: Rpc, opts: { limit?: number; concurrency?: number; fetchFn?: typeof fetch } = {}) {
  const { data, error } = await sb.rpc('claim_events', { p_limit: opts.limit ?? 50 })
  if (error) throw new Error(error.message)
  const queue = [...((data ?? []) as Claimed[])]
  let sent = 0, failed = 0
  const worker = async () => {
    for (let e = queue.shift(); e; e = queue.shift()) {
      const r = await deliver(e, opts.fetchFn)
      const { error: fe } = await sb.rpc('finish_event', { p_id: e.id, p_ok: r.ok, p_code: r.code, p_error: r.error })
      if (fe) throw new Error(fe.message)
      if (r.ok) sent++; else failed++
    }
  }
  await Promise.all(Array.from({ length: opts.concurrency ?? 8 }, worker))
  return { sent, failed }
}

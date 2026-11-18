import { createClient } from '@supabase/supabase-js'

const rawUrl = import.meta.env.VITE_SUPABASE_URL as string | undefined
// a relative address ("/sb") means "same server as the app" (used for previews through a proxy)
const url = rawUrl?.startsWith('/') ? `${window.location.origin}${rawUrl}` : rawUrl
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

export const supabaseUrl = url || 'http://localhost:54321'
export const isConfigured = Boolean(url && key)
export const supabase = createClient(url || 'http://localhost:54321', key || 'public-anon-key', {
  auth: { persistSession: true, autoRefreshToken: true },
})
export const publicAppUrl = (import.meta.env.VITE_PUBLIC_APP_URL as string | undefined) || window.location.origin

export type ZtError = { kind: 'approval' | 'denied'; perm: string } | { kind: 'message'; message: string }

/** Turns PostgREST / Postgres errors into something the UI can act on. */
export function parseError(e: unknown): ZtError {
  const err = e as { code?: string; message?: string }
  const msg = err?.message || String(e)
  if (err?.code === 'ZT401' || msg.startsWith('APPROVAL_REQUIRED:')) return { kind: 'approval', perm: msg.split(':')[1] || '' }
  if (err?.code === 'ZT403' || msg.startsWith('APPROVAL_DENIED:')) return { kind: 'denied', perm: msg.split(':')[1] || '' }
  return { kind: 'message', message: friendly(msg) }
}

/** Server error codes that deserve a plain-language message (translated by the caller through t()). */
export function friendly(msg: string): string {
  if (msg.startsWith('PERIOD_CLOSED:')) return 'This accounting period is closed. Ask the owner to reopen it, or use a date in an open period.'
  if (/duplicate key value.*items_barcode_uq/.test(msg)) return 'Another product already uses this barcode.'
  if (/duplicate key value.*accounts_tenant_id_code_key/.test(msg)) return 'An account with this code already exists.'
  return msg
}

export async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw error
  return data as T
}

export const uuid = () => crypto.randomUUID()

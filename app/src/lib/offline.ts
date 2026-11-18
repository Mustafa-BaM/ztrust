import { createStore, del, entries, get, set } from 'idb-keyval'
import { useEffect, useState, useSyncExternalStore } from 'react'
import { parseError, supabase } from './supabase'
import type { Category, Customer, Item } from './types'

// IndexedDB stores: the catalog snapshot used by the POS, and the outbox of sales made offline.
const catalogStore = createStore('zt-catalog', 'kv')
const outboxStore = createStore('zt-outbox', 'sales')

export interface CatalogStation { id: string; name: string; is_default: boolean; sort: number }
export interface Catalog { items: Item[]; categories: Category[]; customers: Customer[]; stations?: number; stationList?: CatalogStation[]; channels?: { id: string; display_name: string; platform: string }[]; savedAt: string }

export async function saveCatalog(tenantId: string, c: Omit<Catalog, 'savedAt'>) {
  await set(tenantId, { ...c, savedAt: new Date().toISOString() }, catalogStore)
}
export const loadCatalog = (tenantId: string) => get<Catalog>(tenantId, catalogStore)

export interface OutboxEntry {
  client_id: string
  payload: Record<string, unknown>
  created_at: string
  attempts: number
  error?: string
}

let listeners: Array<() => void> = []
let outboxCount = 0
const emit = () => listeners.forEach((l) => l())

async function refreshCount() {
  outboxCount = (await entries(outboxStore)).length
  emit()
}

export async function enqueueSale(payload: Record<string, unknown>) {
  const e: OutboxEntry = { client_id: String(payload.client_id), payload, created_at: new Date().toISOString(), attempts: 0 }
  await set(e.client_id, e, outboxStore)
  await refreshCount()
}

export async function listOutbox(): Promise<OutboxEntry[]> {
  return (await entries<string, OutboxEntry>(outboxStore)).map(([, v]) => v).sort((a, b) => a.created_at.localeCompare(b.created_at))
}

let flushing = false
/** Sends queued sales in order. The server's client_id idempotency makes retries safe. */
export async function flushOutbox(): Promise<{ sent: number; failed: number }> {
  if (flushing || !navigator.onLine) return { sent: 0, failed: 0 }
  flushing = true
  let sent = 0, failed = 0
  try {
    for (const e of await listOutbox()) {
      const { error } = await supabase.rpc('complete_sale', { p: e.payload })
      if (!error) { await del(e.client_id, outboxStore); sent++; continue }
      const pe = parseError(error)
      const network = /fetch|network|Failed to fetch/i.test(pe.kind === 'message' ? pe.message : '')
      if (network) break
      failed++
      await set(e.client_id, { ...e, attempts: e.attempts + 1, error: pe.kind === 'message' ? pe.message : `${pe.kind}: ${pe.perm}` }, outboxStore)
    }
  } finally {
    flushing = false
    await refreshCount()
  }
  return { sent, failed }
}

export async function dropOutboxEntry(clientId: string) { await del(clientId, outboxStore); await refreshCount() }

export function useOutboxCount() {
  useEffect(() => { void refreshCount() }, [])
  return useSyncExternalStore((cb) => { listeners.push(cb); return () => { listeners = listeners.filter((l) => l !== cb) } }, () => outboxCount)
}

export function useOnline() {
  const [online, setOnline] = useState(navigator.onLine)
  useEffect(() => {
    const up = () => { setOnline(true); void flushOutbox() }
    const down = () => setOnline(false)
    window.addEventListener('online', up); window.addEventListener('offline', down)
    const timer = window.setInterval(() => { if (navigator.onLine) void flushOutbox() }, 30_000)
    return () => { window.removeEventListener('online', up); window.removeEventListener('offline', down); clearInterval(timer) }
  }, [])
  return online
}

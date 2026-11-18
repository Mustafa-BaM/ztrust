import { useSyncExternalStore } from 'react'
import type { KitchenTicket, Station } from './types'

/**
 * Connection to the Branch Hub on the shop network. When connected, kitchen tickets travel
 * POS → hub → kitchen screens/printers over Wi-Fi, with or without internet.
 */
export type HubTicket = Omit<KitchenTicket, 'kitchen_ticket_items'> & { items: KitchenTicket['kitchen_ticket_items']; sale_client_id: string | null; synced?: boolean }
interface HubState { status: 'off' | 'connecting' | 'connected' | 'error'; error?: string; cloudOnline?: boolean; pending?: number; tickets: Record<string, HubTicket>; url: string | null; stations?: Station[] }

const KEY_URL = 'zt.hub.url', KEY_CODE = 'zt.hub.code'
const ls = { get: (k: string) => { try { return localStorage.getItem(k) } catch { return null } }, set: (k: string, v: string | null) => { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v) } catch { /* ignore */ } } }

let state: HubState = { status: 'off', tickets: {}, url: null }
let listeners: Array<() => void> = []
let ws: WebSocket | null = null
let retry = 0
let timer: number | undefined
const set = (patch: Partial<HubState>) => { state = { ...state, ...patch }; listeners.forEach((l) => l()) }

export function hubSettings() { return { url: ls.get(KEY_URL), code: ls.get(KEY_CODE) } }

/** If this page is served by a hub, its own origin is the hub. */
export async function detectHub(): Promise<string | null> {
  try {
    const r = await fetch('/api/hub', { cache: 'no-store', signal: AbortSignal.timeout(1500) })
    if (r.ok && (await r.json()).ok) return window.location.origin
  } catch { /* not served by a hub */ }
  return null
}

export function configureHub(url: string | null, code: string | null) {
  ls.set(KEY_URL, url ? url.replace(/\/$/, '') : null); ls.set(KEY_CODE, code)
  disconnect(); if (url && code) connect()
}

export function connect() {
  const { url, code } = hubSettings()
  if (!url || !code) { set({ status: 'off', url: null }); return }
  clearTimeout(timer)
  set({ status: 'connecting', url })
  const sock = new WebSocket(url.replace(/^http/, 'ws') + '/ws')
  ws = sock
  sock.onopen = () => sock.send(JSON.stringify({ type: 'hello', code, role: location.pathname.startsWith('/kds') ? 'kds' : 'pos' }))
  sock.onmessage = (e) => {
    const m = JSON.parse(e.data)
    if (m.type === 'welcome') { retry = 0; set({ status: 'connected', error: undefined, cloudOnline: m.cloud_online, stations: m.stations }) }
    else if (m.type === 'snapshot') set({ tickets: Object.fromEntries((m.tickets as HubTicket[]).map((t) => [t.id, t])) })
    else if (m.type === 'ticket') set({ tickets: { ...state.tickets, [m.ticket.id]: m.ticket } })
    else if (m.type === 'status') set({ cloudOnline: m.cloud_online, pending: m.pending_sync })
    else if (m.type === 'error' && m.error === 'pairing_code') set({ status: 'error', error: 'pairing_code' })
  }
  sock.onclose = () => {
    if (ws !== sock) return
    ws = null
    if (state.status === 'error' && state.error === 'pairing_code') return
    set({ status: 'connecting' })
    timer = window.setTimeout(connect, Math.min(10_000, 1000 * 2 ** retry++))
  }
  sock.onerror = () => { /* onclose handles retry */ }
}

export function disconnect() { clearTimeout(timer); const s = ws; ws = null; s?.close(); set({ status: 'off', tickets: {} }) }

export function hubSend(msg: Record<string, unknown>): boolean {
  if (!ws || ws.readyState !== WebSocket.OPEN || state.status !== 'connected') return false
  ws.send(JSON.stringify(msg)); return true
}

export function useHub() {
  return useSyncExternalStore((cb) => { listeners.push(cb); return () => { listeners = listeners.filter((l) => l !== cb) } }, () => state)
}
export const hubConnected = () => state.status === 'connected'

/** Start automatically: saved settings first, otherwise the hub that served this page (needs the pairing code once). */
export async function startHub() {
  if (hubSettings().url && hubSettings().code) { connect(); return }
  const here = await detectHub()
  if (here) { ls.set(KEY_URL, here); set({ status: hubSettings().code ? 'connecting' : 'error', error: hubSettings().code ? undefined : 'pairing_code', url: here }); if (hubSettings().code) connect() }
}

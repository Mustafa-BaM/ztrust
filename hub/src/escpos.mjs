// Kitchen chit rendering and ESC/POS raster printing.
// Text is drawn to a bitmap first, so Arabic is shaped and joined correctly on any ESC/POS printer
// (printer code pages cannot shape Arabic).
import { createCanvas, GlobalFonts } from '@napi-rs/canvas'
import net from 'node:net'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
GlobalFonts.registerFromPath(path.join(here, '../fonts/PlexArabic-Medium.ttf'), 'ZT')
GlobalFonts.registerFromPath(path.join(here, '../fonts/PlexArabic-Bold.ttf'), 'ZTB')

const AR = /[؀-ۿ]/
const TYPE = { dine_in: 'DINE-IN · محلي', takeaway: 'TAKEAWAY · سفري', delivery: 'DELIVERY · توصيل', pickup: 'PICKUP · استلام' }

/** Wraps text to the printable width. */
function wrap(g, text, max) {
  const words = String(text).split(/\s+/); const lines = []; let cur = ''
  for (const w of words) { const t = cur ? `${cur} ${w}` : w; if (g.measureText(t).width > max && cur) { lines.push(cur); cur = w } else cur = t }
  if (cur) lines.push(cur)
  return lines
}

/** Renders a kitchen ticket to a canvas sized for 58 mm (384 dots) or 80 mm (576 dots) paper. */
export function renderChit(ticket, station, widthMm = 80) {
  const W = widthMm === 58 ? 384 : 576, pad = 12, inner = W - pad * 2
  const draw = (g, measureOnly) => {
    let y = pad
    const text = (s, size, bold, align = 'auto') => {
      g.font = `${size}px ${bold ? 'ZTB' : 'ZT'}`
      const rtl = align === 'auto' ? AR.test(s) : align === 'right'
      for (const line of wrap(g, s, inner)) {
        y += size * 1.25
        if (!measureOnly) {
          g.direction = rtl ? 'rtl' : 'ltr'; g.textAlign = align === 'center' ? 'center' : rtl ? 'right' : 'left'
          g.fillText(line, align === 'center' ? W / 2 : rtl ? W - pad : pad, y - size * 0.25)
        }
      }
    }
    const rule = (dashed) => { y += 10; if (!measureOnly) { g.setLineDash(dashed ? [8, 6] : []); g.lineWidth = 3; g.beginPath(); g.moveTo(pad, y); g.lineTo(W - pad, y); g.stroke() } y += 6 }
    text(station?.name_ar ? `${station.name} · ${station.name_ar}` : station?.name ?? 'Kitchen', 24, true, 'center')
    const ref = String(ticket.order_ref ?? '').startsWith('OFF-') ? String(ticket.order_ref).slice(0, 8) : `#${parseInt(String(ticket.order_ref).split('-').pop() ?? '0', 10)}`
    text(ref, 64, true, 'center')
    text(`${TYPE[ticket.order_type] ?? ticket.order_type}${ticket.table_no ? `  ·  T${ticket.table_no}` : ''}`, 26, true, 'center')
    text(new Date(ticket.created_at ?? Date.now()).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }), 22, false, 'center')
    if (ticket.customer_name) text(ticket.customer_name, 24, false, 'center')
    rule(false)
    for (const it of ticket.items ?? []) {
      const qty = Number(it.qty)
      text(`${qty} × ${it.name_ar || it.name}`, 34, true)
      if (it.name_ar && it.name && it.name !== it.name_ar) text(it.name, 22, false, 'left')
      if (it.note) text(`» ${it.note}`, 28, true)
      y += 6
    }
    if (ticket.note) { rule(true); text(ticket.note, 28, true) }
    rule(false)
    text('Z Trust', 18, false, 'center')
    return y + pad + 40
  }
  const probe = createCanvas(W, 10)
  const H = Math.ceil(draw(probe.getContext('2d'), true))
  const c = createCanvas(W, H), g = c.getContext('2d')
  g.fillStyle = '#fff'; g.fillRect(0, 0, W, H); g.fillStyle = '#000'; g.strokeStyle = '#000'
  draw(g, false)
  return c
}

/** Canvas → ESC/POS bytes: init, raster bit image in bands (GS v 0), feed, partial cut. */
export function toEscPos(canvas) {
  const W = canvas.width, H = canvas.height, bytesPerRow = Math.ceil(W / 8)
  const px = canvas.getContext('2d').getImageData(0, 0, W, H).data
  const parts = [Buffer.from([0x1b, 0x40])]
  for (let top = 0; top < H; top += 240) {
    const rows = Math.min(240, H - top)
    const band = Buffer.alloc(bytesPerRow * rows)
    for (let y = 0; y < rows; y++) for (let x = 0; x < W; x++) {
      const i = ((top + y) * W + x) * 4
      const lum = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2]
      if (lum < 128) band[y * bytesPerRow + (x >> 3)] |= 0x80 >> (x & 7)
    }
    parts.push(Buffer.from([0x1d, 0x76, 0x30, 0x00, bytesPerRow & 0xff, bytesPerRow >> 8, rows & 0xff, rows >> 8]), band)
  }
  parts.push(Buffer.from([0x1b, 0x64, 0x04]), Buffer.from([0x1d, 0x56, 0x42, 0x00]))
  return Buffer.concat(parts)
}

/** Sends raw bytes to a network printer (port 9100 is the ESC/POS default). */
export function sendRaw(ip, port, data, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const s = net.createConnection({ host: ip, port }, () => s.end(data))
    s.setTimeout(timeoutMs, () => { s.destroy(); reject(new Error(`printer ${ip}:${port} timed out`)) })
    s.on('error', reject)
    s.on('close', (hadError) => { if (!hadError) resolve() })
  })
}

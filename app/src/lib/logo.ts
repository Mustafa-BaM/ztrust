/**
 * Shop logo for receipts. Thermal printers print only black dots, so besides the colour logo we keep a
 * black-and-white version made with Floyd–Steinberg dithering at the printer's dot width (576 dots = 80 mm paper),
 * which prints crisply on 58 mm paper too (the browser scales it down by whole dots).
 */
const load = (file: Blob) => new Promise<HTMLImageElement>((resolve, reject) => {
  const url = URL.createObjectURL(file)
  const img = new Image()
  img.onload = () => { URL.revokeObjectURL(url); resolve(img) }
  img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('This file is not an image we can read. Use PNG, JPG, WebP or SVG.')) }
  img.src = url
})

const toBlob = (c: HTMLCanvasElement) => new Promise<Blob>((resolve, reject) => c.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not process the image'))), 'image/png'))

/** Draws the image on white, trimmed to fit maxW × maxH, keeping its proportions. */
function draw(img: HTMLImageElement, maxW: number, maxH: number) {
  const w0 = img.naturalWidth || 512, h0 = img.naturalHeight || 512
  const k = Math.min(maxW / w0, maxH / h0, 1)
  const c = document.createElement('canvas')
  c.width = Math.max(1, Math.round(w0 * k)); c.height = Math.max(1, Math.round(h0 * k))
  const g = c.getContext('2d')!
  g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height)
  g.drawImage(img, 0, 0, c.width, c.height)
  return c
}

/** In-place Floyd–Steinberg to pure black/white on luminance. Exported for tests. */
export function dither(px: Uint8ClampedArray, w: number, h: number) {
  const lum = new Float32Array(w * h)
  for (let i = 0; i < w * h; i++) lum[i] = 0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2]
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = y * w + x, old = lum[i], v = old < 128 ? 0 : 255, e = old - v
    lum[i] = v
    if (x + 1 < w) lum[i + 1] += e * 7 / 16
    if (y + 1 < h) { if (x > 0) lum[i + w - 1] += e * 3 / 16; lum[i + w] += e * 5 / 16; if (x + 1 < w) lum[i + w + 1] += e / 16 }
  }
  for (let i = 0; i < w * h; i++) { const v = lum[i] < 128 ? 0 : 255; px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = v; px[i * 4 + 3] = 255 }
}

export async function prepareLogo(file: File): Promise<{ color: Blob; mono: Blob }> {
  if (file.size > 5 * 1024 * 1024) throw new Error('The logo file is larger than 5 MB.')
  const img = await load(file)
  const color = await toBlob(draw(img, 512, 512))
  const c = draw(img, 576, 240)
  const g = c.getContext('2d')!
  const data = g.getImageData(0, 0, c.width, c.height)
  dither(data.data, c.width, c.height)
  g.putImageData(data, 0, 0)
  return { color, mono: await toBlob(c) }
}

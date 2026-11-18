// The open shift id is remembered per device, branch and user so the POS can keep selling offline.
const key = (branch: string, user: string) => `zt.shift.${branch}.${user}`
export function getShift(branch?: string | null, user?: string | null): string | null {
  if (!branch || !user) return null
  try { return localStorage.getItem(key(branch, user)) } catch { return null }
}
export function setShift(branch: string, user: string, id: string | null) {
  try { if (id) localStorage.setItem(key(branch, user), id); else localStorage.removeItem(key(branch, user)) } catch { /* ignore */ }
}

/** Arabic-aware search normalisation: أ/إ/آ→ا, ة→ه, ى→ي, strip diacritics and tatweel. */
export function norm(s: string): string {
  return s.toLowerCase()
    .replace(/[ً-ْـ]/g, '')
    .replace(/[أإآ]/g, 'ا').replace(/ة/g, 'ه').replace(/ى/g, 'ي')
    .trim()
}

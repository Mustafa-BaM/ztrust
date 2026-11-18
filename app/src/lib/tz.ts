/** Branch-time helpers: the calendar and the booking page show the shop's local time, whatever the device is set to. */
export function partsIn(date: Date, tz: string) {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
  const p = Object.fromEntries(f.formatToParts(date).map((x) => [x.type, x.value]))
  return { date: `${p.year}-${p.month}-${p.day}`, h: Number(p.hour), m: Number(p.minute), hhmm: `${p.hour}:${p.minute}` }
}
/** "2026-11-19" + "09:30" in the shop's zone → the real instant */
export function zoned(date: string, time: string, tz: string): Date {
  const guess = new Date(`${date}T${time}:00Z`)
  const seen = partsIn(guess, tz)
  const diff = (new Date(`${seen.date}T${seen.hhmm}:00Z`).getTime() - guess.getTime())
  return new Date(guess.getTime() - diff)
}
export const todayIn = (tz: string) => partsIn(new Date(), tz).date
export const timeIn = (iso: string, tz: string) => partsIn(new Date(iso), tz).hhmm

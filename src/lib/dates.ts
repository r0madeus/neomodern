// "Date added" like Spotify: recent dates as "4 days ago", older ones as a
// short date ("12 Feb 2026"), in the UI language.

const MINUTE = 60
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR
const WEEK = 7 * DAY
const MONTH = 30 * DAY

/** `seconds` is a unix time in seconds; `now` is for tests. */
export function addedAgo(seconds: number, locale: string, now = Date.now() / 1000): string {
  const diff = Math.max(0, now - seconds)
  const rel = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' })
  if (diff < HOUR) return rel.format(-Math.max(1, Math.floor(diff / MINUTE)), 'minute')
  if (diff < DAY) return rel.format(-Math.floor(diff / HOUR), 'hour')
  if (diff < WEEK) return rel.format(-Math.floor(diff / DAY), 'day')
  if (diff < MONTH) return rel.format(-Math.floor(diff / WEEK), 'week')
  return new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short', year: 'numeric' }).format(
    new Date(seconds * 1000),
  )
}

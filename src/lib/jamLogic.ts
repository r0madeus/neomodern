// Pure helpers of the local Jam UI (docs/JAM.md). No Svelte and no Tauri
// here, so `node --test` can check them (tests/jamLogic.test.ts).

/** Results asked for per `jam_search` page (the host sends at most 30). */
export const JAM_SEARCH_PAGE = 30
/** The host refuses longer queries. */
export const JAM_QUERY_MAX = 100
/** Typing pauses this long before a search is sent (host: ≥ 300 ms apart). */
export const JAM_SEARCH_DEBOUNCE_MS = 300
/** Guest names are shown up to this many characters. */
export const JAM_NAME_MAX = 40

const LINK_PREFIX = 'neomodern://jam?'

/** What a scanned QR code holds, before the backend checks it for real. */
export type ScannedLink = 'jam' | 'pair' | 'other'

/**
 * Sorts a scanned QR code: a Jam link (`neomodern://jam?v=1&c=<6 digits>&a=…`),
 * a phone pairing link (the wrong code for joining a Jam) or anything else.
 * The backend validates the link again (`jam_join_link`).
 */
export function scannedLinkKind(content: string): ScannedLink {
  const s = content.trim()
  if (s.startsWith('neomodern://pair?')) return 'pair'
  if (!s.startsWith(LINK_PREFIX)) return 'other'
  const params = new URLSearchParams(s.slice(LINK_PREFIX.length))
  return /^\d{6}$/.test(params.get('c') ?? '') ? 'jam' : 'other'
}

/** A search query as sent to the host: trimmed and at most 100 characters. */
export function cleanQuery(input: string): string {
  return input.trim().slice(0, JAM_QUERY_MAX)
}

/** A guest's name as shown (the host may send longer ones). */
export function shortName(name: string): string {
  const s = name.trim()
  return s.length > JAM_NAME_MAX ? `${s.slice(0, JAM_NAME_MAX - 1)}…` : s
}

/** "3:05" from milliseconds; an empty string when unknown. */
export function formatDurationMs(ms: number | null | undefined): string {
  if (ms === null || ms === undefined || !Number.isFinite(ms) || ms < 0) return ''
  const s = Math.floor(ms / 1000)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = String(s % 60).padStart(2, '0')
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`
}

/**
 * Puts a page of search results at `offset` into the rows loaded so far.
 * A page that does not follow the loaded rows is dropped (an older answer).
 */
export function mergeResults<T>(rows: readonly T[], offset: number, items: readonly T[]): T[] {
  if (offset === 0) return [...items]
  if (offset !== rows.length) return [...rows]
  return [...rows, ...items]
}

export type JamErrorKind =
  | 'rateLimited'
  | 'queueFull'
  | 'notFound'
  | 'jamEnded'
  | 'removed'
  | 'wrongCode'
  | 'newCode'
  | 'invalidCode'
  | 'noComputer'
  | 'notRunning'
  | 'full'
  | 'disabled'
  | 'unreachable'
  | 'other'

/**
 * Sorts a Jam error from the backend into a kind the UI explains in the
 * user's language. `jam_add` answers with the protocol's codes
 * (`rateLimited`, `queueFull`, `notFound`, `jamEnded`) or an English message.
 */
export function jamErrorKind(message: string): JamErrorKind {
  const m = message.toLowerCase().replace(/[\s_-]+/g, ' ')
  const compact = m.replace(/ /g, '')
  // The new code check comes before "too many" (wrong codes, not adds).
  if (m.includes('new code now') || m.includes('too many attempts')) return 'newCode'
  if (
    compact.includes('ratelimited') ||
    m.includes('not so fast') ||
    m.includes('too many') ||
    m.includes('too fast') ||
    m.includes('slow down')
  )
    return 'rateLimited'
  if (compact.includes('queuefull') || m.includes('queue is full')) return 'queueFull'
  if (m.includes('removed')) return 'removed'
  if (compact.includes('jamended') || m.includes('jam has ended') || m.includes('jam ended')) return 'jamEnded'
  if (compact.includes('notfound') || m.includes('no such') || m.includes('not in the library')) return 'notFound'
  if (m.includes('has 6 digits')) return 'invalidCode'
  if (m.includes('no computer found')) return 'noComputer'
  if (m.includes('wrong') || m.includes('could not prove it knows the code')) return 'wrongCode'
  if (m.includes('no jam') || m.includes('not running') || m.includes('not started')) return 'notRunning'
  if (m.includes('full') || m.includes('guests')) return 'full'
  if (m.includes('turned off') || m.includes('disabled') || m.includes('switch is off') || m.includes('turn on jam'))
    return 'disabled'
  if (
    m.includes('network error') ||
    m.includes('timed out') ||
    m.includes('closed the connection') ||
    m.includes('connection closed') ||
    m.includes('refused') ||
    m.includes('unreachable') ||
    m.includes('not connected')
  )
    return 'unreachable'
  return 'other'
}

/** Translation function shape (`t` from i18n.svelte.ts). */
export type Translate = (en: string, params?: Record<string, string | number>) => string

/** A Jam error (backend message, or the scanner's) in the user's language. */
export function explainJamError(message: string, t: Translate): string {
  if (message === 'pairing qr')
    return t('This is a pairing code. To join a Jam, scan the code in the Jam window on the computer.')
  if (message === 'not a jam qr') return t('This is not a NeoModern Jam code.')
  if (message.toLowerCase().includes('camera'))
    return t('NeoModern needs the camera to scan the code. Allow it in the phone’s settings, or enter the code by hand.')
  switch (jamErrorKind(message)) {
    case 'rateLimited':
      return t('Not so fast: one song every 5 seconds, 20 every 10 minutes.')
    case 'queueFull':
      return t('The queue is full. Try again later.')
    case 'notFound':
      return t('This song is no longer in the library.')
    case 'jamEnded':
      return t('The Jam has ended.')
    case 'removed':
      return t('The host removed you from the Jam.')
    case 'wrongCode':
      return t('Wrong code. Check the Jam code on the computer and try again.')
    case 'newCode':
      return t('Too many wrong codes, so the Jam has a new code. Ask the host for it.')
    case 'invalidCode':
      return t('The Jam code has 6 digits.')
    case 'noComputer':
      return t('No computer found. Type its address.')
    case 'notRunning':
      return t('No Jam is running on that computer.')
    case 'full':
      return t('This Jam is full.')
    case 'disabled':
      return t('Turn on “Join Jams” in Settings › Experimental.')
    case 'unreachable':
      return t('Cannot reach the computer. Check the address and that both devices are on the same Wi-Fi.')
    default:
      return message
  }
}

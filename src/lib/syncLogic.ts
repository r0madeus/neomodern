// Pure helpers of the phone <-> computer sync UI (docs/SYNC.md). No Svelte
// and no Tauri here, so `node --test` can check them (tests/syncLogic.test.ts).

/** Translation function shape (`t` from i18n.svelte.ts). */
export type Translate = (en: string, params?: Record<string, string | number>) => string

export const PAIR_CODE_DIGITS = 6
/** The computer's listening port when none is typed (`link::DEFAULT_PORT`). */
export const DEFAULT_SYNC_PORT = 47321

/** "123456" → "123 456" (easier to read off a screen). */
export function formatPairCode(code: string): string {
  const digits = code.replace(/\D/g, '')
  if (digits.length !== PAIR_CODE_DIGITS) return digits
  return `${digits.slice(0, 3)} ${digits.slice(3)}`
}

/** What the user typed into the code field → at most 6 digits. */
export function normalizePairCode(input: string): string {
  return input.replace(/\D/g, '').slice(0, PAIR_CODE_DIGITS)
}

export type AddressCheck =
  | { ok: true; address: string }
  | { ok: false; reason: 'empty' | 'invalid' | 'notLan' }

function lanV4(parts: number[]): boolean {
  const [a, b] = parts
  return (
    a === 10 ||
    a === 127 ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 169 && b === 254)
  )
}

/**
 * Checks the computer's address typed on the phone: an IPv4 address with an
 * optional `:port`. IPv6 is passed through for the backend to check. Only
 * local network addresses are accepted (the backend refuses the rest too).
 */
export function checkAddress(input: string): AddressCheck {
  // Phones' numeric keyboards often only offer "," next to the digits.
  const s = input.trim().replace(/,/g, '.')
  if (s === '') return { ok: false, reason: 'empty' }
  if ((s.match(/:/g) ?? []).length >= 2) {
    // IPv6 (bare, or "[addr]:port"): the backend decides.
    return /^[\[\]0-9a-fA-F:.%]+$/.test(s) ? { ok: true, address: s } : { ok: false, reason: 'invalid' }
  }
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?::(\d{1,5}))?$/.exec(s)
  if (!m) return { ok: false, reason: 'invalid' }
  const parts = m.slice(1, 5).map(Number)
  if (parts.some((p) => p > 255)) return { ok: false, reason: 'invalid' }
  if (m[5] !== undefined) {
    const port = Number(m[5])
    if (port < 1 || port > 65535) return { ok: false, reason: 'invalid' }
  }
  if (!lanV4(parts)) return { ok: false, reason: 'notLan' }
  return { ok: true, address: s }
}

/** "192.168.1.20" + 47321 → "192.168.1.20:47321". */
export function addressWithPort(ip: string, port: number): string {
  return ip.includes(':') ? `[${ip}]:${port}` : `${ip}:${port}`
}

/**
 * Interpolated playback position between `remote://position` updates (at
 * most 4/s): the last known position plus the time since, while playing,
 * capped at the duration.
 */
export function interpolatePosition(
  anchorSeconds: number,
  anchorAtMs: number,
  nowMs: number,
  playing: boolean,
  duration: number | null,
): number {
  const elapsed = playing ? Math.max(0, (nowMs - anchorAtMs) / 1000) : 0
  const max = duration !== null && duration > 0 ? duration : Infinity
  return Math.max(0, Math.min(anchorSeconds + elapsed, max))
}

export type RepeatMode = 'off' | 'all' | 'one'

/** The repeat button cycles off → all → one → off. */
export function nextRepeat(mode: RepeatMode): RepeatMode {
  return mode === 'off' ? 'all' : mode === 'all' ? 'one' : 'off'
}

/** Seconds left of a pairing code shown as "1:45". */
export function formatCountdown(seconds: number): string {
  const s = Math.max(0, Math.ceil(seconds))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export interface SongLoss {
  name: string
  removed: number
  total: number
}

/** What a sync stopped by the mass-delete guard would remove here. */
export interface GuardSummary {
  favoritesTurnedOff: number
  localFavorites: number
  playlistsDeleted: number
  playlistNames: string[]
  songsRemoved: SongLoss[]
}

/** The guard question as short lines, already translated. */
export function guardLines(g: GuardSummary, t: Translate): string[] {
  const lines: string[] = []
  if (g.favoritesTurnedOff > 0) {
    lines.push(
      t('Remove {n} of your {m} favorites', { n: g.favoritesTurnedOff, m: g.localFavorites }),
    )
  }
  if (g.playlistsDeleted > 0) {
    const names = g.playlistNames.map((n) => `“${n}”`).join(', ')
    const more = g.playlistsDeleted - g.playlistNames.length
    let line =
      g.playlistsDeleted === 1
        ? t('Delete the playlist {names}', { names })
        : t('Delete {n} playlists: {names}', { n: g.playlistsDeleted, names })
    if (more > 0) line += ` ${t('and {n} more', { n: more })}`
    lines.push(line)
  }
  for (const loss of g.songsRemoved) {
    lines.push(
      t('Remove {n} of {m} songs from “{name}”', { n: loss.removed, m: loss.total, name: loss.name }),
    )
  }
  return lines
}

export type PairErrorKind =
  | 'wrongCode'
  | 'tooManyAttempts'
  | 'expired'
  | 'notOpen'
  | 'busy'
  | 'unreachable'
  | 'version'
  | 'address'
  | 'notPairingQr'
  | 'qrNoAddress'
  | 'camera'
  | 'other'

/** Sorts a pairing error from the backend (its English message) into a kind
 *  the UI explains in the user's language. */
export function pairErrorKind(message: string): PairErrorKind {
  const m = message.toLowerCase()
  // The pairing QR code (K23).
  if (m.includes('not a neomodern pairing code')) return 'notPairingQr'
  if (m.includes('no local network address of the computer')) return 'qrNoAddress'
  if (m.includes('camera')) return 'camera'
  if (m.includes('too many attempts')) return 'tooManyAttempts'
  if (m.includes('wrong pairing code') || m.includes('could not prove it knows the code'))
    return 'wrongCode'
  if (m.includes('expired')) return 'expired'
  if (m.includes('pairing is not open')) return 'notOpen'
  if (m.includes('another device is pairing')) return 'busy'
  if (m.includes('version')) return 'version'
  if (m.includes("computer's address") || m.includes('local network')) return 'address'
  if (
    m.includes('network error') ||
    m.includes('timed out') ||
    m.includes('closed the connection') ||
    m.includes('refused') ||
    m.includes('unreachable')
  )
    return 'unreachable'
  return 'other'
}

export type RemoteErrorKind = 'staleQueue' | 'rateLimited' | 'notConnected' | 'noAnswer' | 'other'

/** Sorts a refused remote command (backend message) into a kind. */
export function remoteErrorKind(message: string): RemoteErrorKind {
  const m = message.toLowerCase()
  if (m.includes('queue changed')) return 'staleQueue'
  if (m.includes('too many commands')) return 'rateLimited'
  if (m.includes('not connected') || m.includes('no device is connected')) return 'notConnected'
  if (m.includes('did not answer') || m.includes('connection closed')) return 'noAnswer'
  return 'other'
}

/**
 * Calls `send` at most once per `intervalMs` while values keep coming (a
 * dragged slider), always ending with the last value.
 */
export function throttleLatest<T>(
  send: (value: T) => void,
  intervalMs: number,
  now: () => number = () => Date.now(),
): { push: (value: T) => void; flush: () => void; cancel: () => void } {
  let last = -Infinity
  let pending: { value: T } | null = null
  let timer: ReturnType<typeof setTimeout> | null = null

  const fire = () => {
    timer = null
    if (!pending) return
    const { value } = pending
    pending = null
    last = now()
    send(value)
  }
  return {
    push(value) {
      pending = { value }
      if (timer) return
      const wait = last + intervalMs - now()
      if (wait <= 0) fire()
      else timer = setTimeout(fire, wait)
    },
    flush() {
      if (timer) clearTimeout(timer)
      fire()
    },
    cancel() {
      if (timer) clearTimeout(timer)
      timer = null
      pending = null
    },
  }
}

/** A computer the phone found on the network (`sync_discover`). */
export interface FoundComputer {
  deviceId: string
  name: string
  /** `ip:port`, ready to pair with. */
  address: string
}

/** The pairing rows the phone shows for its active profile (K25): one
 *  computer per phone profile. */
export function computerFor<P extends { kind: string; profileId: number }>(
  peers: readonly P[],
  activeProfile: number | null,
): P | null {
  if (activeProfile === null) return null
  return peers.find((p) => p.kind === 'computer' && p.profileId === activeProfile) ?? null
}

/** What the "Find computers" list shows. */
export type DiscoveryView = 'searching' | 'found' | 'none' | 'idle'

export function discoveryView(searching: boolean, searched: boolean, found: readonly FoundComputer[]): DiscoveryView {
  if (searching) return 'searching'
  if (found.length > 0) return 'found'
  return searched ? 'none' : 'idle'
}

/** Keeps well-formed answers of the backend, one per device id, by name. */
export function cleanFound(list: readonly FoundComputer[]): FoundComputer[] {
  const seen = new Set<string>()
  const out: FoundComputer[] = []
  for (const f of list) {
    if (seen.has(f.deviceId) || !checkAddress(f.address).ok) continue
    seen.add(f.deviceId)
    out.push(f)
  }
  return out.sort((a, b) => a.name.localeCompare(b.name))
}

// Phone <-> computer sync and remote control on the UI side (docs/SYNC.md).
// Rust owns the state (AGENTS.md rule 1): this store mirrors it from the
// `sync://status` and `remote://*` events and sends commands. Failed
// commands land in `error` / `remoteError`, shown inline by the views.
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import type { FoundComputer, GuardSummary, RepeatMode } from './syncLogic'
import { scanQrCode } from './qrScan'
import { cleanFound, computerFor, interpolatePosition, remoteErrorKind, throttleLatest } from './syncLogic'

export interface SyncResult {
  peerId: string
  peerName: string
  /** Unix milliseconds. */
  finishedAt: number
  sent: number
  received: number
  changed: number
  error: string | null
}

export interface PeerStatus {
  id: string
  name: string
  /** `computer`: this phone dials it; `phone`: it dials this computer. */
  kind: 'computer' | 'phone'
  address: string | null
  connected: boolean
  syncing: boolean
  /** Unix milliseconds. */
  lastSyncAt: number | null
  /** The local profile this pairing syncs (K24). */
  profileName: string
  /** Its id: the phone shows the pairing of its active profile (K25). */
  profileId: number
  lastError: string | null
  pendingGuard: GuardSummary | null
  lastResult: SyncResult | null
  rounds: number
}

export type PairingState = 'closed' | 'open' | 'expired' | 'tooManyAttempts'

export interface SyncStatus {
  role: 'desktop' | 'phone'
  deviceId: string
  deviceName: string
  /** The library's active profile. */
  activeProfile: number
  allowPhoneConnections: boolean
  listening: { port: number; addresses: string[] } | null
  pairing: { state: PairingState; code: string | null; remainingSecs: number | null; profileName: string | null }
  peers: PeerStatus[]
  lastResult: SyncResult | null
}

/** A QR code to draw: `size`×`size` modules, row by row, '1' = dark. */
export interface PairQr {
  link: string
  size: number
  modules: string
}

export interface PairingOpen {
  code: string
  addresses: string[]
  port: number
  remainingSecs: number
  /** The local profile a phone paired with this code will sync with. */
  profileName: string
  /** The same code as a QR code with the addresses (K23). */
  qr: PairQr | null
}

export type RemoteStatus = 'playing' | 'paused' | 'stopped'

export interface RemoteTrack {
  title: string
  artist: string
  album: string
  duration: number | null
  key: string
}

export interface RemoteState {
  status: RemoteStatus
  current: RemoteTrack | null
  currentIndex: number | null
  queueLength: number
  queueVersion: number
  volume: number
  shuffle: boolean
  repeat: RepeatMode
  position: number
}

export interface QueueEntry {
  index: number
  title: string
  artist: string
  key: string
}

export interface QueuePage {
  offset: number
  total: number
  queueVersion: number
  entries: QueueEntry[]
}

/** `RemoteCmd` (src-tauri/src/sync/remote.rs), tagged by `kind`. */
export type RemoteCmd =
  | { kind: 'togglePause' | 'play' | 'pause' | 'next' | 'previous' }
  | { kind: 'seek'; seconds: number }
  | { kind: 'setVolume'; percent: number }
  | { kind: 'setShuffle'; on: boolean }
  | { kind: 'setRepeat'; mode: RepeatMode }
  | { kind: 'playIndex'; index: number; queueVersion: number }

/** The settings actions that can fail; `error.action` says which. */
export type SyncAction =
  | 'load'
  | 'allow'
  | 'name'
  | 'pair'
  | 'connect'
  | 'syncNow'
  | 'forget'
  | 'discover'
  | 'remove'
  | 'guard'

export const QUEUE_PAGE = 50
/** Volume changes sent at most this often while the slider moves (≤ 5/s). */
const VOLUME_INTERVAL_MS = 200

class SyncStore {
  status = $state<SyncStatus | null>(null)
  /** The last code from "Pair a phone" (with addresses and port). */
  pairing = $state<PairingOpen | null>(null)
  /** `performance.now()` when the shown code runs out. */
  pairDeadline = $state(0)
  busy = $state<SyncAction | null>(null)
  error = $state<{ action: SyncAction; message: string; peerId?: string } | null>(null)

  remote = $state<RemoteState | null>(null)
  remoteError = $state<string | null>(null)
  /** Remote queue rows loaded so far (`QUEUE_PAGE` at a time), from
   *  `queueStart` (the song playing when the list was loaded) on. */
  queue = $state<QueueEntry[]>([])
  queueStart = $state(0)
  queueTotal = $state(0)
  queueVersion = $state(-1)
  queueLoading = $state(false)

  #anchor = $state({ seconds: 0, at: 0 })
  #durationOverride = $state<number | null>(null)
  #started = false
  #openRemote: (() => void) | null = null

  /** Computers found on the network by the last search (phone). */
  found = $state<FoundComputer[]>([])
  searching = $state(false)
  /** A search has finished since the app started (so "none found" is true). */
  searched = $state(false)

  /** The computer the active profile is paired with (role phone), if any.
   *  Each phone profile has its own pairing (K25). */
  computer = $derived(computerFor(this.status?.peers ?? [], this.status?.activeProfile ?? null))
  /** The phones paired with this computer (role desktop). */
  phones = $derived(this.status?.peers.filter((p) => p.kind === 'phone') ?? [])
  duration = $derived(this.#durationOverride ?? this.remote?.current?.duration ?? null)

  async init(): Promise<void> {
    if (this.#started) return
    this.#started = true
    try {
      await listen<SyncStatus>('sync://status', (e) => this.#applyStatus(e.payload))
      await listen<RemoteState | null>('remote://state', (e) => this.#applyRemote(e.payload))
      await listen<{ seconds: number; duration: number | null }>('remote://position', (e) => {
        this.#setAnchor(e.payload.seconds)
        if (e.payload.duration !== null) this.#durationOverride = e.payload.duration
      })
      await listen<QueuePage>('remote://queue', (e) => this.#mergePage(e.payload))
      this.#applyStatus(await invoke<SyncStatus>('sync_status'))
    } catch (e) {
      this.error = { action: 'load', message: String(e) }
    }
    await this.refreshRemote()
  }

  /** The interpolated remote position at `nowMs` (`performance.now()`). */
  positionAt(nowMs: number): number {
    return interpolatePosition(
      this.#anchor.seconds,
      this.#anchor.at,
      nowMs,
      this.remote?.status === 'playing',
      this.duration,
    )
  }

  // Settings actions --------------------------------------------------------

  setAllowPhones = (enabled: boolean) =>
    this.#status('allow', 'sync_set_allow_phone_connections', { enabled }).then((ok) => {
      if (ok && !enabled) this.pairing = null
    })
  setDeviceName = (name: string) => this.#status('name', 'sync_set_device_name', { name })
  pairOpen = async (): Promise<void> => {
    await this.#act('pair', async () => {
      const open = await invoke<PairingOpen>('sync_pair_open')
      this.pairing = open
      this.pairDeadline = performance.now() + open.remainingSecs * 1000
    })
  }
  pairClose = () =>
    this.#status('pair', 'sync_pair_close').then(() => {
      this.pairing = null
    })
  removePeer = (peerId: string) => this.#status('remove', 'sync_remove_peer', { peerId }, peerId)
  /** Phone: pairs with the computer; true when it worked. */
  connectPair = (address: string, code: string) =>
    this.#status('connect', 'sync_connect_pair', { address, code })
  /** Phone: scans the computer's pairing QR code and pairs (K23); true
   *  when it worked. The camera is only used while the scanner is open. */
  scanPair = async (): Promise<boolean> => {
    const scanned = await scanQrCode()
    if (!scanned.ok) {
      if (scanned.error) this.error = { action: 'connect', message: scanned.error }
      return false
    }
    const link = scanned.content
    return this.#status('connect', 'sync_connect_pair_link', { link })
  }
  /** Phone: looks for computers on the Wi-Fi (about 1.5 s). */
  discover = async (): Promise<void> => {
    if (this.searching) return
    this.searching = true
    if (this.error?.action === 'discover') this.error = null
    try {
      this.found = cleanFound(await invoke<FoundComputer[]>('sync_discover'))
    } catch (e) {
      this.found = []
      this.error = { action: 'discover', message: String(e) }
    } finally {
      this.searching = false
      this.searched = true
    }
  }
  syncNow = () => this.#status('syncNow', 'sync_now')
  forget = () =>
    this.#status('forget', 'sync_forget').then((ok) => {
      if (ok) this.#applyRemote(null)
      return ok
    })
  guardDecide = (peerId: string, apply: boolean) =>
    this.#status('guard', 'sync_guard_decide', { peerId, apply }, peerId)

  // Remote control ------------------------------------------------------------

  /** MobileApp registers how the remote screen opens (a layer). */
  registerRemoteOpener(open: () => void): void {
    this.#openRemote = open
  }
  openRemote = () => this.#openRemote?.()

  async refreshRemote(): Promise<void> {
    if (this.status?.role !== 'phone') return
    try {
      this.#applyRemote(await invoke<RemoteState | null>('remote_state'))
    } catch {
      // not connected: the events bring the state when it is
    }
  }

  /** Sends one remote command; false (and `remoteError`) when refused. */
  send = async (cmd: RemoteCmd): Promise<boolean> => {
    try {
      await invoke('remote_send', { cmd })
      this.remoteError = null
      return true
    } catch (e) {
      const message = String(e)
      this.remoteError = message
      if (remoteErrorKind(message) === 'staleQueue') void this.loadQueue(true)
      return false
    }
  }

  seek = (seconds: number) => {
    this.#setAnchor(seconds)
    return this.send({ kind: 'seek', seconds })
  }

  #volume = throttleLatest((percent: number) => void this.send({ kind: 'setVolume', percent }), VOLUME_INTERVAL_MS)
  /** Volume slider moved: shown at once, sent at most 5 times a second. */
  setVolume = (percent: number) => {
    const p = Math.max(0, Math.min(100, Math.round(percent)))
    if (this.remote) this.remote.volume = p
    this.#volume.push(p)
  }
  /** Slider released: send the last value now. */
  commitVolume = () => this.#volume.flush()

  playIndex = (index: number) => {
    const queueVersion = this.queueVersion >= 0 ? this.queueVersion : (this.remote?.queueVersion ?? 0)
    return this.send({ kind: 'playIndex', index, queueVersion })
  }

  /** Whether more remote queue rows can be loaded. */
  get queueHasMore(): boolean {
    return this.queueVersion >= 0 && this.queueStart + this.queue.length < this.queueTotal
  }

  /** Loads the next page of the computer's "Next up" list (the songs after
   *  the current one, in play order with shuffle applied), or (`reset`) the
   *  first page. Offsets count from the next song. */
  async loadQueue(reset = false): Promise<void> {
    if (this.queueLoading && !reset) return
    const offset = reset ? 0 : this.queueStart + this.queue.length
    if (!reset && !this.queueHasMore) return
    this.queueLoading = true
    try {
      const page = await invoke<QueuePage>('remote_queue_page', { offset, limit: QUEUE_PAGE })
      if (reset) {
        this.queue = []
        this.queueVersion = -1
        this.queueStart = offset
      }
      this.#mergePage(page)
    } catch (e) {
      this.remoteError = String(e)
    } finally {
      this.queueLoading = false
    }
  }

  /** The phone's own cover file for a song key, if it has the song. */
  async coverForKey(key: string): Promise<string | null> {
    if (!key) return null
    try {
      return await invoke<string | null>('sync_cover_for_key', { key })
    } catch {
      return null
    }
  }

  // Internals -------------------------------------------------------------------

  async #act(action: SyncAction, run: () => Promise<void>, peerId?: string): Promise<boolean> {
    this.busy = action
    if (this.error?.action === action || this.error?.action === 'load') this.error = null
    try {
      await run()
      return true
    } catch (e) {
      this.error = { action, message: String(e), peerId }
      return false
    } finally {
      if (this.busy === action) this.busy = null
    }
  }

  #status(action: SyncAction, command: string, args?: Record<string, unknown>, peerId?: string) {
    return this.#act(
      action,
      async () => this.#applyStatus(await invoke<SyncStatus>(command, args)),
      peerId,
    )
  }

  #applyStatus(next: SyncStatus): void {
    this.status = next
    const p = next.pairing
    if (p.state === 'open' && p.remainingSecs !== null) {
      this.pairDeadline = performance.now() + p.remainingSecs * 1000
      if (this.pairing && p.code && this.pairing.code !== p.code) {
        this.pairing = { ...this.pairing, code: p.code, remainingSecs: p.remainingSecs }
      }
    } else if (p.state === 'closed') {
      // Closed elsewhere (or a phone paired): hide the code.
      this.pairing = null
    }
    // A lost connection clears `remote` through `remote://state` (null); the
    // remote screen also hides it while the computer is not connected.
  }

  #applyRemote(next: RemoteState | null): void {
    const prev = this.remote
    const prevKey = prev?.current?.key
    this.remote = next
    if (!next) {
      this.queue = []
      this.queueStart = 0
      this.queueTotal = 0
      this.queueVersion = -1
      return
    }
    if (next.current?.key !== prevKey) this.#durationOverride = null
    this.#setAnchor(next.position)
    // "Next up" depends on the queue, the current song and shuffle.
    if (
      this.queueVersion >= 0 &&
      (next.queueVersion !== this.queueVersion ||
        next.currentIndex !== prev?.currentIndex ||
        next.shuffle !== prev?.shuffle)
    ) {
      void this.loadQueue(true)
    }
  }

  #mergePage(page: QueuePage): void {
    if (page.queueVersion !== this.queueVersion) {
      // A new queue: start over from this page when it is the first one.
      if (page.offset !== this.queueStart) return
      this.queue = []
      this.queueVersion = page.queueVersion
    }
    this.queueTotal = page.total
    const at = page.offset - this.queueStart
    if (at < 0 || at > this.queue.length) return // not next to the loaded rows
    this.queue = [...this.queue.slice(0, at), ...page.entries, ...this.queue.slice(at + page.entries.length)]
  }

  #setAnchor(seconds: number): void {
    this.#anchor = { seconds, at: performance.now() }
  }
}

export const sync = new SyncStore()

// Local Jam on the UI side (docs/JAM.md, decision K27). Rust owns the state
// (AGENTS.md rule 1): this store mirrors it from the `jam://status`,
// `jam://guest` and `jam://state` events and sends commands. Failed commands
// land in `error` (and `addError` for adding a song), shown by the views.
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import type { PairQr } from './sync.svelte'
import { scanQrCode } from './qrScan'
import { cleanQuery, JAM_SEARCH_DEBOUNCE_MS, JAM_SEARCH_PAGE, mergeResults, scannedLinkKind } from './jamLogic'

export interface JamGuest {
  id: string
  name: string
  /** Songs this guest added. */
  added: number
  /** Its phone is connected right now (sent by the backend; optional in docs/JAM.md). */
  connected?: boolean
}

export interface JamRecentAdd {
  title: string
  artist: string
  addedBy: string
}

/** The host's Jam (desktop). */
export interface JamStatus {
  enabled: boolean
  running: boolean
  code?: string | null
  /** `neomodern://jam?v=1&c=<code>&a=<ip:port,...>` */
  link?: string | null
  /** The link as a QR code, when the backend sends one (as for pairing). */
  qr?: PairQr | null
  /** `ip:port` the guests can reach. */
  addresses: string[]
  guests: JamGuest[]
  recent: JamRecentAdd[]
}

/** This phone as a Jam guest. */
export interface JamGuestStatus {
  enabled: boolean
  joined: boolean
  hostName?: string | null
  connecting: boolean
  error?: string | null
}

export interface JamTrack {
  title: string
  artist: string
  durationMs: number | null
}

export interface JamUpNextEntry extends JamTrack {
  addedBy?: string | null
}

/** What the host plays (`jamState`, pushed by the host on every change). */
export interface JamState {
  hostName: string
  nowPlaying?: JamTrack | null
  playing: boolean
  upNext: JamUpNextEntry[]
}

export interface JamSearchItem {
  trackId: number
  title: string
  artist: string
  album: string
  durationMs: number | null
}

export interface JamSearchPage {
  total: number
  items: JamSearchItem[]
}

export type JamAction = 'load' | 'enable' | 'start' | 'end' | 'newCode' | 'remove' | 'join' | 'leave' | 'search'

class JamStore {
  /** Desktop (host). */
  status = $state<JamStatus | null>(null)
  /** Phone (guest). */
  guest = $state<JamGuestStatus | null>(null)
  state = $state<JamState | null>(null)

  busy = $state<JamAction | null>(null)
  error = $state<{ action: JamAction; message: string; id?: string } | null>(null)
  /** The host's Jam window (desktop). */
  dialogOpen = $state(false)

  // Guest search: the host's library, paged.
  query = $state('')
  results = $state<JamSearchItem[]>([])
  total = $state(0)
  searching = $state(false)
  /** Songs being sent (`jam_add`), and the ones the host took. */
  adding = $state<ReadonlySet<number>>(new Set())
  added = $state<ReadonlySet<number>>(new Set())
  addError = $state<string | null>(null)

  #role: 'desktop' | 'phone' | null = null
  #openScreen: (() => void) | null = null
  #listening = false
  #searchTimer: ReturnType<typeof setTimeout> | null = null
  #searchSeq = 0

  /** The host switch is on (desktop). */
  hostEnabled = $derived(this.status?.enabled === true)
  /** The guest switch is on (phone). */
  guestEnabled = $derived(this.guest?.enabled === true)
  joined = $derived(this.guest?.joined === true)
  hasMore = $derived(this.results.length < this.total)

  /** Loads the Jam of this device's role; called again when the role is known. */
  async init(role: 'desktop' | 'phone'): Promise<void> {
    if (this.#role === role) return
    this.#role = role
    try {
      if (!this.#listening) {
        this.#listening = true
        await listen<JamStatus>('jam://status', (e) => this.#applyStatus(e.payload))
        await listen<JamGuestStatus>('jam://guest', (e) => this.#applyGuest(e.payload))
        await listen<JamState | null>('jam://state', (e) => (this.state = e.payload))
      }
      if (role === 'desktop') this.#applyStatus(await invoke<JamStatus>('jam_status'))
      else this.#applyGuest(await invoke<JamGuestStatus>('jam_guest_status'))
    } catch (e) {
      this.error = { action: 'load', message: String(e) }
    }
  }

  // Host (desktop) ---------------------------------------------------------------

  setEnabled = (enabled: boolean) =>
    this.#host('enable', 'jam_set_enabled', { enabled }).then((ok) => {
      if (ok && !enabled) this.dialogOpen = false
      return ok
    })
  /** Starts the Jam (or shows the running one) and opens its window. */
  start = async (): Promise<boolean> => {
    this.dialogOpen = true
    if (this.status?.running) return true
    return this.#host('start', 'jam_start')
  }
  end = () =>
    this.#host('end', 'jam_end').then((ok) => {
      if (ok) this.dialogOpen = false
      return ok
    })
  newCode = () => this.#host('newCode', 'jam_new_code')
  removeGuest = (id: string) => this.#host('remove', 'jam_remove_guest', { id }, id)

  // Guest (phone) --------------------------------------------------------------------

  /** MobileApp registers how the Jam screen opens (a layer). */
  registerScreenOpener(open: () => void): void {
    this.#openScreen = open
  }
  openScreen = () => this.#openScreen?.()

  setGuestEnabled = async (enabled: boolean): Promise<boolean> =>
    this.#act('enable', async () => {
      const next = await invoke<JamGuestStatus | null>('jam_guest_set_enabled', { enabled })
      this.#applyGuest(next ?? (await invoke<JamGuestStatus>('jam_guest_status')))
    })
  /** Joins with a typed code (and the host's address, if one is known). */
  join = (address: string | null, code: string) => this.#guestCmd('join', 'jam_join', { address, code })
  /** Scans the host's Jam QR code and joins; true when it worked. */
  scanJoin = async (): Promise<boolean> => {
    const scanned = await scanQrCode()
    if (!scanned.ok) {
      if (scanned.error) this.error = { action: 'join', message: scanned.error }
      return false
    }
    const kind = scannedLinkKind(scanned.content)
    if (kind !== 'jam') {
      this.error = { action: 'join', message: kind === 'pair' ? 'pairing qr' : 'not a jam qr' }
      return false
    }
    return this.#guestCmd('join', 'jam_join_link', { link: scanned.content.trim() })
  }
  leave = () =>
    this.#act('leave', async () => {
      const next = await invoke<JamGuestStatus | null>('jam_leave')
      this.#applyGuest(next ?? (await invoke<JamGuestStatus>('jam_guest_status')))
    })

  /** The search box changed: searches after a short pause. */
  setQuery = (input: string) => {
    this.query = input
    if (this.#searchTimer) clearTimeout(this.#searchTimer)
    const q = cleanQuery(input)
    if (q === '') {
      this.#searchSeq++
      this.results = []
      this.total = 0
      this.searching = false
      return
    }
    this.searching = true
    this.#searchTimer = setTimeout(() => void this.#search(q, 0), JAM_SEARCH_DEBOUNCE_MS)
  }
  loadMore = () => {
    const q = cleanQuery(this.query)
    if (q === '' || this.searching || !this.hasMore) return
    this.searching = true
    void this.#search(q, this.results.length)
  }

  /** Adds a song to the end of the host's queue; false (and `addError`) when refused. */
  add = async (trackId: number): Promise<boolean> => {
    if (this.adding.has(trackId)) return false
    this.adding = new Set([...this.adding, trackId])
    try {
      await invoke('jam_add', { trackId })
      this.added = new Set([...this.added, trackId])
      this.addError = null
      return true
    } catch (e) {
      this.addError = String(e)
      return false
    } finally {
      const next = new Set(this.adding)
      next.delete(trackId)
      this.adding = next
    }
  }

  // Internals --------------------------------------------------------------------------

  async #search(query: string, offset: number): Promise<void> {
    const seq = ++this.#searchSeq
    if (this.error?.action === 'search') this.error = null
    try {
      const page = await invoke<JamSearchPage>('jam_search', { query, offset, limit: JAM_SEARCH_PAGE })
      if (seq !== this.#searchSeq) return
      this.results = mergeResults(this.results, offset, page.items)
      this.total = page.total
    } catch (e) {
      if (seq !== this.#searchSeq) return
      this.error = { action: 'search', message: String(e) }
    } finally {
      if (seq === this.#searchSeq) this.searching = false
    }
  }

  async #act(action: JamAction, run: () => Promise<void>, id?: string): Promise<boolean> {
    this.busy = action
    if (this.error?.action === action || this.error?.action === 'load') this.error = null
    try {
      await run()
      return true
    } catch (e) {
      this.error = { action, message: String(e), id }
      return false
    } finally {
      if (this.busy === action) this.busy = null
    }
  }

  #host(action: JamAction, command: string, args?: Record<string, unknown>, id?: string) {
    return this.#act(action, async () => this.#applyStatus(await invoke<JamStatus>(command, args)), id)
  }

  #guestCmd(action: JamAction, command: string, args: Record<string, unknown>) {
    return this.#act(action, async () => {
      const next = await invoke<JamGuestStatus>(command, args)
      this.#applyGuest(next)
      if (!next.joined && !next.connecting && next.error) throw next.error
    })
  }

  #applyStatus(next: JamStatus): void {
    this.status = next
    if (!next.enabled) this.dialogOpen = false
  }

  #applyGuest(next: JamGuestStatus): void {
    const wasJoined = this.guest?.joined === true
    this.guest = next
    if (!next.joined) {
      this.state = null
      if (wasJoined) this.#resetSearch()
    }
  }

  #resetSearch(): void {
    if (this.#searchTimer) clearTimeout(this.#searchTimer)
    this.#searchSeq++
    this.query = ''
    this.results = []
    this.total = 0
    this.searching = false
    this.added = new Set()
    this.addError = null
  }
}

export const jam = new JamStore()

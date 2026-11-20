// Player state on the UI side. Rust owns the real state (AGENTS.md rule 1);
// this module only mirrors it from `player://state` / `player://position`
// events and sends commands back.
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'

export type Status = 'playing' | 'paused' | 'stopped'
export type RepeatMode = 'off' | 'all' | 'one'
export type ReplayGain = 'off' | 'track' | 'album'

export interface TrackInfo {
  id: number
  path: string
  title: string
  /** Empty when unknown (files opened directly, untagged files). */
  artist: string
  /** Added with "Add to queue". */
  queued?: boolean
}

export interface PlayerSnapshot {
  status: Status
  currentIndex: number | null
  current: TrackInfo | null
  queueLength: number
  queueVersion: number
  positionSeconds: number
  durationSeconds: number | null
  volume: number
  shuffle: boolean
  repeat: RepeatMode
  replaygain: ReplayGain
  gapless: boolean
  wasapiExclusive: boolean
  equalizer: Equalizer
  /** Crossfade length in seconds; 0 = off. */
  crossfadeSeconds: number
  /** Sleep timer end (unix ms) when set to a time. */
  sleepEndsAt: number | null
  /** Sleep timer set to the end of the current track. */
  sleepEndOfTrack: boolean
  /** What previous / next would play (shuffle and repeat applied). */
  previousTrack: TrackInfo | null
  nextTrack: TrackInfo | null
  /** What the queue was started from: 'album:3', 'playlist:7', 'favorites'. */
  context: string | null
}

/** Ten octave bands, 31 Hz to 16 kHz; values in dB (±12). */
export interface Equalizer {
  enabled: boolean
  preampDb: number
  gainsDb: number[]
}

export const EQ_BANDS = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
export const EQ_MAX_DB = 12
export const MAX_CROSSFADE_SECONDS = 12

interface PositionPayload {
  seconds: number
  duration: number | null
}

const EMPTY: PlayerSnapshot = {
  status: 'stopped',
  currentIndex: null,
  current: null,
  queueLength: 0,
  queueVersion: 0,
  positionSeconds: 0,
  durationSeconds: null,
  volume: 100,
  shuffle: false,
  repeat: 'off',
  replaygain: 'album',
  gapless: true,
  wasapiExclusive: false,
  equalizer: { enabled: false, preampDb: 0, gainsDb: Array(10).fill(0) },
  crossfadeSeconds: 0,
  sleepEndsAt: null,
  sleepEndOfTrack: false,
  previousTrack: null,
  nextTrack: null,
  context: null,
}

/** Queue rows are fetched in pages; never the whole list in one IPC call. */
const PAGE_SIZE = 500

class PlayerStore {
  snapshot = $state<PlayerSnapshot>(EMPTY)
  queue = $state<TrackInfo[]>([])
  error = $state<string | null>(null)

  // Position arrives a few times per second; in between we interpolate
  // from the last update so the seek bar moves smoothly (rule 5).
  #anchor = $state({ seconds: 0, at: 0 })
  #now = $state(0)
  #frame = 0
  #loadedQueueVersion = -1
  #unmutedVolume = 100
  #visibilityBound = false

  position = $derived.by(() => {
    const { seconds, at } = this.#anchor
    const elapsed = this.snapshot.status === 'playing' ? (this.#now - at) / 1000 : 0
    const duration = this.snapshot.durationSeconds ?? Infinity
    return Math.max(0, Math.min(seconds + Math.max(0, elapsed), duration))
  })

  async init(): Promise<void> {
    await listen<PlayerSnapshot>('player://state', (e) => this.#apply(e.payload))
    await listen<string>('player://error', (e) => (this.error = e.payload))
    await listen<PositionPayload>('player://position', (e) => {
      this.#setAnchor(e.payload.seconds)
      if (e.payload.duration !== null) this.snapshot.durationSeconds = e.payload.duration
    })
    if (typeof document !== 'undefined' && !this.#visibilityBound) {
      this.#visibilityBound = true
      document.addEventListener('visibilitychange', () => {
        // While hidden the webview freezes the page; the backend stops sending
        // position updates so they do not pile up (src-tauri/src/ui.rs).
        void invoke('app_set_visible', { visible: document.visibilityState !== 'hidden' }).catch(() => {})
        if (document.visibilityState === 'hidden') {
          cancelAnimationFrame(this.#frame)
          this.#frame = 0
        } else if (document.visibilityState === 'visible' && this.snapshot.status === 'playing') {
          const elapsed = Math.max(0, (performance.now() - this.#anchor.at) / 1000)
          const duration = this.snapshot.durationSeconds ?? Infinity
          this.#setAnchor(Math.max(0, Math.min(this.#anchor.seconds + elapsed, duration)))
          this.#startClock()
        }
      })
    }
    await this.#run('player_snapshot')
  }

  /** Apply a snapshot returned by a command issued outside this store (e.g. library play). */
  applySnapshot = (snapshot: PlayerSnapshot) => {
    this.#apply(snapshot)
    this.error = null
  }
  playWithShuffle = async (snapshot: PlayerSnapshot, shuffle?: boolean): Promise<void> => {
    this.applySnapshot(snapshot)
    if (shuffle !== undefined && snapshot.shuffle !== shuffle) {
      await this.setShuffle(shuffle)
    }
  }
  openFiles = (paths: string[]) => this.#run('queue_replace', { paths, startIndex: 0 })
  appendFiles = (paths: string[]) => this.#run('queue_append', { paths })
  /** Spotify's "Add to queue": after earlier adds, before the rest. */
  addToQueue = (paths: string[]) => this.#run('queue_add', { paths })
  /** Removes the not yet played "Add to queue" songs. */
  clearAdded = () => this.#run('queue_clear_added')
  playNext = (path: string) => this.#run('queue_play_next', { path })
  playIndex = (index: number) => this.#run('player_play_index', { index })
  removeIndex = (index: number) => this.#run('queue_remove', { index })
  moveIndex = (from: number, to: number) => {
    if (from === to || from < 0 || to < 0) return Promise.resolve()
    if (
      from < this.queue.length &&
      to < this.queue.length &&
      this.queue.length === this.snapshot.queueLength
    ) {
      const next = [...this.queue]
      const [moved] = next.splice(from, 1)
      next.splice(to, 0, moved)
      this.queue = next
    }
    return this.#run('queue_move', { from, to })
  }
  togglePause = () => this.#run('player_toggle_pause')

  /** Whether the queue was started from `context` ("album:3",
   *  "playlist:7", "favorites") and still has a song. */
  isPlayingFrom = (context: string): boolean =>
    this.snapshot.context === context && this.snapshot.current !== null
  /** Same, and not paused: show a pause button. */
  isActiveFrom = (context: string): boolean =>
    this.isPlayingFrom(context) && this.snapshot.status === 'playing'
  /** Spotify-style play button of an album or playlist: pause / resume when
   *  it is the one playing, otherwise `start` it. */
  playOrToggle = (context: string, start: () => unknown): void => {
    if (this.isPlayingFrom(context)) void this.togglePause()
    else void start()
  }
  next = () => this.#run('player_next')
  previous = () => this.#run('player_previous')
  /** Previous entry even when the current one has played > 3 s (swipes). */
  previousTrack = () => this.#run('player_previous_track')
  setVolume = (percent: number) => {
    const clamped = Math.max(0, Math.min(100, Math.round(percent)))
    if (clamped > 0) this.#unmutedVolume = clamped
    return this.#run('player_set_volume', { percent: clamped })
  }
  adjustVolume = (delta: number) => this.setVolume(this.snapshot.volume + delta)
  toggleMute = () => {
    if (this.snapshot.volume > 0) {
      this.#unmutedVolume = this.snapshot.volume
      return this.#run('player_set_volume', { percent: 0 })
    }
    return this.setVolume(this.#unmutedVolume > 0 ? this.#unmutedVolume : 100)
  }
  setShuffle = (enabled: boolean) => this.#run('player_set_shuffle', { enabled })
  toggleShuffle = () => this.setShuffle(!this.snapshot.shuffle)
  setRepeat = (mode: RepeatMode) => this.#run('player_set_repeat', { mode })
  cycleRepeat = () => {
    const order: RepeatMode[] = ['off', 'all', 'one']
    const next = order[(order.indexOf(this.snapshot.repeat) + 1) % order.length]
    return this.setRepeat(next)
  }
  setReplayGain = (mode: ReplayGain) => this.#run('player_set_replaygain', { mode })
  setGapless = (enabled: boolean) => this.#run('player_set_gapless', { enabled })
  setEqualizer = (equalizer: Equalizer) => this.#run('player_set_equalizer', { equalizer })
  setCrossfade = (seconds: number) => this.#run('player_set_crossfade', { seconds })
  /** Minutes, or `endOfTrack`; `(null, false)` turns the timer off. */
  setSleepTimer = (minutes: number | null, endOfTrack = false) =>
    this.#run('player_set_sleep_timer', { minutes, endOfTrack })
  setWasapiExclusive = (enabled: boolean) => this.#run('player_set_wasapi_exclusive', { enabled })
  seek = (seconds: number) => {
    this.#setAnchor(seconds)
    return this.#run('player_seek', { seconds })
  }
  seekRelative = (deltaSeconds: number) => {
    const dur = this.snapshot.durationSeconds
    if (dur === null || dur <= 0) return Promise.resolve()
    return this.seek(Math.max(0, Math.min(dur, this.position + deltaSeconds)))
  }

  async #run(command: string, args?: Record<string, unknown>): Promise<void> {
    try {
      this.#apply(await invoke<PlayerSnapshot>(command, args))
      this.error = null
    } catch (e) {
      this.error = String(e)
    }
  }

  #apply(next: PlayerSnapshot): void {
    const wasPlaying = this.snapshot.status === 'playing'
    this.snapshot = next
    this.#setAnchor(next.positionSeconds)
    if (next.queueVersion !== this.#loadedQueueVersion) void this.#loadQueue(next.queueVersion)
    if (next.status === 'playing' && !wasPlaying) this.#startClock()
    if (next.status !== 'playing') {
      cancelAnimationFrame(this.#frame)
      this.#frame = 0
    }
  }

  #setAnchor(seconds: number): void {
    const at = performance.now()
    this.#anchor = { seconds, at }
    this.#now = at
  }

  #startClock(): void {
    cancelAnimationFrame(this.#frame)
    this.#frame = 0
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
    const tick = (t: number) => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') {
        this.#frame = 0
        return
      }
      // Throttle position reactivity to ~10 Hz while keeping seekbars and 0.1s lyric sync smooth.
      if (t - this.#now >= 100) this.#now = t
      if (this.snapshot.status === 'playing') this.#frame = requestAnimationFrame(tick)
    }
    this.#frame = requestAnimationFrame(tick)
  }

  async #loadQueue(version: number): Promise<void> {
    this.#loadedQueueVersion = version
    const rows: TrackInfo[] = []
    for (let offset = 0; offset < this.snapshot.queueLength; offset += PAGE_SIZE) {
      const page = await invoke<TrackInfo[]>('queue_page', { offset, limit: PAGE_SIZE })
      if (this.#loadedQueueVersion !== version) return // a newer load started
      rows.push(...page)
      if (page.length < PAGE_SIZE) break
    }
    this.queue = rows
  }
}

export const player = new PlayerStore()

export function randomTrackIndex(count: number): number {
  return count > 1 ? Math.floor(Math.random() * count) : 0
}

export function formatTime(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds)) return '–:––'
  const s = Math.floor(seconds)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = String(s % 60).padStart(2, '0')
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`
}

import type { TrackRow } from './library.svelte'

export interface TrackMenuContext {
  track: TrackRow
  x: number
  y: number
  alignRight?: boolean
  onPlay?: () => void
  onRemoveFromPlaylist?: () => void
  onRemoveFromQueue?: () => void
}

export type TrackMenuOptions = Omit<TrackMenuContext, 'track' | 'x' | 'y' | 'alignRight'>

class TrackMenuState {
  current = $state<TrackMenuContext | null>(null)
  #openQueue: (() => void) | null = null

  /** The phone or desktop shell says how "Go to queue" opens the queue. */
  registerQueueOpener(fn: () => void): void {
    this.#openQueue = fn
  }

  get canOpenQueue(): boolean {
    return this.#openQueue !== null
  }

  openQueue(): void {
    this.#openQueue?.()
  }

  open(ctx: TrackMenuContext): void {
    this.current = ctx
  }

  fromEvent(e: MouseEvent, track: TrackRow, opts?: TrackMenuOptions): void {
    e.preventDefault()
    e.stopPropagation()
    this.open({ track, x: e.clientX, y: e.clientY, ...opts })
  }

  fromButton(el: HTMLElement | null, track: TrackRow, opts?: TrackMenuOptions): void {
    if (!el) return
    const r = el.getBoundingClientRect()
    this.open({ track, x: r.right, y: r.bottom + 4, alignRight: true, ...opts })
  }

  close(): void {
    this.current = null
  }
}

export const trackMenu = new TrackMenuState()

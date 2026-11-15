// Spotify-like horizontal swipe between songs (phones). The previous and next
// songs sit left and right of the current one; the strip follows the finger,
// and on release it either springs back or slides the neighbour fully in and
// then switches the song, so nothing jumps. A quick flick is enough.
import { motionDuration } from './motion'
import { player } from './player.svelte'

const SETTLE_MS = 240
/** Fraction of the width, or a flick faster than this (px/ms), switches. */
const DISTANCE = 0.28
const FLICK = 0.45

export class TrackSwipe {
  /** Strip offset in px (negative: towards the next song). */
  offset = $state(0)
  /** True while the strip animates (CSS transition on). */
  settling = $state(false)
  width = 0
  #samples: { x: number; t: number }[] = []
  #busy = false

  get hasNext(): boolean {
    return player.snapshot.nextTrack !== null
  }

  get hasPrevious(): boolean {
    return player.snapshot.previousTrack !== null
  }

  /** CSS transform for a three-panel strip [previous, current, next]. */
  get transform(): string {
    return `translate3d(calc(-100% / 3 + ${this.offset}px), 0, 0)`
  }

  get transition(): string {
    return this.settling ? `transform ${motionDuration(SETTLE_MS)}ms cubic-bezier(0.22, 0.8, 0.3, 1)` : 'none'
  }

  /** Finger moved horizontally by `dx` since the gesture started. */
  drag(dx: number): void {
    if (this.#busy) return
    this.settling = false
    const now = performance.now()
    this.#samples.push({ x: dx, t: now })
    while (this.#samples.length > 6) this.#samples.shift()
    // No song that way: resist like a rubber band.
    const blocked = (dx < 0 && !this.hasNext) || (dx > 0 && !this.hasPrevious)
    this.offset = blocked ? dx * 0.25 : dx
  }

  /** Finger lifted: spring back or switch. */
  release(): void {
    if (this.#busy) return
    const s = this.#samples
    this.#samples = []
    let velocity = 0
    if (s.length >= 2) {
      const a = s[0]
      const b = s[s.length - 1]
      velocity = (b.x - a.x) / Math.max(1, b.t - a.t)
    }
    const w = this.width || 1
    const dx = this.offset
    const toNext = this.hasNext && (dx < -w * DISTANCE || (velocity < -FLICK && dx < 0))
    const toPrevious = this.hasPrevious && (dx > w * DISTANCE || (velocity > FLICK && dx > 0))
    this.settling = true
    if (!toNext && !toPrevious) {
      this.offset = 0
      return
    }
    this.#busy = true
    this.offset = toNext ? -w : w
    setTimeout(() => void this.#commit(toNext), motionDuration(SETTLE_MS))
  }

  cancel(): void {
    if (this.#busy) return
    this.#samples = []
    this.settling = true
    this.offset = 0
  }

  async #commit(next: boolean): Promise<void> {
    try {
      await (next ? player.next() : player.previousTrack())
    } finally {
      // The centre panel now shows the new song, which is what was on the
      // side: put the strip back without animating.
      this.settling = false
      this.offset = 0
      this.#busy = false
    }
  }
}

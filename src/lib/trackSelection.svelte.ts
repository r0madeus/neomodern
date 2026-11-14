// Multi-select for song lists (decision K16). One selection for the whole
// app, tied to the list it was made in (`scope`): moving to another list
// clears it. Desktop: Ctrl/Cmd-click toggles, Shift-click selects a range,
// Ctrl/Cmd+A selects the loaded rows, Escape clears. Phones: a long press
// starts selecting and taps then toggle.
import { SvelteMap } from 'svelte/reactivity'
import type { TrackRow } from './library.svelte'

interface Picked {
  index: number
  track: TrackRow
}

class TrackSelection {
  #items = new SvelteMap<string, Picked>()
  scope = $state<string | null>(null)
  /** Phones: taps toggle rows instead of playing them. */
  touchMode = $state(false)
  #anchor: number | null = null

  get size(): number {
    return this.#items.size
  }

  has(scope: string, path: string): boolean {
    return this.scope === scope && this.#items.has(path)
  }

  /** Selected tracks in list order. */
  get tracks(): TrackRow[] {
    return [...this.#items.values()].sort((a, b) => a.index - b.index).map((p) => p.track)
  }

  clear(): void {
    this.#items.clear()
    this.#anchor = null
    this.touchMode = false
  }

  #useScope(scope: string): void {
    if (this.scope !== scope) {
      this.clear()
      this.scope = scope
    }
  }

  #toggle(index: number, track: TrackRow): void {
    if (this.#items.has(track.path)) this.#items.delete(track.path)
    else this.#items.set(track.path, { index, track })
    this.#anchor = index
    if (this.#items.size === 0) this.touchMode = false
  }

  /**
   * Row click on desktop. Returns true when the click was a selection
   * (Ctrl/Cmd or Shift held); a plain click clears an existing selection.
   */
  click(
    e: MouseEvent,
    scope: string,
    index: number,
    track: TrackRow,
    rowAt: (i: number) => TrackRow | undefined,
  ): boolean {
    const target = e.target as HTMLElement | null
    const inner = target?.closest('a, button, input')
    if (inner && inner !== e.currentTarget) return false
    const toggle = e.ctrlKey || e.metaKey
    if (!toggle && !e.shiftKey) {
      if (this.size > 0) this.clear()
      return false
    }
    e.preventDefault()
    this.#useScope(scope)
    if (e.shiftKey && this.#anchor !== null) {
      const [lo, hi] = this.#anchor < index ? [this.#anchor, index] : [index, this.#anchor]
      for (let i = lo; i <= hi; i++) {
        const row = i === index ? track : rowAt(i)
        if (row) this.#items.set(row.path, { index: i, track: row })
      }
    } else {
      this.#toggle(index, track)
    }
    return true
  }

  /** Ctrl/Cmd+A: every row that is loaded. */
  selectAll(scope: string, count: number, rowAt: (i: number) => TrackRow | undefined): void {
    this.#useScope(scope)
    for (let i = 0; i < count; i++) {
      const row = rowAt(i)
      if (row) this.#items.set(row.path, { index: i, track: row })
    }
  }

  /** Phones: long press starts selecting with this row. */
  start(scope: string, index: number, track: TrackRow): void {
    this.#useScope(scope)
    this.touchMode = true
    if (!this.#items.has(track.path)) this.#items.set(track.path, { index, track })
  }

  /** Phones: a tap while selecting. */
  tap(scope: string, index: number, track: TrackRow): void {
    this.#useScope(scope)
    this.#toggle(index, track)
  }

  /** Keyboard shortcuts on a list row; true when handled. */
  key(e: KeyboardEvent, scope: string, count: number, rowAt: (i: number) => TrackRow | undefined): boolean {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'a') {
      e.preventDefault()
      this.selectAll(scope, count, rowAt)
      return true
    }
    if (e.key === 'Escape' && this.size > 0) {
      e.preventDefault()
      this.clear()
      return true
    }
    return false
  }
}

export const selection = new TrackSelection()

/** Long press (touch) on an element: calls `onPress` after 450 ms. */
export function longPress(node: HTMLElement, onPress: () => void) {
  let timer: ReturnType<typeof setTimeout> | null = null
  let startX = 0
  let startY = 0
  let fired = false
  const cancel = () => {
    if (timer !== null) clearTimeout(timer)
    timer = null
  }
  const down = (e: PointerEvent) => {
    if (e.pointerType === 'mouse') return
    fired = false
    startX = e.clientX
    startY = e.clientY
    cancel()
    timer = setTimeout(() => {
      fired = true
      navigator.vibrate?.(20)
      onPress()
    }, 450)
  }
  const move = (e: PointerEvent) => {
    if (Math.hypot(e.clientX - startX, e.clientY - startY) > 10) cancel()
  }
  // The click that ends a long press must not also play the row.
  const click = (e: MouseEvent) => {
    if (fired) {
      e.stopPropagation()
      e.preventDefault()
      fired = false
    }
  }
  const menu = (e: Event) => {
    if (timer !== null || fired) e.preventDefault()
  }
  node.addEventListener('pointerdown', down)
  node.addEventListener('pointermove', move)
  node.addEventListener('pointerup', cancel)
  node.addEventListener('pointercancel', cancel)
  node.addEventListener('click', click, true)
  node.addEventListener('contextmenu', menu)
  return {
    update(next: () => void) {
      onPress = next
    },
    destroy() {
      cancel()
      node.removeEventListener('pointerdown', down)
      node.removeEventListener('pointermove', move)
      node.removeEventListener('pointerup', cancel)
      node.removeEventListener('pointercancel', cancel)
      node.removeEventListener('click', click, true)
      node.removeEventListener('contextmenu', menu)
    },
  }
}

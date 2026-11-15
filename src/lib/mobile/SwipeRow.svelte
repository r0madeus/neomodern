<script lang="ts">
  import type { Snippet } from 'svelte'
  import Icon, { type Name } from '../Icon.svelte'

  // A list row that can be swiped sideways, like Spotify's song rows:
  // swiping right reveals `right` (e.g. add to queue) on the left edge,
  // swiping left reveals `left` (e.g. like, remove) on the right edge.
  // Past the threshold the action runs when the finger lifts; the row
  // springs back either way. Vertical scrolling is left alone.
  export interface SwipeAction {
    icon: Name
    label: string
    /** Panel colour (Tailwind bg class). */
    tone?: 'accent' | 'danger'
    run: () => void
  }

  let {
    right = null,
    left = null,
    disabled = false,
    children,
  }: {
    right?: SwipeAction | null
    left?: SwipeAction | null
    disabled?: boolean
    children: Snippet
  } = $props()

  const THRESHOLD = 96
  const MAX = 140

  let dx = $state(0)
  let settling = $state(false)
  let startX = 0
  let startY = 0
  let axis: 'none' | 'x' | 'y' = 'none'
  let swiped = false

  function onStart(e: TouchEvent) {
    if (disabled || e.touches.length !== 1) return
    startX = e.touches[0].clientX
    startY = e.touches[0].clientY
    axis = 'none'
    settling = false
  }

  function onMove(e: TouchEvent) {
    if (disabled || e.touches.length !== 1) return
    const mx = e.touches[0].clientX - startX
    const my = e.touches[0].clientY - startY
    if (axis === 'none') {
      if (Math.abs(mx) > 10 && Math.abs(mx) > Math.abs(my) * 1.4) axis = 'x'
      else if (Math.abs(my) > 10) axis = 'y'
      else return
    }
    if (axis !== 'x') return
    let next = mx
    if (next > 0 && !right) next = 0
    if (next < 0 && !left) next = 0
    // Resist past the threshold.
    const sign = Math.sign(next)
    const abs = Math.abs(next)
    dx = sign * (abs <= THRESHOLD ? abs : Math.min(MAX, THRESHOLD + (abs - THRESHOLD) * 0.35))
  }

  function onEnd() {
    if (axis === 'x') {
      swiped = true
      if (dx >= THRESHOLD) right?.run()
      else if (dx <= -THRESHOLD) left?.run()
    }
    axis = 'none'
    settling = true
    dx = 0
  }

  // A swipe must not also count as a tap on the row.
  function onClickCapture(e: MouseEvent) {
    if (swiped) {
      e.stopPropagation()
      e.preventDefault()
    }
    swiped = false
  }

  const armed = $derived(Math.abs(dx) >= THRESHOLD)
  const tone = (a: SwipeAction | null) => (a?.tone === 'danger' ? 'bg-red-600' : 'bg-accent-500')
</script>

<div class="relative overflow-hidden">
  {#if dx > 0 && right}
    <div
      class={['absolute inset-y-0 left-0 flex items-center justify-center text-zinc-950 transition-[filter]', tone(right), !armed && 'brightness-75']}
      style:width="{dx}px"
      aria-hidden="true"
    >
      <Icon name={right.icon} class="size-7" />
    </div>
  {:else if dx < 0 && left}
    <div
      class={['absolute inset-y-0 right-0 flex items-center justify-center text-white transition-[filter]', tone(left), left.tone !== 'danger' && 'text-zinc-950', !armed && 'brightness-75']}
      style:width="{-dx}px"
      aria-hidden="true"
    >
      <Icon name={left.icon} class="size-7" />
    </div>
  {/if}
  <div
    role="presentation"
    class="relative bg-zinc-950"
    style:transform={dx !== 0 ? `translateX(${dx}px)` : undefined}
    style:transition={settling ? 'transform 180ms ease-out' : undefined}
    ontouchstart={onStart}
    ontouchmove={onMove}
    ontouchend={onEnd}
    ontouchcancel={onEnd}
    onclickcapture={onClickCapture}
  >
    {@render children()}
  </div>
</div>

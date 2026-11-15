<script lang="ts">
  import type { Snippet } from 'svelte'
  import { tick } from 'svelte'
  import Icon from './Icon.svelte'
  import { portal } from './portal'

  // The "…" button of a page header and its menu. The menu lives at the end
  // of <body> (fixed) so no parent clips or covers it. `children` gets a
  // `close` function for its items.
  let {
    label,
    children,
  }: {
    label: string
    children: Snippet<[() => void]>
  } = $props()

  const WIDTH = 240
  let open = $state(false)
  let trigger = $state<HTMLButtonElement | null>(null)
  let menu = $state<HTMLDivElement | null>(null)
  let place = $state({ left: 0, top: 0 })

  async function show() {
    if (!trigger) return
    const r = trigger.getBoundingClientRect()
    place = { left: Math.max(8, Math.min(r.left, window.innerWidth - WIDTH - 8)), top: r.bottom + 6 }
    open = true
    await tick()
    if (!menu) return
    // Keep it on screen: open upwards when there is no room below.
    const h = menu.offsetHeight
    if (place.top + h > window.innerHeight - 8) place = { ...place, top: Math.max(8, r.top - h - 6) }
    menu.querySelector<HTMLElement>('[role="menuitem"]')?.focus()
  }

  function close() {
    open = false
  }

  $effect(() => {
    if (!open) return
    const onDown = (e: PointerEvent) => {
      const target = e.target as Node
      if (menu?.contains(target) || trigger?.contains(target)) return
      close()
    }
    const onScroll = (e: Event) => {
      if (!menu?.contains(e.target as Node)) close()
    }
    window.addEventListener('pointerdown', onDown, true)
    window.addEventListener('scroll', onScroll, true)
    window.addEventListener('resize', close)
    return () => {
      window.removeEventListener('pointerdown', onDown, true)
      window.removeEventListener('scroll', onScroll, true)
      window.removeEventListener('resize', close)
    }
  })

  function onKey(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault()
      e.stopPropagation()
      close()
      trigger?.focus()
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      const list = [...(menu?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])]
      const at = list.indexOf(document.activeElement as HTMLElement)
      const next = e.key === 'ArrowDown' ? (at + 1) % list.length : (at - 1 + list.length) % list.length
      list[next]?.focus()
    } else if (e.key === 'Tab') {
      close()
    }
  }
</script>

<button
  bind:this={trigger}
  type="button"
  aria-label={label}
  title={label}
  aria-haspopup="menu"
  aria-expanded={open}
  class="rounded-full p-1.5 text-white/70 outline-none hover:text-white focus-visible:ring-2 focus-visible:ring-white/70"
  onclick={() => (open ? close() : void show())}
>
  <Icon name="more" class="size-7" />
</button>

{#if open}
  <div
    use:portal
    bind:this={menu}
    role="menu"
    aria-label={label}
    tabindex="-1"
    onkeydown={onKey}
    class="fixed z-50 flex max-h-[70vh] flex-col overflow-y-auto rounded-xl border border-zinc-200 bg-white py-1 text-sm text-zinc-800 shadow-xl dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
    style:left="{place.left}px"
    style:top="{place.top}px"
    style:width="{WIDTH}px"
  >
    {@render children(close)}
  </div>
{/if}

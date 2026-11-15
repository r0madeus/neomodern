<script lang="ts">
  // Sleep timer (decision K16): Rust pauses playback when it runs out and
  // fades the volume over the last seconds; this only picks the time and
  // shows what is left.
  import Icon from './Icon.svelte'
  import { portal } from './portal'
  import { t } from './i18n.svelte'
  import { player } from './player.svelte'

  /** `card`: the queue sheet's big square button with a label. */
  let { mobile = false, card = false }: { mobile?: boolean; card?: boolean } = $props()

  const CHOICES = [15, 30, 45, 60, 90, 120]

  let open = $state(false)
  let root = $state<HTMLElement | null>(null)
  let button = $state<HTMLButtonElement | null>(null)
  let menu = $state<HTMLElement | null>(null)
  // The menu is fixed to the viewport: inside the player bar (desktop) or the
  // full-screen player (phone) it was drawn under the page or clipped.
  let place = $state<{ bottom: number; left: number } | null>(null)
  const MENU_WIDTH = 240

  function toggle() {
    if (open) {
      open = false
      return
    }
    const r = button?.getBoundingClientRect()
    if (r) {
      const center = mobile || card ? r.left + r.width / 2 - MENU_WIDTH / 2 : r.right - MENU_WIDTH
      place = {
        bottom: window.innerHeight - r.top + 8,
        left: Math.max(8, Math.min(window.innerWidth - MENU_WIDTH - 8, center)),
      }
    }
    open = true
  }
  let now = $state(Date.now())

  const endsAt = $derived(player.snapshot.sleepEndsAt)
  const endOfTrack = $derived(player.snapshot.sleepEndOfTrack)
  const active = $derived(endsAt !== null || endOfTrack)
  const left = $derived(endsAt === null ? null : Math.max(0, Math.round((endsAt - now) / 1000)))

  // Tick once a second while a time is set (only for the label).
  $effect(() => {
    if (endsAt === null) return
    now = Date.now()
    const id = setInterval(() => (now = Date.now()), 1000)
    return () => clearInterval(id)
  })

  // Close on a click outside or Escape.
  $effect(() => {
    if (!open) return
    const onDown = (e: PointerEvent) => {
      const target = e.target as Node
      if (root?.contains(target) || menu?.contains(target)) return
      open = false
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        open = false
      }
    }
    const close = () => (open = false)
    document.addEventListener('pointerdown', onDown, true)
    document.addEventListener('keydown', onKey, true)
    window.addEventListener('resize', close)
    return () => {
      document.removeEventListener('pointerdown', onDown, true)
      document.removeEventListener('keydown', onKey, true)
      window.removeEventListener('resize', close)
    }
  })

  function clock(seconds: number): string {
    const h = Math.floor(seconds / 3600)
    const m = Math.floor((seconds % 3600) / 60)
    const s = seconds % 60
    const mm = String(m).padStart(h > 0 ? 2 : 1, '0')
    return h > 0 ? `${h}:${mm}:${String(s).padStart(2, '0')}` : `${mm}:${String(s).padStart(2, '0')}`
  }

  const summary = $derived(
    endOfTrack ? t('Sleep at the end of this song') : left !== null ? t('Sleep in {time}', { time: clock(left) }) : t('Sleep timer'),
  )

  function choose(minutes: number | null, atEnd = false) {
    open = false
    void player.setSleepTimer(minutes, atEnd)
  }

  const item =
    'flex w-full items-center justify-between gap-6 rounded-lg px-3 py-2 text-left text-sm hover:bg-zinc-100 dark:hover:bg-zinc-800'
</script>

<div class={card ? 'relative flex-1' : 'relative'} bind:this={root}>
  {#if card}
    <button
      type="button"
      class={['flex w-full flex-col items-center gap-1 rounded-xl bg-zinc-800 py-3 text-xs font-medium active:bg-zinc-700', active ? 'text-accent-400' : 'text-zinc-100']}
      bind:this={button}
      aria-haspopup="menu"
      aria-expanded={open}
      aria-label={summary}
      onclick={toggle}
    >
      <Icon name="moon" class="size-6" />
      {#if left !== null}{clock(left)}{:else if endOfTrack}{t('End')}{:else}{t('Timer')}{/if}
    </button>
  {:else}
  <button
    type="button"
    class={mobile
      ? ['relative flex items-center gap-1.5 rounded-full p-3 active:bg-white/10', active ? 'text-accent-400' : 'text-white/80']
      : [
          'flex items-center gap-1 rounded-full p-2 transition-colors',
          active
            ? 'bg-accent-50 text-accent-700 hover:bg-accent-100 dark:bg-accent-950/60 dark:text-accent-300 dark:hover:bg-accent-950'
            : 'text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-white',
        ]}
    bind:this={button}
    aria-haspopup="menu"
    aria-expanded={open}
    aria-label={summary}
    title={summary}
    onclick={toggle}
  >
    <Icon name="moon" class={mobile ? 'size-6' : 'size-5'} />
    {#if left !== null}
      <span class="text-xs font-medium tabular-nums">{clock(left)}</span>
    {:else if endOfTrack}
      <span class="text-xs font-medium">{t('End')}</span>
    {/if}
  </button>
  {/if}

  {#if open && place}
    <div
      role="menu"
      aria-label={t('Sleep timer')}
      use:portal
      bind:this={menu}
      class="fixed z-[100] rounded-xl border border-zinc-200 bg-white p-1.5 text-zinc-800 shadow-xl dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
      style:width="{MENU_WIDTH}px"
      style:bottom="{place.bottom}px"
      style:left="{place.left}px"
    >
      <p class="px-3 pt-1.5 pb-1 text-xs font-semibold tracking-wide text-zinc-500 uppercase">{t('Sleep timer')}</p>
      {#each CHOICES as m (m)}
        <button type="button" role="menuitem" class={item} onclick={() => choose(m)}>
          <span>{m < 60 ? t('{n} minutes', { n: m }) : m === 60 ? t('1 hour') : t('{h} hours', { h: m / 60 })}</span>
        </button>
      {/each}
      <button type="button" role="menuitem" class={item} onclick={() => choose(null, true)}>
        <span>{t('End of this song')}</span>
        {#if endOfTrack}<Icon name="check" class="size-4 text-accent-600 dark:text-accent-400" />{/if}
      </button>
      {#if active}
        <div class="my-1 border-t border-zinc-200 dark:border-zinc-700"></div>
        <button type="button" role="menuitem" class={[item, 'text-red-600 dark:text-red-400']} onclick={() => choose(null)}>
          {t('Turn off timer')}
        </button>
      {/if}
    </div>
  {/if}
</div>

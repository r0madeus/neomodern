<script lang="ts">
  // Sleep timer (decision K16): Rust pauses playback when it runs out and
  // fades the volume over the last seconds; this only picks the time and
  // shows what is left.
  import Icon from './Icon.svelte'
  import { t } from './i18n.svelte'
  import { player } from './player.svelte'

  let { mobile = false }: { mobile?: boolean } = $props()

  const CHOICES = [15, 30, 45, 60, 90, 120]

  let open = $state(false)
  let root = $state<HTMLElement | null>(null)
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
      if (root && !root.contains(e.target as Node)) open = false
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        open = false
      }
    }
    document.addEventListener('pointerdown', onDown, true)
    document.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('pointerdown', onDown, true)
      document.removeEventListener('keydown', onKey, true)
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

<div class="relative" bind:this={root}>
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
    aria-haspopup="menu"
    aria-expanded={open}
    aria-label={summary}
    title={summary}
    onclick={() => (open = !open)}
  >
    <Icon name="moon" class={mobile ? 'size-6' : 'size-5'} />
    {#if left !== null}
      <span class="text-xs font-medium tabular-nums">{clock(left)}</span>
    {:else if endOfTrack}
      <span class="text-xs font-medium">{t('End')}</span>
    {/if}
  </button>

  {#if open}
    <div
      role="menu"
      aria-label={t('Sleep timer')}
      class={[
        'absolute bottom-full z-50 mb-2 w-60 rounded-xl border border-zinc-200 bg-white p-1.5 text-zinc-800 shadow-xl dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100',
        mobile ? 'left-1/2 -translate-x-1/2' : 'right-0',
      ]}
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

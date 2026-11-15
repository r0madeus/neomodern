<script lang="ts">
  // Actions for the songs picked with multi-select (trackSelection). Shown
  // above the player bar on desktop and above the mini player on phones.
  import { invoke } from '@tauri-apps/api/core'
  import AddToPlaylist from './AddToPlaylist.svelte'
  import Icon from './Icon.svelte'
  import { count, t } from './i18n.svelte'
  import { player } from './player.svelte'
  import { playlists } from './playlists.svelte'
  import { selection } from './trackSelection.svelte'

  let { mobile = false }: { mobile?: boolean } = $props()

  const tracks = $derived(selection.tracks)
  const paths = $derived(tracks.map((tr) => tr.path))
  const ids = $derived(tracks.map((tr) => tr.id).filter((id) => id > 0))

  async function run(action: () => Promise<unknown>, done: string) {
    try {
      await action()
      if (!player.error) playlists.flash(done)
      selection.clear()
    } catch (e) {
      player.error = String(e)
    }
  }

  const play = () => run(() => player.openFiles(paths), t('Playing {n}', { n: count(paths.length, '{n} song', '{n} songs') }))
  const playNext = () =>
    run(async () => {
      player.applySnapshot(await invoke('queue_play_next_many', { paths }))
    }, t('Queued to play next'))
  const queue = () => run(() => player.addToQueue(paths), t('Added to queue'))
  const favorite = () => run(() => invoke('favorites_set_many', { trackIds: ids, favorite: true }), t('Added to favorites'))

  $effect(() => {
    if (selection.size === 0) return
    const onKey = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null
      if (e.key === 'Escape' && !el?.closest('input, textarea, [role="dialog"], [role="menu"]')) selection.clear()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  const btn = $derived(
    mobile
    ? 'flex flex-col items-center gap-0.5 rounded-lg px-2 py-1.5 text-[11px] text-zinc-200 active:bg-white/10'
    : 'flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-200/70 dark:text-zinc-200 dark:hover:bg-zinc-800',
  )
</script>

{#if selection.size > 0}
  <div
    role="toolbar"
    aria-label={t('Selected songs')}
    class={mobile
      ? 'flex items-center justify-between gap-1 rounded-2xl bg-zinc-800/95 px-2 py-1.5 text-white shadow-xl backdrop-blur'
      : 'flex flex-wrap items-center justify-between gap-2 rounded-xl border border-accent-500/30 bg-accent-500/10 px-4 py-2 text-sm dark:border-accent-400/25 dark:bg-accent-400/10'}
  >
    <div class={['flex items-center gap-3', mobile && 'pl-1']}>
      <button
        type="button"
        class={mobile ? 'rounded-full p-1.5 active:bg-white/10' : 'rounded-md p-1 text-zinc-500 hover:bg-zinc-200/70 dark:hover:bg-zinc-800'}
        aria-label={t('Clear selection')}
        title={t('Clear selection')}
        onclick={() => selection.clear()}
      >
        <Icon name="close" class="size-4" />
      </button>
      <span class={mobile ? 'text-sm font-semibold' : 'font-medium text-accent-800 dark:text-accent-200'}>
        {t('{n} selected', { n: selection.size })}
      </span>
    </div>
    <div class="flex flex-wrap items-center gap-1">
      <button
        type="button"
        class={mobile
          ? btn
          : 'flex items-center gap-1.5 rounded-lg bg-accent-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-accent-500 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400'}
        onclick={() => void play()}
      >
        <Icon name="play" class={mobile ? 'size-5' : 'size-4'} />
        {t('Play')}
      </button>
      <button type="button" class={btn} onclick={() => void playNext()}>
        <Icon name="up" class={mobile ? 'size-5' : 'size-4'} />
        {t('Play next')}
      </button>
      <button type="button" class={btn} onclick={() => void queue()}>
        <Icon name="queue" class={mobile ? 'size-5' : 'size-4'} />
        {t('Add to queue')}
      </button>
      {#if ids.length > 0}
        <button type="button" class={btn} onclick={() => void favorite()}>
          <Icon name="star" class={mobile ? 'size-5' : 'size-4'} />
          {t('Favorite')}
        </button>
        <AddToPlaylist trackIds={ids} text={!mobile} editTags={!mobile} class={mobile ? 'p-2 text-zinc-200' : ''} />
      {/if}
    </div>
  </div>
{/if}

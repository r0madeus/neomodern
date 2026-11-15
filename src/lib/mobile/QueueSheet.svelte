<script lang="ts">
  import { t } from '../i18n.svelte'
  import { fade, fly } from 'svelte/transition'
  import { invoke } from '@tauri-apps/api/core'
  import ActionsMenu from '../ActionsMenu.svelte'
  import Cover from '../Cover.svelte'
  import Equalizer from '../Equalizer.svelte'
  import Icon from '../Icon.svelte'
  import SleepTimerButton from '../SleepTimerButton.svelte'
  import { createDragReorder } from '../dragReorder.svelte'
  import DropIndicator from '../DropIndicator.svelte'
  import { motionDuration, viewportHeight } from '../motion'
  import { player } from '../player.svelte'
  import { playlists } from '../playlists.svelte'
  import { trackCovers } from '../trackCovers.svelte'
  import SwipeRow from './SwipeRow.svelte'

  // Spotify-style queue sheet over the player: what is playing and from
  // where, the songs to come (drag ≡ to reorder, swipe left to remove,
  // right to add again), Clear for the songs added with "Add to queue",
  // and Shuffle / Repeat / Timer at the bottom.
  let { onClose }: { onClose: () => void } = $props()

  const ROW = 64

  // "Open files": the system picker, after asking for music access. Files
  // without a path on the phone (e.g. from a cloud drive) are skipped.
  let picking = $state(false)
  let note = $state<string | null>(null)
  async function pickFiles(append: boolean) {
    if (picking) return
    picking = true
    note = null
    try {
      const res = await invoke<{ paths: string[]; skipped: number }>('android_pick_audio_files')
      if (res.paths.length > 0) {
        if (append) await player.appendFiles(res.paths)
        else await player.openFiles(res.paths)
      }
      if (res.skipped > 0) {
        note =
          res.skipped === 1
            ? t('1 file could not be opened: it is not stored on this phone.')
            : t('{n} files could not be opened: they are not stored on this phone.', { n: res.skipped })
      }
    } catch (e) {
      player.error = String(e)
    } finally {
      picking = false
    }
  }

  const current = $derived(player.snapshot.currentIndex)
  const nowTrack = $derived(current !== null ? (player.queue[current] ?? null) : null)
  const offset = $derived(current === null ? 0 : current + 1)
  const upNext = $derived(player.queue.slice(offset))
  const hasAdded = $derived(upNext.some((tr) => tr.queued))

  // "Playing <list>": the album, playlist or Favorites the queue came from.
  let albumTitle = $state<string | null>(null)
  $effect(() => {
    const ctx = player.snapshot.context
    albumTitle = null
    if (!ctx?.startsWith('album:')) return
    let stale = false
    invoke<{ album: { title: string } }>('library_album', { albumId: Number(ctx.slice(6)) })
      .then((d) => {
        if (!stale) albumTitle = d.album.title
      })
      .catch(() => {})
    return () => (stale = true)
  })
  const contextName = $derived.by(() => {
    const ctx = player.snapshot.context
    if (!ctx) return null
    if (ctx === 'favorites') return t('Favorites')
    if (ctx.startsWith('playlist:')) return playlists.byId(Number(ctx.slice(9)))?.name ?? null
    if (ctx.startsWith('album:')) return albumTitle
    return null
  })

  let editing = $state(false)

  let listEl = $state<HTMLOListElement | null>(null)
  const drag = createDragReorder({
    rowHeight: ROW,
    getCount: () => upNext.length,
    getListEl: () => listEl,
    getScrollEl: () => listEl?.closest<HTMLElement>('.overflow-y-auto') ?? null,
    onMove: (from, to) => player.moveIndex(offset + from, offset + to),
  })
  $effect(() => () => drag.destroy())

  const repeatLabel = $derived(
    player.snapshot.repeat === 'one' ? t('Repeat one') : player.snapshot.repeat === 'all' ? t('Repeat all') : t('Repeat'),
  )
  const card = 'flex flex-1 flex-col items-center gap-1 rounded-xl bg-zinc-800 py-3 text-xs font-medium active:bg-zinc-700'
</script>

<div class="fixed inset-0 z-50 text-white" role="dialog" aria-modal="true" aria-label={t('Queue')}>
  <button
    type="button"
    class="absolute inset-0 bg-black/50"
    aria-label={t('Close queue')}
    tabindex="-1"
    onclick={onClose}
    transition:fade={{ duration: motionDuration(150) }}
  ></button>
  <div
    class="absolute inset-x-0 bottom-0 flex h-[70vh] flex-col rounded-t-2xl bg-zinc-900 shadow-2xl"
    style:padding-bottom="var(--inset-bottom)"
    transition:fly={{ y: viewportHeight(), duration: motionDuration(220), opacity: 1 }}
  >
    <button type="button" class="flex shrink-0 justify-center pt-2.5 pb-1" aria-label={t('Close queue')} onclick={onClose}>
      <span class="h-1 w-10 rounded-full bg-zinc-600"></span>
    </button>

    <header class="flex shrink-0 items-center gap-2 px-4 pt-1">
      <h1 class="min-w-0 flex-1 text-xl font-bold">{t('Queue')}</h1>
      {#if hasAdded}
        <button type="button" class="rounded-full bg-zinc-800 px-4 py-2 text-sm font-semibold active:bg-zinc-700" onclick={() => void player.clearAdded()}>
          {t('Clear')}
        </button>
      {/if}
      {#if upNext.length > 0}
        <button
          type="button"
          class={['rounded-full px-4 py-2 text-sm font-semibold', editing ? 'bg-zinc-100 text-zinc-900' : 'bg-zinc-800 active:bg-zinc-700']}
          aria-pressed={editing}
          onclick={() => (editing = !editing)}
        >
          {t(editing ? 'Done' : 'Edit')}
        </button>
      {/if}
      <ActionsMenu label={t('More actions')}>
        {#snippet children(close)}
          <button
            type="button"
            role="menuitem"
            class="flex w-full items-center gap-3 px-4 py-3 text-left active:bg-zinc-100 dark:active:bg-zinc-800"
            disabled={picking}
            onclick={() => {
              close()
              void pickFiles(false)
            }}
          >
            <Icon name="folder" class="size-5 text-zinc-500" />{t('Open files')}
          </button>
          {#if player.snapshot.queueLength > 0}
            <button
              type="button"
              role="menuitem"
              class="flex w-full items-center gap-3 px-4 py-3 text-left active:bg-zinc-100 dark:active:bg-zinc-800"
              disabled={picking}
              onclick={() => {
                close()
                void pickFiles(true)
              }}
            >
              <Icon name="queueAdd" class="size-5 text-zinc-500" />{t('Add files to the queue')}
            </button>
          {/if}
        {/snippet}
      </ActionsMenu>
    </header>
    <p class="shrink-0 truncate px-4 pb-3 text-sm text-zinc-400">
      {#if contextName}{t('Playing')} <span class="font-semibold text-zinc-100">{contextName}</span>{/if}
    </p>
    {#if note}
      <p role="status" class="mx-4 mb-2 rounded-lg bg-zinc-800 px-3 py-2 text-sm text-zinc-200">{note}</p>
    {/if}

    <div class="min-h-0 flex-1 overflow-y-auto">
      {#if nowTrack}
        <div class="flex h-16 items-center gap-3 px-4">
          <Cover cover={trackCovers.get(nowTrack.path) ?? null} title={nowTrack.title} class="size-12 shrink-0 rounded text-sm" />
          <span class="min-w-0 flex-1">
            <span class="flex items-center gap-1.5 text-[15px] text-accent-400">
              {#if player.snapshot.status === 'playing'}<Equalizer class="shrink-0" />{/if}
              <span class="truncate">{nowTrack.title}</span>
            </span>
            <span class="block truncate text-[13px] text-zinc-400">{nowTrack.artist}</span>
          </span>
          <button
            type="button"
            class="flex size-10 shrink-0 items-center justify-center rounded-full bg-white text-zinc-950 active:scale-95"
            aria-label={t(player.snapshot.status === 'playing' ? 'Pause' : 'Play')}
            onclick={() => void player.togglePause()}
          >
            <Icon name={player.snapshot.status === 'playing' ? 'pause' : 'play'} class="size-5" />
          </button>
        </div>
      {/if}

      {#if upNext.length > 0}
        <ol bind:this={listEl} class="relative">
          {#each upNext as track, i (track.id)}
            {@const index = offset + i}
            <li class={['h-16', drag.from === i && 'opacity-40']}>
              <SwipeRow
                disabled={drag.active}
                right={{
                  icon: 'queueAdd',
                  label: t('Add to queue'),
                  run: () => {
                    void player.addToQueue([track.path])
                    playlists.flash(t('Added to queue'))
                  },
                }}
                left={{ icon: 'trash', label: t('Remove from queue'), tone: 'danger', run: () => void player.removeIndex(index) }}
              >
                <div class="flex h-16 items-center gap-3 bg-zinc-900 pl-4">
                  {#if editing}
                    <button
                      type="button"
                      class="-ml-1 shrink-0 rounded-full p-1 text-red-400 active:bg-white/10"
                      aria-label={t('Remove “{title}” from queue', { title: track.title })}
                      onclick={() => void player.removeIndex(index)}
                    >
                      <Icon name="minusCircle" class="size-6" />
                    </button>
                  {/if}
                  <button type="button" class="flex min-w-0 flex-1 items-center gap-3 text-left" onclick={() => void player.playIndex(index)}>
                    <Cover cover={trackCovers.get(track.path) ?? null} title={track.title} class="size-12 shrink-0 rounded text-sm" />
                    <span class="min-w-0 flex-1">
                      <span class="block truncate text-[15px]">{track.title}</span>
                      <span class="flex min-w-0 items-center gap-1 text-[13px] text-zinc-400">
                        {#if track.queued}
                          <Icon name="queue" class="size-4 shrink-0 text-accent-400" />
                          <span class="sr-only">{t('Added to queue')}</span>
                        {/if}
                        <span class="truncate">{track.artist}</span>
                      </span>
                    </span>
                  </button>
                  <button
                    type="button"
                    class="shrink-0 touch-none p-4 text-zinc-400"
                    aria-label={t('Drag to reorder')}
                    onpointerdown={(e) => drag.onPointerDown(e, i, track.title)}
                  >
                    <Icon name="drag" class="size-6" />
                  </button>
                </div>
              </SwipeRow>
            </li>
          {/each}
          <DropIndicator count={upNext.length} rowHeight={ROW} gap={drag.gap} from={drag.from} to={drag.to} />
        </ol>
      {:else}
        <p class="px-4 pt-4 text-sm text-zinc-400">{t('Nothing after this song.')}</p>
      {/if}
    </div>

    <div class="flex shrink-0 gap-3 px-4 pt-3 pb-3">
      <button
        type="button"
        class={[card, player.snapshot.shuffle ? 'text-accent-400' : 'text-zinc-100']}
        aria-pressed={player.snapshot.shuffle}
        onclick={() => void player.toggleShuffle()}
      >
        <Icon name="shuffle" class="size-6" />
        {t('Shuffle')}
      </button>
      <button
        type="button"
        class={[card, player.snapshot.repeat !== 'off' ? 'text-accent-400' : 'text-zinc-100']}
        aria-label={repeatLabel}
        onclick={() => void player.cycleRepeat()}
      >
        <Icon name={player.snapshot.repeat === 'one' ? 'repeatOne' : 'repeat'} class="size-6" />
        {t('Repeat')}
      </button>
      <SleepTimerButton card />
    </div>
  </div>
</div>

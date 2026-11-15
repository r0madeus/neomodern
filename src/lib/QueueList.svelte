<script lang="ts">
  import ArtistLinks from './ArtistLinks.svelte'
  import Cover from './Cover.svelte'
  import { createDragReorder } from './dragReorder.svelte'
  import DragPill from './DragPill.svelte'
  import DropIndicator from './DropIndicator.svelte'
  import { t } from './i18n.svelte'
  import Icon from './Icon.svelte'
  import { library, type TrackRow } from './library.svelte'
  import { nowCover } from './nowCover.svelte'
  import { player, type TrackInfo } from './player.svelte'
  import { trackMenu } from './contextMenu.svelte'
  import { trackCovers } from './trackCovers.svelte'

  const ROW = 56

  const current = $derived(player.snapshot.currentIndex)
  const nowTrack = $derived(current !== null ? player.queue[current] ?? null : null)
  const startOffset = $derived(current === null ? 0 : current + 1)
  const upNext = $derived(player.queue.slice(startOffset))

  let listEl = $state<HTMLOListElement | null>(null)
  const drag = createDragReorder({
    rowHeight: ROW,
    getCount: () => upNext.length,
    getListEl: () => listEl,
    getScrollEl: () => listEl?.closest<HTMLElement>('.overflow-y-auto') ?? listEl?.parentElement ?? null,
    onMove: (from, to) => player.moveIndex(startOffset + from, startOffset + to),
  })

  $effect(() => () => drag.destroy())

  function fallbackRow(track: TrackInfo): TrackRow {
    return {
      id: -1,
      title: track.title,
      artist: track.artist,
      album: '',
      albumId: null,
      trackNo: null,
      discNo: null,
      year: null,
      durationMs: null,
      path: track.path,
      cover: null,
      plays: 0,
    }
  }

  async function openMenu(e: MouseEvent, track: TrackInfo, index: number) {
    e.preventDefault()
    e.stopPropagation()
    const x = e.clientX
    const y = e.clientY
    const row = (await library.trackByPath(track.path)) ?? fallbackRow(track)
    trackMenu.open({
      track: row,
      x,
      y,
      onPlay: () => void player.playIndex(index),
      onRemoveFromQueue: () => void player.removeIndex(index),
    })
  }
</script>

<div class="space-y-2 px-2 pb-4">
  {#if nowTrack && current !== null}
    <h3 class="px-2 pt-1 text-xs font-semibold text-zinc-500 dark:text-zinc-400">
      {t('Now playing')}
    </h3>
    <div
      class="flex h-14 items-center gap-3 rounded-lg bg-accent-50/70 px-2 dark:bg-accent-950/35"
      ondblclick={() => player.playIndex(current)}
      oncontextmenu={(e) => void openMenu(e, nowTrack, current)}
      role="group"
    >
      <Cover
        cover={nowCover.cover ?? trackCovers.get(nowTrack.path) ?? null}
        title={nowTrack.title}
        class="size-10 shrink-0 rounded text-xs"
      />
      <div class="min-w-0 flex-1">
        <p class="truncate text-sm font-medium text-accent-600 dark:text-accent-400" title={nowTrack.path}>
          {nowTrack.title}
        </p>
        <p class="truncate text-xs text-zinc-500 dark:text-zinc-400">
          {#if nowTrack.artist}
            <ArtistLinks artist={nowTrack.artist} />
          {:else}
            {nowTrack.path}
          {/if}
        </p>
      </div>
    </div>
  {/if}

  {#if upNext.length > 0}
    <h3 class="px-2 pt-2 text-xs font-semibold text-zinc-500 dark:text-zinc-400">
      {t('Next up')}
    </h3>
    <ol bind:this={listEl} class="relative">
      {#each upNext as track, i (track.id)}
        {@const origIndex = startOffset + i}
        <li
          class={[
            'group flex h-14 cursor-default items-center gap-3 rounded-lg px-2 text-sm transition-opacity',
            drag.from === i && 'opacity-40',
            'text-zinc-800 hover:bg-zinc-200/60 dark:text-zinc-200 dark:hover:bg-zinc-800/60',
          ]}
          onpointerdown={(e) => drag.onPointerDown(e, i, track.title)}
          ondblclick={() => player.playIndex(origIndex)}
          oncontextmenu={(e) => void openMenu(e, track, origIndex)}
        >
          <Cover
            cover={trackCovers.get(track.path) ?? null}
            title={track.title}
            class="size-10 shrink-0 rounded text-xs"
          />
          <div class="min-w-0 flex-1">
            <button
              data-drag-allow
              class="block w-full truncate text-left text-sm font-medium hover:underline"
              onclick={() => player.playIndex(origIndex)}
              title={track.path}
            >
              {track.title}
            </button>
            <p class="truncate text-xs text-zinc-500 dark:text-zinc-400">
              {#if track.artist}
                <ArtistLinks artist={track.artist} />
              {:else}
                {track.path}
              {/if}
            </p>
          </div>
          <button
            data-no-drag
            class="invisible rounded p-1 text-zinc-400 hover:bg-zinc-200 hover:text-zinc-700 group-hover:visible dark:hover:bg-zinc-700 dark:hover:text-zinc-100"
            onclick={() => player.removeIndex(origIndex)}
            aria-label={t('Remove from queue')}
          >
            <Icon name="close" class="size-4" />
          </button>
        </li>
      {/each}
      <DropIndicator count={upNext.length} rowHeight={ROW} gap={drag.gap} from={drag.from} to={drag.to} />
    </ol>
  {:else if nowTrack}
    <p class="px-2 pt-3 text-xs text-zinc-500 dark:text-zinc-400">
      {t('Nothing after this song.')}
    </p>
  {/if}
</div>

<DragPill active={drag.active} x={drag.pointer.x} y={drag.pointer.y} label={drag.label} />

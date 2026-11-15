<script lang="ts">
  import { count, t } from '../i18n.svelte'
  import Icon from '../Icon.svelte'
  import PlaylistCover from '../PlaylistCover.svelte'
  import PlaylistCoverModal from '../PlaylistCoverModal.svelte'
  import ActionsMenu from '../ActionsMenu.svelte'
  import { portal } from '../portal'
  import { underTopBar } from './titleWatch'
  import TrackItem from './TrackItem.svelte'
  import StickyPlay from './StickyPlay.svelte'
  import { playlists } from '../playlists.svelte'
  import { player } from '../player.svelte'
  import { pinned } from '../pinned.svelte'
  import type { TrackRow } from '../library.svelte'

  let { id, onBack }: { id: number; onBack: () => void } = $props()

  const info = $derived(playlists.byId(id))
  let tracks = $state<TrackRow[]>([])
  let editingCover = $state(false)
  // The bar's title appears once the big title is under the bar.
  let titleHidden = $state(false)

  // Deleting asks once more in a bottom sheet; the page then closes.
  let confirmingDelete = $state(false)
  async function deletePlaylist() {
    confirmingDelete = false
    if (await playlists.delete(id)) onBack()
  }

  $effect(() => {
    void playlists.version
    const count = info?.trackCount ?? 0
    let stale = false
    void playlists.tracks(id, count).then((rows) => {
      if (!stale) tracks = rows
    })
    return () => (stale = true)
  })

  async function shufflePlay() {
    if (tracks.length === 0) return
    await player.setShuffle(true)
    await playlists.play(id, Math.floor(Math.random() * tracks.length))
  }
</script>

<div class="absolute inset-0 flex flex-col bg-zinc-950">
  <!-- Spotify-style bar over the scrolling list (the play button sticks
       to its edge): back, the name once the big title is under the bar,
       and "…" for the rest (export). -->
  <!-- pr-[22px]: the round "…" sits right above the round play button. -->
  <header class="absolute inset-x-0 top-0 z-10 flex h-14 items-center gap-2 pr-[22px] pl-2 transition-colors" class:bg-zinc-900={titleHidden}>
    <button class="rounded-full bg-black/30 p-2.5 text-white active:bg-black/50" aria-label={t('Back')} onclick={onBack}>
      <Icon name="back" class="size-6" />
    </button>
    <h1 class={['min-w-0 flex-1 truncate text-base font-semibold transition-opacity', !titleHidden && 'opacity-0']}>
      {info?.name ?? ''}
    </h1>
    {#if info}
      <ActionsMenu
        label={t('More actions for “{title}”', { title: info.name })}
        triggerClass="rounded-full bg-black/30 p-2.5 text-white outline-none active:bg-black/50"
        iconClass="size-6"
      >
        {#snippet children(close)}
          <button
            type="button"
            role="menuitem"
            class="flex w-full items-center gap-3 px-4 py-3 text-left outline-none active:bg-zinc-100 dark:active:bg-zinc-800"
            onclick={() => {
              close()
              if (info) void playlists.exportM3u(info)
            }}
          >
            <Icon name="upload" class="size-5 text-zinc-500" />
            {t('Export…')}
          </button>
          <button
            type="button"
            role="menuitem"
            class="flex w-full items-center gap-3 px-4 py-3 text-left outline-none active:bg-zinc-100 dark:active:bg-zinc-800"
            onclick={() => {
              close()
              editingCover = true
            }}
          >
            <Icon name="image" class="size-5 text-zinc-500" />
            {t('Cover')}
          </button>
          <button
            type="button"
            role="menuitem"
            class="flex w-full items-center gap-3 border-t border-zinc-200 px-4 py-3 text-left text-red-600 outline-none active:bg-zinc-100 dark:border-zinc-800 dark:text-red-400 dark:active:bg-zinc-800"
            onclick={() => {
              close()
              confirmingDelete = true
            }}
          >
            <Icon name="trash" class="size-5" />
            {t('Delete playlist')}
          </button>
        {/snippet}
      </ActionsMenu>
    {/if}
  </header>
  <div class="min-h-0 flex-1 overflow-y-auto pt-14 pb-[var(--mobile-bar-clear,5rem)]">
    {#if info}
      <div class="flex flex-col items-center px-4 pt-2 pb-4">
        <button
          type="button"
          class="group relative aspect-square w-1/2 max-w-56 overflow-hidden rounded-xl shadow-2xl shadow-black/60 active:scale-[0.98]"
          aria-label={t('Playlist cover')}
          onclick={() => (editingCover = true)}
        >
          <PlaylistCover
            cover={info.cover}
            albumCovers={info.albumCovers}
            name={info.name}
            class="size-full rounded-xl text-5xl"
            iconClass="size-20"
          />
          <span class="absolute right-2 bottom-2 flex items-center gap-1 rounded-full bg-black/65 px-2.5 py-1 text-[11px] font-medium text-white backdrop-blur-xs">
            <Icon name="image" class="size-3.5" />
            {t('Cover')}
          </span>
        </button>
        <h2 class="mt-4 self-start text-2xl font-bold" {@attach underTopBar((hidden) => (titleHidden = hidden))}>{info.name}</h2>
        <p class="self-start text-xs text-zinc-400">
          {t('Playlist · {count}', { count: count(info.trackCount, '{n} song', '{n} songs') })}
        </p>
      </div>
      {#if tracks.length > 0}
        <!-- The list's pt-14 (bar height) counts for sticky too: -12px lets
             the button overlap the bar's lower edge (clear of "Export"). -->
        <StickyPlay
          top="-12px"
          playing={player.isActiveFrom(`playlist:${id}`)}
          onclick={() => player.playOrToggle(`playlist:${id}`, () => playlists.play(id, 0))}
        />
        <div class="flex h-16 items-center gap-2 px-4 pb-2">
          <button
            class={['rounded-full p-2.5 active:bg-white/10', pinned.isPinned('playlist', id) ? 'text-accent-400' : 'text-zinc-300']}
            aria-label={t(pinned.isPinned('playlist', id) ? 'Unpin' : 'Pin')}
            aria-pressed={pinned.isPinned('playlist', id)}
            onclick={() => void pinned.toggle('playlist', id)}
          >
            <Icon name="pin" class="size-6" />
          </button>
          <span class="flex-1"></span>
          <button class="rounded-full p-3 text-zinc-300 active:bg-white/10" aria-label={t("Shuffle play")} onclick={shufflePlay}>
            <Icon name="shuffle" class="size-6" />
          </button>
          <span class="size-14 shrink-0" aria-hidden="true"></span>
        </div>
      {:else}
        <p class="px-8 pt-6 text-center text-sm text-zinc-400">
          {t("This playlist is empty. Use the ⋯ menu on a song or album to add tracks.")}
        </p>
      {/if}
      {#each tracks as track, i (`${i}:${track.id}`)}
        <TrackItem
          title={track.title}
          subtitle={[track.artist, track.album].filter(Boolean).join(' · ')}
          path={track.path}
          cover={track.cover}
          trackId={track.id}
          {track}
          onPlay={() => playlists.play(id, i)}
          onRemoveFromPlaylist={() => void playlists.removeAt(id, [i])}
        />
      {/each}
    {/if}
  </div>
</div>

{#if editingCover && info}
  <PlaylistCoverModal playlist={info} onClose={() => (editingCover = false)} />
{/if}

{#if confirmingDelete && info}
  <div use:portal class="fixed inset-0 z-[90] flex items-end bg-black/60" role="presentation" onclick={() => (confirmingDelete = false)}>
    <div
      role="alertdialog"
      aria-modal="true"
      aria-label={t('Delete playlist')}
      tabindex="-1"
      class="w-full rounded-t-2xl bg-zinc-900 px-4 pt-5 pb-[calc(1rem+var(--inset-bottom,0px))] text-zinc-100"
      onclick={(e) => e.stopPropagation()}
      onkeydown={(e) => e.key === 'Escape' && (confirmingDelete = false)}
    >
      <p class="text-lg font-bold">{t('Delete “{name}”?', { name: info.name })}</p>
      <p class="mt-1 text-sm text-zinc-400">{t('The songs stay in your library.')}</p>
      <div class="mt-5 flex gap-3">
        <button type="button" class="flex-1 rounded-full bg-zinc-800 py-3 font-semibold active:bg-zinc-700" onclick={() => (confirmingDelete = false)}>
          {t('Cancel')}
        </button>
        <button type="button" class="flex-1 rounded-full bg-red-600 py-3 font-semibold text-white active:bg-red-500" onclick={() => void deletePlaylist()}>
          {t('Delete')}
        </button>
      </div>
    </div>
  </div>
{/if}

<script lang="ts">
  import { appSettings } from '../appSettings.svelte'
  import { count, t } from '../i18n.svelte'
  import { invoke } from '@tauri-apps/api/core'
  import ArtistLinks from '../ArtistLinks.svelte'
  import Cover from '../Cover.svelte'
  import Icon from '../Icon.svelte'
  import ActionsMenu from '../ActionsMenu.svelte'
  import AddToPlaylist from '../AddToPlaylist.svelte'
  import TintedBackdrop from '../TintedBackdrop.svelte'
  import TrackItem from './TrackItem.svelte'
  import StickyPlay from './StickyPlay.svelte'
  import { underTopBar } from './titleWatch'
  import { metadataMatch } from '../metadata.svelte'
  import { library, type AlbumRow, type TrackRow } from '../library.svelte'
  import type { Rgb } from '../nowCover.svelte'
  import { player, formatTime } from '../player.svelte'
  import { tintFrom } from '../tint'
  import { pinned } from '../pinned.svelte'

  let { albumId, onBack }: { albumId: number; onBack: () => void } = $props()

  let data = $state<{ album: AlbumRow; tracks: TrackRow[] } | null>(null)
  let color = $state<Rgb | null>(null)
  // The bar's title appears once the big title is under the bar.
  let titleHidden = $state(false)

  $effect(() => {
    void library.stats.version
    let stale = false
    invoke<{ album: AlbumRow; tracks: TrackRow[] }>('library_album', { albumId })
      .then((d) => {
        if (!stale) data = d
      })
      .catch((e) => (player.error = String(e)))
    return () => (stale = true)
  })

  $effect(() => {
    const cover = data?.album.cover ?? null
    color = null
    if (cover === null) return
    let stale = false
    invoke<Rgb | null>('library_cover_color', { cover })
      .then((c) => {
        if (!stale) color = c
      })
      .catch(() => {})
    return () => (stale = true)
  })
  const tint = $derived(tintFrom(color))

  const totalSeconds = $derived(
    data ? data.tracks.reduce((sum, t) => sum + (t.durationMs ?? 0), 0) / 1000 : 0,
  )
  // Started from this album and playing (like Spotify: its button pauses).
  const playingThis = $derived(player.isActiveFrom(`album:${albumId}`))

  async function shufflePlay() {
    if (!data || data.tracks.length === 0) return
    await player.setShuffle(true)
    await library.playAlbum(albumId, Math.floor(Math.random() * data.tracks.length))
  }

  async function changeCover() {
    const updated = await library.pickAlbumCoverFile(albumId)
    if (updated && data) data = { ...data, album: updated }
    if (updated) void pinned.refresh()
  }

  async function resetCover() {
    const updated = await library.clearAlbumCover(albumId)
    if (updated && data) data = { ...data, album: updated }
    if (updated) void pinned.refresh()
  }
</script>

<div class="absolute inset-0 flex flex-col bg-zinc-950">
  <!-- Back bar: the title fades in once the big title scrolled under it. -->
  <header class="absolute inset-x-0 top-0 z-10 flex h-14 items-center gap-1 px-1 transition-colors" class:bg-zinc-900={titleHidden}>
    <button class="rounded-full bg-black/30 p-2.5 text-white active:bg-black/50" aria-label={t("Back")} onclick={onBack}>
      <Icon name="back" class="size-6" />
    </button>
    {#if titleHidden && data}
      <h1 class="min-w-0 flex-1 truncate text-base font-semibold">{data.album.title}</h1>
    {/if}
  </header>

  <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
    {#if data}
      <div class="relative isolate overflow-hidden px-4 pt-16 pb-4">
        <TintedBackdrop background="linear-gradient(180deg, {tint.top} 0%, {tint.surface} 65%, var(--color-zinc-950) 100%)" />
        <div class="relative">
          <Cover cover={data.album.cover} title={data.album.title} class="mx-auto aspect-square w-3/5 max-w-64 rounded-md text-5xl shadow-2xl shadow-black/60" />
          <h2 class="mt-5 text-2xl leading-tight font-bold" {@attach underTopBar((hidden) => (titleHidden = hidden))}>{data.album.title}</h2>
          <p class="mt-1 text-sm font-medium text-zinc-200">
            <ArtistLinks artist={data.album.albumArtist} />
          </p>
          <p class="mt-1 text-xs text-zinc-400">
            {t('Album · {details}', {
              details: [data.album.year, count(data.album.trackCount, '{n} song', '{n} songs'), formatTime(totalSeconds)]
                .filter(Boolean)
                .join(' · '),
            })}
          </p>
        </div>
      </div>
      <StickyPlay
        top="44px"
        playing={playingThis}
        onclick={() => player.playOrToggle(`album:${albumId}`, () => library.playAlbum(albumId, 0))}
      />
      <div class="flex h-16 items-center gap-2 px-4 pb-2">
        <AddToPlaylist {albumId} label="Add album to playlist" class="p-2.5 text-zinc-300" />
        <button
          class={['rounded-full p-2.5 active:bg-white/10', pinned.isPinned('album', albumId) ? 'text-accent-400' : 'text-zinc-300']}
          aria-label={t(pinned.isPinned('album', albumId) ? 'Unpin' : 'Pin')}
          aria-pressed={pinned.isPinned('album', albumId)}
          onclick={() => void pinned.toggle('album', albumId)}
        >
          <Icon name="pin" class="size-6" />
        </button>
        {#if appSettings.allowMetadata}
          <button
            class="rounded-full px-3 py-2 text-sm font-medium text-zinc-300 active:bg-white/10"
            onclick={() => metadataMatch.openAlbum(albumId)}
          >
            {t("Find info")}
          </button>
        {/if}
        <ActionsMenu
          label={t('More actions for “{title}”', { title: data.album.title })}
          triggerClass="rounded-full p-2.5 text-zinc-300 outline-none active:bg-white/10"
          iconClass="size-6"
        >
          {#snippet children(close)}
            <button
              type="button"
              role="menuitem"
              class="flex w-full items-center gap-3 px-4 py-3 text-left outline-none active:bg-zinc-100 dark:active:bg-zinc-800"
              onclick={() => {
                close()
                void changeCover()
              }}
            >
              <Icon name="image" class="size-5 text-zinc-500" />
              {t('Choose cover…')}
            </button>
            {#if data?.album.cover !== null}
              <button
                type="button"
                role="menuitem"
                class="flex w-full items-center gap-3 px-4 py-3 text-left outline-none active:bg-zinc-100 dark:active:bg-zinc-800"
                onclick={() => {
                  close()
                  void resetCover()
                }}
              >
                <Icon name="refresh" class="size-5 text-zinc-500" />
                {t('Reset cover')}
              </button>
            {/if}
          {/snippet}
        </ActionsMenu>
        <span class="flex-1"></span>
        <button class="rounded-full p-3 text-zinc-300 active:bg-white/10" aria-label={t("Shuffle play")} onclick={shufflePlay}>
          <Icon name="shuffle" class="size-6" />
        </button>
        <span class="size-14 shrink-0" aria-hidden="true"></span>
      </div>
      {#each data.tracks as track, i (track.id)}
        <TrackItem
          title={track.title}
          subtitle={track.artist}
          path={track.path}
          trackId={track.id}
          {track}
          album=""
          number={track.trackNo ?? i + 1}
          onPlay={() => library.playAlbum(albumId, i)}
          selectScope={`m:album:${albumId}`}
          index={i}
        />
      {/each}
    {:else}
      <div class="mx-auto mt-24 aspect-square w-3/5 animate-pulse rounded-md bg-zinc-800"></div>
    {/if}
  </div>
</div>

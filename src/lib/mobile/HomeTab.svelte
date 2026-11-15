<script lang="ts">
  import Logo from '../Logo.svelte'
  import Cover from '../Cover.svelte'
  import EmptyLibrary from '../EmptyLibrary.svelte'
  import Icon from '../Icon.svelte'
  import PlaylistCover from '../PlaylistCover.svelte'
  import TrackItem from './TrackItem.svelte'
  import { count, t } from '../i18n.svelte'
  import { favorites } from '../favorites.svelte'
  import { greetingKey, home, mixSubtitle, mixTitle } from '../home.svelte'
  import { library } from '../library.svelte'
  import { pinned } from '../pinned.svelte'
  import { player } from '../player.svelte'
  import { playlists } from '../playlists.svelte'
  import { sync } from '../sync.svelte'

  let {
    onOpenAlbum,
    onOpenPlaylist,
    onOpenMix,
    onOpenFavorites,
    onOpenAlbums,
    onOpenSongs,
    onOpenStats,
    onOpenRemote,
  }: {
    onOpenAlbum: (albumId: number) => void
    onOpenPlaylist: (playlistId: number) => void
    onOpenMix: (mixId: string) => void
    onOpenFavorites: () => void
    onOpenAlbums: () => void
    onOpenSongs: () => void
    onOpenStats: () => void
    onOpenRemote: () => void
  } = $props()

  type HomeFilter = 'all' | 'mixes' | 'albums'
  let filter = $state<HomeFilter>('all')

  interface QuickTile {
    key: string
    kind: 'album' | 'playlist'
    id: number
    title: string
    cover: string | null
    albumCovers: string[]
  }

  const quickTiles = $derived.by<QuickTile[]>(() => {
    const feed = home.feed
    const tiles: QuickTile[] = []
    const seen = new Set<string>()
    for (const p of pinned.entries) {
      const key = `${p.kind}:${p.id}`
      seen.add(key)
      tiles.push({
        key,
        kind: p.kind,
        id: p.id,
        title: p.title,
        cover: p.cover,
        albumCovers: p.albumCovers,
      })
      if (tiles.length >= 7) return tiles
    }
    for (const pl of playlists.list) {
      const key = `playlist:${pl.id}`
      if (seen.has(key)) continue
      seen.add(key)
      tiles.push({
        key,
        kind: 'playlist',
        id: pl.id,
        title: pl.name,
        cover: pl.cover,
        albumCovers: pl.albumCovers,
      })
      if (tiles.length >= 7) return tiles
    }
    for (const a of feed?.recentlyPlayedAlbums.length
      ? feed.recentlyPlayedAlbums
      : (feed?.recentlyAddedAlbums ?? [])) {
      const key = `album:${a.id}`
      if (seen.has(key)) continue
      seen.add(key)
      tiles.push({
        key,
        kind: 'album',
        id: a.id,
        title: a.title,
        cover: a.cover,
        albumCovers: [],
      })
      if (tiles.length >= 7) break
    }
    return tiles
  })

  async function shuffleAll() {
    if (library.stats.tracks === 0) return
    await player.setShuffle(true)
    await library.playAll(Math.floor(Math.random() * library.stats.tracks))
  }
</script>

<!-- Remote control of the paired computer: only when one is paired; the dot
     says whether it is connected. -->
{#snippet remoteButton()}
  {#if sync.computer}
    <button
      type="button"
      class="relative shrink-0 rounded-full p-2 text-zinc-300 active:bg-white/10"
      aria-label={t('Remote control')}
      onclick={onOpenRemote}
    >
      <Icon name="computer" class="size-5" />
      <span
        class={[
          'absolute top-1.5 right-1.5 size-2 rounded-full ring-2 ring-zinc-950',
          sync.computer.connected ? 'bg-emerald-400' : 'bg-zinc-500',
        ]}
      ></span>
    </button>
  {/if}
{/snippet}

<div class="flex h-full flex-col">
  {#if library.stats.tracks === 0 && !home.feed?.hasHistory && (home.feed?.favoriteCount ?? 0) === 0}
    <header class="flex shrink-0 items-center justify-between gap-3 px-4 pt-4 pb-3">
      <h1 class="truncate text-2xl font-bold tracking-tight">{t('Home')}</h1>
      {@render remoteButton()}
    </header>
    <EmptyLibrary />
  {:else}
    {@const feed = home.feed}
    <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
      <!-- Sticky Spotify-style top bar with badge, filter chips & stats -->
      <header class="sticky top-0 z-10 flex items-center gap-2 bg-zinc-950/85 px-4 pt-3.5 pb-3 backdrop-blur-md">
        <span
          title={t(greetingKey())}
          class="flex size-8 shrink-0 items-center justify-center rounded-full bg-zinc-800 text-accent-400"
        >
          <Logo class="size-4" />
        </span>

        <div class="flex min-w-0 flex-1 items-center gap-2 overflow-x-auto no-scrollbar">
          {#each [
            { id: 'all', label: 'All' },
            { id: 'mixes', label: 'Mixes' },
            { id: 'albums', label: 'Albums' },
          ] as const as chip (chip.id)}
            <button
              type="button"
              class={[
                'shrink-0 rounded-full px-3.5 py-1.5 text-[13px] font-medium transition',
                filter === chip.id
                  ? 'bg-accent-500 font-semibold text-zinc-950'
                  : 'bg-zinc-800/90 text-zinc-100 active:bg-zinc-700',
              ]}
              onclick={() => (filter = chip.id)}
            >
              {t(chip.label)}
            </button>
          {/each}

          <button
            type="button"
            class="shrink-0 rounded-full bg-zinc-800/90 px-3.5 py-1.5 text-[13px] font-medium text-zinc-100 active:bg-zinc-700"
            onclick={onOpenSongs}
          >
            {t('Songs')}
          </button>

          <button
            type="button"
            class="flex shrink-0 items-center gap-1 rounded-full bg-zinc-800/90 px-3 py-1.5 text-[13px] font-medium text-zinc-100 active:bg-zinc-700"
            onclick={() => void shuffleAll()}
          >
            <Icon name="shuffle" class="size-3.5 text-accent-400" />
            {t('Shuffle')}
          </button>
        </div>

        {@render remoteButton()}
        <button
          type="button"
          class="-mr-1.5 shrink-0 rounded-full p-2 text-zinc-300 active:bg-white/10"
          aria-label={t('Listening stats')}
          onclick={onOpenStats}
        >
          <Icon name="chart" class="size-5" />
        </button>
      </header>

      <!-- 2x4 compact Spotify-style quick access grid -->
      <section class="grid grid-cols-2 gap-2 px-4 pt-0.5 pb-6" aria-label={t('Quick access')}>
        <button
          type="button"
          class="flex h-14 items-center gap-2.5 overflow-hidden rounded-md bg-zinc-900 text-left active:bg-zinc-800"
          onclick={onOpenFavorites}
        >
          <span class="flex size-14 shrink-0 items-center justify-center bg-gradient-to-br from-indigo-600 via-accent-500 to-accent-300 text-white">
            <Icon name="star" class="size-6" />
          </span>
          <span class="min-w-0 flex-1 pr-2">
            <span class="line-clamp-2 text-[13px] leading-tight font-semibold text-zinc-50">
              {t('Favorites')}
            </span>
          </span>
        </button>

        {#each quickTiles as tile (tile.key)}
          <button
            type="button"
            class="flex h-14 items-center gap-2.5 overflow-hidden rounded-md bg-zinc-900 text-left active:bg-zinc-800"
            onclick={() => (tile.kind === 'album' ? onOpenAlbum(tile.id) : onOpenPlaylist(tile.id))}
          >
            {#if tile.kind === 'album'}
              <Cover cover={tile.cover} title={tile.title} class="size-14 shrink-0 rounded-none text-base" />
            {:else}
              <PlaylistCover
                cover={tile.cover}
                albumCovers={tile.albumCovers}
                name={tile.title}
                class="size-14 shrink-0 rounded-none"
                iconClass="size-5"
              />
            {/if}
            <span class="line-clamp-2 min-w-0 flex-1 pr-2 text-[13px] leading-tight font-semibold text-zinc-50">
              {tile.title}
            </span>
          </button>
        {/each}
      </section>

      <!-- Dynamic Mixes -->
      {#if filter === 'all' || filter === 'mixes'}
        {#if feed && feed.mixes.length > 0}
          <section class="pb-6">
            <h2 class="px-4 pb-3 text-[19px] font-bold tracking-tight">{t('Daily Mixes')}</h2>
            <div class="flex gap-3.5 overflow-x-auto px-4 pb-1">
              {#each feed.mixes as mix (mix.id)}
                {@const title = mixTitle(mix)}
                <button
                  type="button"
                  class="w-[42vw] max-w-44 shrink-0 text-left active:opacity-75"
                  onclick={() => onOpenMix(mix.id)}
                >
                  <PlaylistCover
                    cover={null}
                    albumCovers={mix.albumCovers}
                    name={title}
                    class="aspect-square w-full rounded-lg shadow-lg shadow-black/40"
                    iconClass="size-12"
                  />
                  <span class="mt-2 block truncate text-[13px] font-semibold text-zinc-50">{title}</span>
                  <span class="mt-0.5 line-clamp-2 text-[11px] leading-snug text-zinc-400">
                    {mixSubtitle(mix)}
                  </span>
                </button>
              {/each}
            </div>
          </section>
        {:else if feed && !feed.hasHistory}
          <div class="mx-4 mb-6 rounded-xl border border-zinc-800 bg-zinc-900/70 px-4 py-3 text-xs leading-relaxed text-zinc-400">
            {t('Start playing some songs to unlock personalized mixes and recent history.')}
          </div>
        {/if}
      {/if}

      <!-- Recently Played Albums -->
      {#if (filter === 'all' || filter === 'albums') && feed && feed.recentlyPlayedAlbums.length > 0}
        <section class="pb-6">
          <div class="flex items-center justify-between px-4 pb-3">
            <h2 class="text-[19px] font-bold tracking-tight">{t('Recently played')}</h2>
            {#if filter === 'albums'}
              <button
                type="button"
                class="py-1 text-xs font-medium text-accent-400 active:opacity-70"
                onclick={onOpenAlbums}
              >
                {t('See all')}
              </button>
            {/if}
          </div>
          <div class="flex gap-3.5 overflow-x-auto px-4 pb-1">
            {#each feed.recentlyPlayedAlbums as album (album.id)}
              <button
                type="button"
                class="w-[42vw] max-w-44 shrink-0 text-left active:opacity-75"
                onclick={() => onOpenAlbum(album.id)}
              >
                <Cover
                  cover={album.cover}
                  title={album.title}
                  class="aspect-square w-full rounded-lg text-2xl shadow-md shadow-black/40"
                />
                <span class="mt-2 line-clamp-2 text-[13px] leading-snug font-semibold text-zinc-50">{album.title}</span>
                <span class="mt-0.5 block truncate text-xs text-zinc-400">{album.albumArtist}</span>
              </button>
            {/each}
          </div>
        </section>
      {/if}

      <!-- Recently Played Tracks -->
      {#if filter === 'all' && feed && feed.recentlyPlayedTracks.length > 0}
        <section class="pb-5">
          <h2 class="px-4 pb-1 text-[19px] font-bold tracking-tight">{t('Recently played tracks')}</h2>
          {#each feed.recentlyPlayedTracks.slice(0, 6) as item (item.track.id)}
            <TrackItem
              title={item.track.title}
              subtitle={[item.track.artist, item.track.album].filter(Boolean).join(' · ')}
              path={item.track.path}
              cover={item.track.cover}
              trackId={item.track.id}
              track={item.track}
              onPlay={() => void player.openFiles([item.track.path])}
            />
          {/each}
        </section>
      {/if}

      <!-- Favorites Preview -->
      {#if (filter === 'all' || filter === 'mixes') && feed && feed.favoriteTracks.length > 0}
        <section class="pb-5">
          <div class="flex items-center justify-between px-4 pb-1">
            <h2 class="text-[19px] font-bold tracking-tight">{t('Favorites')}</h2>
            <button
              type="button"
              class="py-1 text-xs font-medium text-accent-400 active:opacity-70"
              onclick={onOpenFavorites}
            >
              {t('See all')}
            </button>
          </div>
          {#each feed.favoriteTracks.slice(0, 4) as track, i (track.id)}
            <TrackItem
              title={track.title}
              subtitle={[track.artist, track.album].filter(Boolean).join(' · ')}
              path={track.path}
              cover={track.cover}
              trackId={track.id}
              {track}
              onPlay={() => void favorites.play(i)}
            />
          {/each}
        </section>
      {/if}

      <!-- Recently Added Albums -->
      {#if (filter === 'all' || filter === 'albums') && feed && feed.recentlyAddedAlbums.length > 0}
        <section class="pb-4">
          <div class="flex items-center justify-between px-4 pb-3">
            <h2 class="text-[19px] font-bold tracking-tight">{t('Recently added')}</h2>
            <button
              type="button"
              class="py-1 text-xs font-medium text-accent-400 active:opacity-70"
              onclick={onOpenAlbums}
            >
              {t('See all')}
            </button>
          </div>
          <div class="flex gap-3.5 overflow-x-auto px-4 pb-1">
            {#each feed.recentlyAddedAlbums as album (album.id)}
              <button
                type="button"
                class="w-[42vw] max-w-44 shrink-0 text-left active:opacity-75"
                onclick={() => onOpenAlbum(album.id)}
              >
                <Cover
                  cover={album.cover}
                  title={album.title}
                  class="aspect-square w-full rounded-lg text-2xl shadow-md shadow-black/40"
                />
                <span class="mt-2 line-clamp-2 text-[13px] leading-snug font-semibold text-zinc-50">{album.title}</span>
                <span class="mt-0.5 block truncate text-xs text-zinc-400">
                  {album.albumArtist}{album.year ? ` · ${album.year}` : ''}
                </span>
              </button>
            {/each}
          </div>
        </section>
      {/if}
    </div>
  {/if}
</div>

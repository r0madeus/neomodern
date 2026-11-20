<script lang="ts">
  import { count, t } from '../i18n.svelte'
  import { genreColor } from '../genreColor'
  import { appSettings } from '../appSettings.svelte'
  import { artists } from '../artists.svelte'
  import Cover from '../Cover.svelte'
  import Icon from '../Icon.svelte'
  import TrackDownloadButton from '../TrackDownloadButton.svelte'
  import PageHeader from './PageHeader.svelte'
  import TrackItem from './TrackItem.svelte'
  import { library, PagedRows, type GenreRow } from '../library.svelte'
  import {
    downloadProgress,
    isAlbumInLibrary,
    isTrackInLibrary,
    online,
    type OnlineAlbum,
  } from '../online.svelte'
  import { formatTime, player } from '../player.svelte'

  let {
    onOpenAlbum,
    onOpenOnlineAlbum,
    onOpenGenre,
  }: {
    onOpenAlbum: (albumId: number) => void
    onOpenOnlineAlbum: (album: OnlineAlbum) => void
    onOpenGenre: (name: string) => void
  } = $props()

  // "Browse all": the genre cards shown while the search box is empty.
  let genres = $state<GenreRow[]>([])
  $effect(() => {
    void library.stats.version
    let live = true
    library
      .genres()
      .then((g) => {
        if (live) genres = g
      })
      .catch(() => {})
    return () => {
      live = false
    }
  })

  const q = $derived(library.debouncedQuery)
  const trimmedQuery = $derived(library.query.trim())
  const onlineEnabled = $derived(appSettings.allowOnline)
  const ytdlpAvailable = $derived(online.status?.ytdlpAvailable ?? false)
  const hasCurrentOnline = $derived(
    trimmedQuery !== '' && online.searchedQuery === trimmedQuery && online.results !== null,
  )

  let localSongLimit = $state(30)
  $effect(() => {
    void q
    localSongLimit = 30
  })

  const songs = $derived.by(() => {
    void library.stats.version
    return new PagedRows(library.tracksPage(library.sort, q))
  })
  const albums = $derived.by(() => {
    void library.stats.version
    return new PagedRows(library.albumsPage(q))
  })
  const matchingArtists = $derived.by(() => {
    void library.stats.version
    return new PagedRows(artists.page(q))
  })
  $effect(() => {
    const s = songs
    const a = albums
    const ar = matchingArtists
    if (q !== '') {
      s.ensureRange(0, localSongLimit)
      a.ensureRange(0, 12)
      ar.ensureRange(0, 12)
    }
    return () => {
      s.dispose()
      a.dispose()
      ar.dispose()
    }
  })

  const albumList = $derived(
    Array.from({ length: Math.min(12, albums.total ?? 0) }, (_, i) => albums.get(i)).filter((a) => a !== undefined),
  )
  const artistList = $derived(
    Array.from({ length: Math.min(12, matchingArtists.total ?? 0) }, (_, i) => matchingArtists.get(i)).filter((a) => a !== undefined),
  )
  const songList = $derived(
    Array.from({ length: Math.min(localSongLimit, songs.total ?? 0) }, (_, i) => songs.get(i)).filter((s) => s !== undefined),
  )

  function submitSearch(e: SubmitEvent) {
    e.preventDefault()
    if (!onlineEnabled || trimmedQuery === '') return
    void online.search(library.query)
  }

  function clearSearch() {
    library.setQuery('')
    online.clearSearch()
  }

  function openOnlineAlbum(album: OnlineAlbum) {
    void online.openAlbum(album)
    onOpenOnlineAlbum(album)
  }
</script>

<div class="flex h-full flex-col">
  <PageHeader title={t("Search")} />
  <div class="shrink-0 px-4 pb-3">
    <form class="flex items-center gap-2" onsubmit={submitSearch}>
      <label class="flex min-w-0 flex-1 items-center gap-3 rounded-lg bg-zinc-100 px-3 py-2.5 text-zinc-900">
        <Icon name="search" class="size-5 shrink-0 text-zinc-600" />
        <input
          class="min-w-0 flex-1 bg-transparent text-[15px] outline-none placeholder:text-zinc-500"
          placeholder={onlineEnabled ? t("Songs, artists, albums or online") : t("Songs, artists or albums")}
          value={library.query}
          oninput={(e) => library.setQuery(e.currentTarget.value)}
          enterkeyhint="search"
          autocomplete="off"
        />
        {#if library.query !== ''}
          <button type="button" class="-m-1 p-1 text-zinc-600" aria-label={t("Clear search")} onclick={clearSearch}>
            <Icon name="close" class="size-5" />
          </button>
        {/if}
      </label>
      {#if onlineEnabled && trimmedQuery !== ''}
        <button
          type="submit"
          disabled={online.searching}
          class="shrink-0 rounded-lg bg-accent-500 px-3.5 py-2.5 text-sm font-semibold text-zinc-950 active:opacity-80 disabled:opacity-50"
        >
          {online.searching ? t("Searching…") : t("Online")}
        </button>
      {/if}
    </form>
    {#if online.error}
      <button
        type="button"
        class="mt-2 w-full rounded-lg bg-red-950/70 px-3 py-2 text-left text-xs text-red-200"
        onclick={() => (online.error = null)}
      >
        {online.error}
      </button>
    {/if}
  </div>

  <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
    {#if online.downloads.length > 0}
      <section aria-label={t("Downloads")} class="mx-4 mb-4 rounded-xl border border-zinc-800 bg-zinc-900/70 p-3">
        <div class="mb-2 flex items-center justify-between gap-2">
          <div class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-zinc-400">
            <Icon
              name="download"
              class={online.activeDownloadCount > 0 ? 'size-3.5 animate-pulse text-accent-400' : 'size-3.5'}
            />
            <span>{t("Downloads")}</span>
            {#if online.activeDownloadCount > 0}
              <span class="rounded-full bg-accent-500/20 px-1.5 py-0.5 text-[10px] font-medium normal-case text-accent-300">
                {online.activeDownloadCount}
              </span>
            {/if}
          </div>
          {#if online.hasFinishedDownloads}
            <button
              type="button"
              class="text-xs text-zinc-400 active:text-zinc-200"
              onclick={() => void online.clearFinished()}
            >
              {t("Clear finished")}
            </button>
          {/if}
        </div>
        <ul class="flex flex-col gap-2">
          {#each online.downloads as job (job.id)}
            {@const active = job.state === 'queued' || job.state === 'downloading'}
            <li class="flex flex-col gap-1 rounded-lg bg-zinc-950/70 px-2.5 py-2 text-xs">
              <div class="flex items-center justify-between gap-2">
                <div class="min-w-0 flex-1">
                  <p class="truncate font-medium text-zinc-100">{job.title}</p>
                  {#if job.state === 'downloading' && job.currentTrack && job.currentTrack !== job.title}
                    <p class="truncate text-[11px] text-zinc-400">{job.currentTrack}</p>
                  {:else if job.state === 'failed' && job.error}
                    <p class="truncate text-[11px] text-red-400">{job.error}</p>
                  {/if}
                </div>
                <div class="flex shrink-0 items-center gap-1.5">
                  <span
                    class={[
                      'text-[11px] font-medium tabular-nums',
                      job.state === 'done'
                        ? 'text-accent-400'
                        : job.state === 'failed'
                          ? 'text-red-400'
                          : 'text-zinc-400',
                    ]}
                  >
                    {#if job.state === 'done'}
                      {t("Done")}
                    {:else if job.state === 'failed'}
                      {t("Failed")}
                    {:else if job.state === 'cancelled'}
                      {t("Cancelled")}
                    {:else if job.state === 'queued'}
                      {t("Queued")}
                    {:else}
                      {job.doneTracks}/{job.totalTracks}
                    {/if}
                  </span>
                  {#if active}
                    <button
                      type="button"
                      class="rounded-full p-1 text-zinc-400 active:bg-zinc-800"
                      aria-label={t("Cancel download")}
                      onclick={() => void online.cancelDownload(job.id)}
                    >
                      <Icon name="close" class="size-3.5" />
                    </button>
                  {/if}
                </div>
              </div>
              {#if active}
                <div class="h-1 w-full overflow-hidden rounded-full bg-zinc-800">
                  <div
                    class="h-full rounded-full bg-accent-500 transition-[width]"
                    style:width="{downloadProgress(job)}%"
                  ></div>
                </div>
              {/if}
            </li>
          {/each}
        </ul>
      </section>
    {/if}

    {#if q === '' && !online.searching && !hasCurrentOnline}
      {#if genres.length > 0}
        <h2 class="px-4 pb-3 text-lg font-bold tracking-tight">{t('Browse all')}</h2>
        <div class="grid grid-cols-2 gap-3 px-4 pb-6">
          {#each genres as g (g.name)}
            <button
              type="button"
              style="background-color: {genreColor(g.name)}"
              class="relative flex h-24 flex-col items-start overflow-hidden rounded-lg p-3 text-left text-white shadow-sm active:brightness-90"
              onclick={() => onOpenGenre(g.name)}
            >
              <div class="relative z-10 min-w-0 pr-10">
                <p class="line-clamp-2 text-[15px] leading-snug font-bold drop-shadow-sm">{g.name}</p>
                <p class="mt-0.5 text-[11px] text-white/80">{count(g.trackCount, '{n} track', '{n} tracks')}</p>
              </div>
              {#if g.cover}
                <Cover
                  cover={g.cover}
                  title={g.name}
                  class="pointer-events-none absolute -right-3 -bottom-2 size-16 rotate-[24deg] rounded-md shadow-xl shadow-black/45"
                />
              {/if}
            </button>
          {/each}
        </div>
      {:else}
        <div class="flex min-h-64 flex-col items-center justify-center gap-2 px-10 text-center">
          <p class="text-lg font-semibold">{t("Search your library")}</p>
          <p class="text-sm text-zinc-400">
            {onlineEnabled
              ? t("Find local songs, artists and albums, or press Enter to search online (Experimental).")
              : t("Find songs, artists and albums by name.")}
          </p>
        </div>
      {/if}
    {:else}
      {#if q !== ''}
        {#if artistList.length > 0}
          <h2 class="px-4 pb-2 text-lg font-bold">{t("Artists")}</h2>
          <div class="flex gap-3 overflow-x-auto px-4 pb-4">
            {#each artistList as ar (ar.name)}
              <button type="button" class="w-24 shrink-0 text-center active:opacity-70" onclick={() => artists.open(ar.name)}>
                <Cover cover={ar.cover} title={ar.name} class="aspect-square w-full rounded-full text-2xl" />
                <span class="mt-1.5 block truncate text-[13px] font-medium">{ar.name}</span>
              </button>
            {/each}
          </div>
        {/if}
        {#if albumList.length > 0}
          <h2 class="px-4 pb-2 text-lg font-bold">{t("Albums")}</h2>
          <div class="flex gap-3 overflow-x-auto px-4 pb-4">
            {#each albumList as a (a.id)}
              <button type="button" class="w-28 shrink-0 text-left active:opacity-70" onclick={() => onOpenAlbum(a.id)}>
                <Cover cover={a.cover} title={a.title} class="aspect-square w-full rounded-md text-2xl" />
                <span class="mt-1.5 block truncate text-[13px] font-medium">{a.title}</span>
                <span class="block truncate text-xs text-zinc-400">{a.albumArtist}</span>
              </button>
            {/each}
          </div>
        {/if}
        {#if songList.length > 0}
          <h2 class="px-4 pb-1 text-lg font-bold">{t("Songs")}</h2>
          <div class="pb-4">
            {#each songList as track, i (track.id)}
              <TrackItem
                title={track.title}
                subtitle={[track.artist, track.album].filter(Boolean).join(' · ')}
                path={track.path}
                cover={track.cover}
                trackId={track.id}
                {track}
                onPlay={() => library.playAll(i)}
              />
            {/each}
            {#if (songs.total ?? 0) > songList.length}
              <button
                type="button"
                class="mx-4 mt-2 rounded-lg border border-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-300 active:bg-zinc-800"
                onclick={() => (localSongLimit += 50)}
              >
                {t("Show more")}
              </button>
            {/if}
          </div>
        {:else if !onlineEnabled && songs.total === 0 && albums.total === 0 && matchingArtists.total === 0}
          <div class="flex min-h-48 flex-col items-center justify-center gap-2 px-10 text-center">
            <p class="text-lg font-semibold">{t('No results for “{q}”', { q })}</p>
            <p class="text-sm text-zinc-400">{t("Check the spelling or try fewer words.")}</p>
          </div>
        {/if}
      {/if}

      {#if onlineEnabled && trimmedQuery !== ''}
        <section aria-label={t("Online")} class="px-4 pt-2 pb-6">
          <div class="mb-3 flex items-center gap-2">
            <h2 class="text-lg font-bold">{t("Online")}</h2>
            <span class="rounded-full bg-amber-500/15 px-2 py-0.5 text-[11px] font-semibold text-amber-400">
              {t("Experimental")}
            </span>
          </div>

          {#if online.searching}
            <p class="text-sm text-zinc-400">{t("Searching online…")}</p>
          {:else if online.searchError && online.searchedQuery === trimmedQuery}
            <div class="flex items-center gap-3 rounded-xl border border-red-900/60 bg-red-950/40 px-3.5 py-2.5 text-sm text-red-200">
              <span class="min-w-0 flex-1">{online.searchError}</span>
              <button
                type="button"
                class="shrink-0 rounded-lg bg-red-600 px-3 py-1 text-xs font-medium text-white"
                onclick={() => void online.search(library.query)}
              >
                {t("Retry")}
              </button>
            </div>
          {:else if hasCurrentOnline && online.results}
            {#if online.results.albums.length === 0 && online.results.tracks.length === 0}
              <p class="text-sm text-zinc-400">{t('No online results for “{q}”.', { q: trimmedQuery })}</p>
            {:else}
              {#if online.results.albums.length > 0}
                <h3 class="pb-2 text-xs font-semibold uppercase tracking-wider text-zinc-400">{t("Albums")}</h3>
                <div class="-mx-4 flex gap-3 overflow-x-auto px-4 pb-4">
                  {#each online.results.albums as album (album.id)}
                    {@const inLib = isAlbumInLibrary(album, albumList)}
                    <button
                      type="button"
                      class="w-28 shrink-0 text-left active:opacity-70"
                      onclick={() => openOnlineAlbum(album)}
                    >
                      <Cover
                        cover={album.cover ?? album.coverUrl}
                        title={album.title}
                        class="aspect-square w-full rounded-md text-2xl"
                      />
                      <span class="mt-1.5 block truncate text-[13px] font-medium">{album.title}</span>
                      <span class="block truncate text-xs text-zinc-400">
                        {album.artist}{album.year ? ` · ${album.year}` : ''}
                      </span>
                      {#if inLib}
                        <span class="mt-1 inline-block rounded-full bg-accent-500/20 px-2 py-0.5 text-[10px] font-medium text-accent-300">
                          {t("In library")}
                        </span>
                      {/if}
                    </button>
                  {/each}
                </div>
              {/if}

              {#if online.results.tracks.length > 0}
                {@const onlineTracks = online.results.tracks}
                <h3 class="pb-1 text-xs font-semibold uppercase tracking-wider text-zinc-400">{t("Songs")}</h3>
                <ol class="divide-y divide-zinc-800/70">
                  {#each onlineTracks as track, i (track.id)}
                    {@const job = online.jobFor('track', track.title, track.artist)}
                    {@const inLib = isTrackInLibrary(track, songList)}
                    {@const isCurrent =
                      online.playingId === track.id ||
                      (player.snapshot.current?.title === track.title &&
                        player.snapshot.current?.path.startsWith('http'))}
                    <li class="flex items-center gap-2 py-1">
                      <button
                        type="button"
                        disabled={!ytdlpAvailable || online.playingId !== null}
                        class={[
                          'flex min-w-0 flex-1 items-center gap-3 rounded-lg py-1.5 pr-2 text-left disabled:opacity-60 active:opacity-75',
                          isCurrent ? 'text-accent-400' : 'text-zinc-100',
                        ]}
                        onclick={() => void online.playTracks(onlineTracks, i)}
                      >
                        <Cover
                          cover={track.cover ?? track.coverUrl}
                          title={track.title}
                          class="size-11 shrink-0 rounded text-sm"
                        />
                        <div class="min-w-0 flex-1">
                          <p class="truncate text-sm font-medium">{track.title}</p>
                          <p class="truncate text-xs text-zinc-400">
                            {track.artist}{track.album ? ` · ${track.album}` : ''}
                          </p>
                        </div>
                        {#if online.playingId === track.id}
                          <span class="shrink-0 text-xs text-accent-400">{t("Loading…")}</span>
                        {:else if inLib && job?.state !== 'done'}
                          <span class="shrink-0 rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] font-medium text-zinc-300">
                            {t("In library")}
                          </span>
                        {/if}
                        <span class="shrink-0 text-xs tabular-nums text-zinc-400">
                          {formatTime(track.durationSeconds)}
                        </span>
                      </button>
                      <TrackDownloadButton {track} {job} disabled={!ytdlpAvailable} />
                    </li>
                  {/each}
                </ol>
              {/if}
            {/if}
          {:else}
            <div class="flex items-center justify-between gap-3 rounded-xl border border-zinc-800 bg-zinc-900/60 px-3.5 py-2.5 text-sm text-zinc-300">
              <span class="min-w-0 truncate">{t('Search online for “{q}”', { q: trimmedQuery })}</span>
              <button
                type="button"
                class="shrink-0 rounded-full bg-accent-500/20 px-3.5 py-1.5 text-xs font-semibold text-accent-300 active:bg-accent-500/30"
                onclick={() => void online.search(library.query)}
              >
                {t("Search online")}
              </button>
            </div>
          {/if}
        </section>
      {/if}
    {/if}
  </div>
</div>

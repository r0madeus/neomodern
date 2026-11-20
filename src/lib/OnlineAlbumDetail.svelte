<script lang="ts">
  import { invoke } from '@tauri-apps/api/core'
  import Cover from './Cover.svelte'
  import Icon from './Icon.svelte'
  import TintedBackdrop from './TintedBackdrop.svelte'
  import TrackDownloadButton from './TrackDownloadButton.svelte'
  import { count, t } from './i18n.svelte'
  import { library, type AlbumRow, type TrackRow } from './library.svelte'
  import type { Rgb } from './nowCover.svelte'
  import {
    isAlbumInLibrary,
    isTrackInLibrary,
    online,
    type OnlineAlbum,
    type OnlineTrack,
  } from './online.svelte'
  import { formatTime, player } from './player.svelte'
  import { tintFrom } from './tint'
  import StickyPlay from './mobile/StickyPlay.svelte'
  import { underTopBar } from './mobile/titleWatch'

  // `mobile`: the phone's full-screen album page (Spotify layout with its own
  // top bar and sticky play button); otherwise the desktop panel.
  let { album, onBack, mobile = false }: { album: OnlineAlbum; onBack: () => void; mobile?: boolean } = $props()


  const activeAlbum = $derived(online.albumDetail?.album ?? album)
  const tracks = $derived(online.albumDetail?.tracks ?? [])
  let titleHidden = $state(false)
  const playingHere = $derived(
    online.playingId !== null && tracks.some((tr) => tr.id === online.playingId),
  )
  const ytdlpAvailable = $derived(online.status?.ytdlpAvailable ?? false)
  const albumJob = $derived(online.jobFor('album', activeAlbum.title, activeAlbum.artist))

  let localAlbums = $state<AlbumRow[]>([])
  let localTracks = $state<TrackRow[]>([])
  $effect(() => {
    void library.stats.version
    const title = activeAlbum.title.trim()
    if (!title) {
      localAlbums = []
      localTracks = []
      return
    }
    let stale = false
    Promise.all([
      library.albumsPage(title)(0, 20),
      library.tracksPage('title', title)(0, 200),
    ])
      .then(([albs, trs]) => {
        if (stale) return
        localAlbums = albs.items
        localTracks = trs.items
      })
      .catch(() => {})
    return () => {
      stale = true
    }
  })

  const albumInLibrary = $derived(isAlbumInLibrary(activeAlbum, localAlbums))

  // Tint the Spotify-style album hero using the locally cached cover image.
  let color = $state<Rgb | null>(null)
  $effect(() => {
    const cover = activeAlbum.cover
    color = null
    if (!cover || cover.startsWith('http://') || cover.startsWith('https://')) return
    let stale = false
    invoke<Rgb | null>('library_cover_color', { cover })
      .then((c) => {
        if (!stale) color = c
      })
      .catch(() => {})
    return () => {
      stale = true
    }
  })
  const tint = $derived(tintFrom(color))

  function trackJob(track: OnlineTrack) {
    return online.jobFor('track', track.title, track.artist)
  }

  function isAlbumBusy(): boolean {
    return albumJob?.state === 'queued' || albumJob?.state === 'downloading'
  }

  const albumDownloadLabel = $derived.by(() => {
    if (albumJob?.state === 'done') return t('Downloaded')
    if (albumJob?.state === 'downloading') {
      return t('Downloading {done}/{total}', {
        done: albumJob.doneTracks,
        total: albumJob.totalTracks,
      })
    }
    if (albumJob?.state === 'queued') return t('Queued')
    return t('Download album')
  })
</script>

{#if mobile}
  <div class="absolute inset-0 flex flex-col bg-zinc-950">
    <header class="absolute inset-x-0 top-0 z-10 flex h-14 items-center gap-2 pr-4 pl-2 transition-colors" class:bg-zinc-900={titleHidden}>
      <button class="rounded-full bg-black/30 p-2.5 text-white active:bg-black/50" aria-label={t('Back')} onclick={onBack}>
        <Icon name="back" class="size-6" />
      </button>
      <h1 class={['min-w-0 flex-1 truncate pr-14 text-base font-semibold transition-opacity', !titleHidden && 'opacity-0']}>
        {activeAlbum.title}
      </h1>
    </header>
    <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
      <div class="relative isolate overflow-hidden px-4 pt-16 pb-3">
        <TintedBackdrop background="linear-gradient(180deg, {tint.top} 0%, {tint.surface} 60%, var(--color-zinc-950) 100%)" />
        <Cover
          cover={activeAlbum.cover ?? activeAlbum.coverUrl}
          title={activeAlbum.title}
          class="mx-auto aspect-square w-[62%] max-w-72 rounded-sm text-5xl shadow-2xl shadow-black/60"
        />
        <h2 class="mt-6 text-[1.7rem] leading-tight font-bold tracking-tight" {@attach underTopBar((hidden) => (titleHidden = hidden))}>
          {activeAlbum.title}
        </h2>
        {#if activeAlbum.artist}
          <p class="mt-2.5 flex min-w-0 items-center gap-2 text-sm font-bold text-zinc-50">
            <Cover cover={null} title={activeAlbum.artist} class="size-6 shrink-0 rounded-full text-[10px]" />
            <span class="truncate">{activeAlbum.artist}</span>
          </p>
        {/if}
        <p class="mt-2 text-[13px] text-zinc-400">
          {[t('Album'), activeAlbum.year, count(tracks.length || activeAlbum.trackCount, '{n} song', '{n} songs')]
            .filter(Boolean)
            .join(' • ')}
        </p>
      </div>
      <StickyPlay
        playing={false}
        disabled={!ytdlpAvailable || tracks.length === 0 || online.playingId !== null}
        onclick={() => void online.playTracks(tracks, 0)}
      />
      <div class="flex h-16 items-center gap-2 px-2.5 pb-2">
        <button
          type="button"
          disabled={!ytdlpAvailable || tracks.length === 0 || isAlbumBusy()}
          title={albumDownloadLabel}
          aria-label={albumDownloadLabel}
          class={['rounded-full p-2.5 active:bg-white/10 disabled:opacity-40', albumJob?.state === 'done' ? 'text-accent-400' : 'text-zinc-300']}
          onclick={() => void online.downloadAlbum(activeAlbum, tracks)}
        >
          {#if albumJob?.state === 'done'}
            <Icon name="checkCircle" class="size-6" />
          {:else}
            <Icon name="download" class={albumJob?.state === 'downloading' ? 'size-6 animate-pulse' : 'size-6'} />
          {/if}
        </button>
        {#if albumJob?.state === 'downloading' || albumJob?.state === 'queued'}
          <span class="truncate text-xs text-zinc-400">{albumDownloadLabel}</span>
        {:else if albumInLibrary}
          <span class="truncate rounded-full border border-zinc-600 px-3 py-1 text-xs font-semibold text-zinc-200">{t('In library')}</span>
        {/if}
        <span class="flex-1"></span>
        {#if playingHere}
          <span class="text-xs text-accent-400">{t('Loading…')}</span>
        {/if}
        <span class="mr-1.5 size-14 shrink-0" aria-hidden="true"></span>
      </div>

      {#if online.loadingAlbum && tracks.length === 0}
        <p class="px-4 text-sm text-zinc-400">{t('Loading…')}</p>
      {:else if online.albumError}
        <div class="mx-4 flex items-center gap-3 rounded-xl bg-red-950/40 px-4 py-3 text-sm text-red-300">
          <span class="min-w-0 flex-1">{online.albumError}</span>
          <button type="button" class="rounded-full bg-red-600 px-3 py-1 text-xs font-medium text-white" onclick={() => void online.openAlbum(album)}>
            {t('Retry')}
          </button>
        </div>
      {:else if tracks.length === 0}
        <p class="px-4 text-sm text-zinc-400">{t('No tracks found for this album.')}</p>
      {:else}
        <ol>
          {#each tracks as track, i (track.id)}
            {@const job = trackJob(track)}
            {@const isCurrent =
              online.playingId === track.id ||
              (player.snapshot.current?.title === track.title && player.snapshot.current?.path.startsWith('http'))}
            <li class="flex h-16 items-center gap-1 pr-1 pl-4 active:bg-white/5">
              <button
                type="button"
                disabled={!ytdlpAvailable || online.playingId !== null}
                class="flex min-w-0 flex-1 flex-col justify-center text-left disabled:opacity-60"
                onclick={() => void online.playTracks(tracks, i)}
              >
                <span class={['truncate text-[15px] leading-tight', isCurrent ? 'text-accent-400' : 'text-zinc-50']}>{track.title}</span>
                <span class="mt-1 truncate text-[13px] leading-tight text-zinc-400">
                  {online.playingId === track.id ? t('Loading…') : track.artist || activeAlbum.artist}
                </span>
              </button>
              <TrackDownloadButton {track} {job} disabled={!ytdlpAvailable} />
            </li>
          {/each}
        </ol>
      {/if}
    </div>
  </div>
{:else}
<div class="h-full overflow-y-auto px-5 pb-6">
  <button
    type="button"
    class="mb-4 rounded-lg px-2 py-1 text-sm text-zinc-600 hover:bg-zinc-200/70 dark:text-zinc-300 dark:hover:bg-zinc-800"
    onclick={onBack}
  >
    {t('← Search')}
  </button>

  <div
    class="relative isolate mb-6 flex flex-col gap-4 overflow-hidden rounded-2xl p-4 text-white sm:flex-row sm:items-end sm:gap-6 sm:p-6"
  >
    <TintedBackdrop background="linear-gradient(135deg, {tint.top}, {tint.surface})" />
    <Cover
      cover={activeAlbum.cover ?? activeAlbum.coverUrl}
      title={activeAlbum.title}
      class="size-32 shrink-0 self-center rounded-lg text-5xl shadow-2xl shadow-black/40 sm:size-48 sm:self-auto sm:text-6xl"
    />
    <div class="min-w-0">
      <p class="text-xs font-semibold tracking-widest text-white/70 uppercase">{t('Album')}</p>
      <h2 class="mt-1 truncate pb-1 text-2xl leading-tight font-bold tracking-tight sm:text-4xl">{activeAlbum.title}</h2>
      <p class="mt-2 truncate font-medium text-white/90">{activeAlbum.artist}</p>
      <p class="mt-1 text-sm text-white/60">
        {activeAlbum.year ? `${activeAlbum.year} · ` : ''}{count(
          tracks.length || activeAlbum.trackCount,
          '{n} track',
          '{n} tracks',
        )}
      </p>
      <div class="mt-4 flex flex-wrap items-center gap-2">
        <button
          type="button"
          disabled={!ytdlpAvailable || tracks.length === 0 || online.playingId !== null}
          class="flex items-center gap-2 rounded-full bg-accent-500 py-2 pr-5 pl-4 text-sm font-semibold text-zinc-950 hover:scale-[1.03] hover:bg-accent-400 disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:scale-100"
          onclick={() => {
            void online.playTracks(tracks, 0)
          }}
        >
          <Icon name="play" class="size-5" />
          {online.playingId && tracks.some((tr) => tr.id === online.playingId)
            ? t('Loading…')
            : t('Play')}
        </button>

        <button
          type="button"
          disabled={!ytdlpAvailable || tracks.length === 0 || isAlbumBusy()}
          title={albumDownloadLabel}
          aria-label={albumDownloadLabel}
          class={[
            'flex size-10 shrink-0 items-center justify-center rounded-full border transition disabled:cursor-not-allowed disabled:opacity-50',
            albumJob?.state === 'done'
              ? 'border-accent-400/50 bg-accent-500/20 text-accent-300'
              : 'border-white/25 bg-white/10 text-white hover:bg-white/20',
          ]}
          onclick={() => void online.downloadAlbum(activeAlbum, tracks)}
        >
          {#if albumJob?.state === 'done'}
            <Icon name="check" class="size-5" />
          {:else if albumJob?.state === 'downloading'}
            <Icon name="download" class="size-5 animate-pulse" />
          {:else}
            <Icon name="download" class="size-5" />
          {/if}
        </button>

        {#if albumInLibrary && albumJob?.state !== 'done'}
          <span class="rounded-full bg-white/15 px-3 py-1 text-xs font-medium text-white/90">
            {t('In library')}
          </span>
        {/if}
      </div>
    </div>
  </div>

  {#if online.loadingAlbum && tracks.length === 0}
    <p class="text-sm text-zinc-500">{t('Loading…')}</p>
  {:else if online.albumError}
    <div class="flex items-center gap-3 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-300">
      <span class="min-w-0 flex-1">{online.albumError}</span>
      <button
        type="button"
        class="rounded-lg bg-red-600 px-3 py-1 text-xs font-medium text-white hover:bg-red-500"
        onclick={() => void online.openAlbum(album)}
      >
        {t('Retry')}
      </button>
    </div>
  {:else if tracks.length === 0}
    <p class="text-sm text-zinc-500">{t('No tracks found for this album.')}</p>
  {:else}
    <ol class="divide-y divide-zinc-100 dark:divide-zinc-800/70">
      {#each tracks as track, i (track.id)}
        {@const job = trackJob(track)}
        {@const inLib = isTrackInLibrary(track, localTracks)}
        {@const isCurrent =
          online.playingId === track.id ||
          (player.snapshot.current?.title === track.title &&
            player.snapshot.current?.path.startsWith('http'))}
        <li class="group flex items-center gap-2">
          <button
            type="button"
            disabled={!ytdlpAvailable || online.playingId !== null}
            class={[
              'flex h-11 min-w-0 flex-1 items-center gap-3 rounded-lg px-3 text-left text-sm disabled:cursor-not-allowed disabled:opacity-60',
              isCurrent
                ? 'bg-accent-50 text-accent-900 dark:bg-accent-950/40 dark:text-accent-100'
                : 'text-zinc-700 hover:bg-zinc-100/70 dark:text-zinc-300 dark:hover:bg-zinc-800/50',
            ]}
            onclick={() => void online.playTracks(tracks, i)}
          >
            <span class="w-7 text-right text-xs tabular-nums text-zinc-400">
              {track.trackNo ?? i + 1}
            </span>
            <div class="min-w-0 flex-1">
              <p class="truncate font-medium">{track.title}</p>
              {#if track.artist && track.artist !== activeAlbum.artist}
                <p class="truncate text-xs text-zinc-500">{track.artist}</p>
              {/if}
            </div>
            {#if online.playingId === track.id}
              <span class="text-xs text-accent-600 dark:text-accent-400">{t('Loading…')}</span>
            {:else if inLib && job?.state !== 'done'}
              <span class="rounded-full bg-zinc-200/80 px-2 py-0.5 text-[11px] font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                {t('In library')}
              </span>
            {/if}
            <span class="text-xs tabular-nums text-zinc-500">
              {formatTime(track.durationSeconds)}
            </span>
          </button>

          <TrackDownloadButton {track} {job} disabled={!ytdlpAvailable} />
        </li>
      {/each}
    </ol>
  {/if}
</div>
{/if}

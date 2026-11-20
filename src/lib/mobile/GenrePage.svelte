<script lang="ts">
  import { count, i18n, t } from '../i18n.svelte'
  import Cover from '../Cover.svelte'
  import Icon from '../Icon.svelte'
  import TintedBackdrop from '../TintedBackdrop.svelte'
  import StickyPlay from './StickyPlay.svelte'
  import TrackItem from './TrackItem.svelte'
  import { underTopBar } from './titleWatch'
  import { genreColor } from '../genreColor'
  import { library, type GenreDetail, type TrackRow } from '../library.svelte'
  import { player, randomTrackIndex } from '../player.svelte'

  // A genre on phones (from the Search tab's "Browse all"): Spotify layout
  // like the album and playlist pages. Tracks come in pages as the list
  // scrolls, so a genre with thousands of songs never goes over IPC at once.
  let { name, onBack, onOpenAlbum }: { name: string; onBack: () => void; onOpenAlbum: (albumId: number) => void } =
    $props()

  const TRACK_PAGE = 100

  let detail = $state<GenreDetail | null>(null)
  let tracks = $state<TrackRow[]>([])
  let loadingMore = $state(false)
  let sentinel = $state<HTMLElement | null>(null)
  let titleHidden = $state(false)
  /** Bumped on every reload so late pages of an old load are dropped. */
  let generation = 0

  $effect(() => {
    void library.stats.version
    const wanted = name
    const gen = ++generation
    tracks = []
    loadingMore = false
    library
      .genreDetail(wanted)
      .then((res) => {
        if (gen !== generation) return
        detail = res
        void loadMore()
      })
      .catch((e) => {
        if (gen === generation) player.error = String(e)
      })
  })

  async function loadMore(): Promise<void> {
    const d = detail
    if (!d || loadingMore || tracks.length >= d.trackCount) return
    const gen = generation
    loadingMore = true
    try {
      const page = await library.genreTracksPage(d.name, tracks.length, TRACK_PAGE)
      if (gen !== generation) return
      tracks = [...tracks, ...page.items]
      // The library can shrink while scrolling; stop at what is there.
      if (page.items.length === 0 && detail) detail.trackCount = tracks.length
    } catch (e) {
      player.error = String(e)
    } finally {
      if (gen === generation) loadingMore = false
    }
  }

  // The next page loads when the end of the list comes near the viewport,
  // and again while a page left it still in view.
  $effect(() => {
    const el = sentinel
    if (!el) return
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) void loadMore()
      },
      { rootMargin: '600px 0px' },
    )
    io.observe(el)
    return () => io.disconnect()
  })
  $effect(() => {
    void tracks.length
    const el = sentinel
    if (!el || loadingMore) return
    if (el.getBoundingClientRect().top < window.innerHeight + 600) void loadMore()
  })

  const color = $derived(genreColor(detail?.name ?? name))
  const heroCover = $derived(
    detail?.albums.find((a) => a.cover)?.cover ?? tracks.find((tr) => tr.cover)?.cover ?? null,
  )
  const context = $derived(`genre:${(detail?.name ?? name).toLowerCase()}`)
  const empty = $derived(detail !== null && detail.trackCount === 0)

  function duration(ms: number): string {
    const mins = Math.floor(ms / 60_000)
    if (mins < 1) return t('< 1 min')
    const h = Math.floor(mins / 60)
    const m = mins % 60
    return h === 0 ? t('{m} min', { m }) : t('{h} hr {m} min', { h: h.toLocaleString(i18n.locale), m })
  }
</script>

<div class="absolute inset-0 flex flex-col bg-zinc-950">
  <header class="absolute inset-x-0 top-0 z-10 flex h-14 items-center gap-2 pr-4 pl-2 transition-colors" class:bg-zinc-900={titleHidden}>
    <button class="rounded-full bg-black/30 p-2.5 text-white active:bg-black/50" aria-label={t('Back')} onclick={onBack}>
      <Icon name="back" class="size-6" />
    </button>
    <h1 class={['min-w-0 flex-1 truncate pr-14 text-base font-semibold transition-opacity', !titleHidden && 'opacity-0']}>
      {detail?.name ?? name}
    </h1>
  </header>

  <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
    <div class="relative isolate overflow-hidden px-4 pt-16 pb-3">
      <TintedBackdrop background="linear-gradient(180deg, {color} 0%, color-mix(in srgb, {color} 35%, var(--color-zinc-950)) 65%, var(--color-zinc-950) 100%)" />
      {#if heroCover}
        <Cover
          cover={heroCover}
          title={detail?.name ?? name}
          class="mx-auto aspect-square w-[55%] max-w-64 rounded-sm text-5xl shadow-2xl shadow-black/60"
        />
      {:else}
        <div class="mx-auto flex aspect-square w-[55%] max-w-64 items-center justify-center rounded-sm bg-white/15 shadow-2xl shadow-black/60">
          <Icon name="music" class="size-16 text-white/85" />
        </div>
      {/if}
      <h2 class="mt-6 text-[1.7rem] leading-tight font-bold tracking-tight" {@attach underTopBar((hidden) => (titleHidden = hidden))}>
        {detail?.name ?? name}
      </h2>
      {#if detail}
        <p class="mt-2 text-[13px] text-white/75">
          {[
            t('Genre'),
            count(detail.trackCount, '{n} song', '{n} songs'),
            detail.albums.length > 0 ? count(detail.albums.length, '{n} album', '{n} albums') : '',
            detail.durationMs > 0 ? duration(detail.durationMs) : '',
          ]
            .filter(Boolean)
            .join(' • ')}
        </p>
      {/if}
    </div>

    <StickyPlay
      playing={player.isActiveFrom(context)}
      disabled={!detail || detail.trackCount === 0}
      onclick={() => detail && player.playOrToggle(context, () => library.playGenre(detail!.name, 0, false))}
    />
    <div class="flex h-16 items-center gap-1 px-2.5 pb-2">
      <span class="flex-1"></span>
      <button
        class="rounded-full p-3 text-zinc-300 active:bg-white/10 disabled:opacity-40"
        aria-label={t('Shuffle play')}
        disabled={!detail || detail.trackCount === 0}
        onclick={() => detail && void library.playGenre(detail.name, randomTrackIndex(detail.trackCount), true)}
      >
        <Icon name="shuffle" class="size-6" />
      </button>
      <span class="mr-1.5 size-14 shrink-0" aria-hidden="true"></span>
    </div>

    {#if detail && detail.albums.length > 0}
      <h3 class="px-4 pb-2 text-lg font-bold">{t('Albums')}</h3>
      <div class="flex gap-3 overflow-x-auto px-4 pb-5">
        {#each detail.albums as a (a.id)}
          <button type="button" class="w-28 shrink-0 text-left active:opacity-70" onclick={() => onOpenAlbum(a.id)}>
            <Cover cover={a.cover} title={a.title} class="aspect-square w-full rounded-md text-2xl" />
            <span class="mt-1.5 block truncate text-[13px] font-medium">{a.title}</span>
            <span class="block truncate text-xs text-zinc-400">{a.albumArtist}</span>
          </button>
        {/each}
      </div>
    {/if}

    {#if empty}
      <p class="px-8 pt-4 text-center text-sm text-zinc-400">{t('No tracks found for this genre.')}</p>
    {:else if detail}
      <h3 class="px-4 pb-1 text-lg font-bold">{t('Songs')}</h3>
      {#each tracks as track, i (track.id)}
        <TrackItem
          title={track.title}
          subtitle={[track.artist, track.album].filter(Boolean).join(' · ')}
          path={track.path}
          cover={track.cover}
          trackId={track.id}
          {track}
          onPlay={() => library.playGenre(detail!.name, i)}
          selectScope={`m:genre:${name}`}
          index={i}
        />
      {/each}
      <div bind:this={sentinel} class="h-px" aria-hidden="true"></div>
      {#if loadingMore}
        <p class="px-4 py-3 text-center text-xs text-zinc-500">{t('Loading…')}</p>
      {/if}
    {:else}
      <div class="mx-4 mt-2 h-16 animate-pulse rounded-lg bg-zinc-800/60"></div>
    {/if}
  </div>
</div>

<script lang="ts">
  import { selection } from './trackSelection.svelte'
  import { invoke } from '@tauri-apps/api/core'
  import AddToPlaylist from './AddToPlaylist.svelte'
  import ArtistLinks from './ArtistLinks.svelte'
  import TitleLink from './TitleLink.svelte'
  import Cover from './Cover.svelte'
  import Equalizer from './Equalizer.svelte'
  import ExtBadge from './ExtBadge.svelte'
  import FavoriteButton from './FavoriteButton.svelte'
  import Icon from './Icon.svelte'
  import OnlineAlbumDetail from './OnlineAlbumDetail.svelte'
  import ShuffleButton from './ShuffleButton.svelte'
  import TintedBackdrop from './TintedBackdrop.svelte'
  import { artists, type ArtistOnlineInfo, type ArtistProfile } from './artists.svelte'
  import { history } from './history.svelte'
  import { count, i18n, t } from './i18n.svelte'
  import { library } from './library.svelte'
  import type { Rgb } from './nowCover.svelte'
  import { online, type OnlineAlbum } from './online.svelte'
  import { formatTime, player, randomTrackIndex } from './player.svelte'
  import { tintFrom } from './tint'
  import { trackMenu } from './contextMenu.svelte'

  let {
    name,
    onBack,
    onOpenAlbum,
  }: {
    name: string
    onBack: () => void
    onOpenAlbum?: (albumId: number) => void
  } = $props()

  let profile = $state<ArtistProfile | null>(null)
  let onlineInfo = $state<ArtistOnlineInfo | null>(null)
  let selectedOnlineAlbum = $state<OnlineAlbum | null>(null)
  let color = $state<Rgb | null>(null)
  let showAllTracks = $state(false)

  $effect(() => {
    void name
    selectedOnlineAlbum = null
    onlineInfo = null
    showAllTracks = false
  })

  $effect(() => {
    void library.stats.version
    void history.version
    const wanted = name
    let stale = false
    artists
      .profile(wanted)
      .then((res) => {
        if (!stale) profile = res
      })
      .catch((e) => (player.error = String(e)))
    return () => {
      stale = true
    }
  })

  $effect(() => {
    const wanted = name
    const lang = i18n.lang
    let stale = false
    artists
      .enrich(wanted, lang)
      .then((res) => {
        if (!stale) onlineInfo = res
      })
      .catch(() => {})
    return () => {
      stale = true
    }
  })

  const portrait = $derived(
    onlineInfo?.image ?? profile?.image ?? profile?.fallbackCover ?? null,
  )
  const bio = $derived(onlineInfo?.bio ?? profile?.bio ?? null)

  $effect(() => {
    const cover = portrait
    color = null
    if (!cover) return
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
  const currentPath = $derived(player.snapshot.current?.path ?? null)

  const POPULAR_COLLAPSED = 5
  const allPopularRows = $derived.by(() => {
    if (!profile) return []
    const seen = new Set(profile.popularTracks.map((e) => e.track.id))
    const rest = profile.tracks
      .filter((tr) => !seen.has(tr.id))
      .map((track) => ({ track, playCount: 0, listenedMs: 0 }))
    return [...profile.popularTracks, ...rest]
  })
  const scope = $derived(`artist:${profile?.name ?? ''}`)
  const visiblePopular = $derived(
    showAllTracks ? allPopularRows : allPopularRows.slice(0, POPULAR_COLLAPSED),
  )

  const trackIndexById = $derived.by(() => {
    const map = new Map<number, number>()
    if (!profile) return map
    profile.tracks.forEach((tr, idx) => map.set(tr.id, idx))
    return map
  })

  const missingAlbums = $derived.by(() => {
    if (!onlineInfo) return []
    const localTitles = new Set(
      (profile?.albums ?? []).map((a) => a.title.trim().toLowerCase()),
    )
    return onlineInfo.albums.filter((a) => !localTitles.has(a.title.trim().toLowerCase()))
  })

  function formatHoursMins(ms: number): string {
    const totalMin = Math.floor(ms / 60_000)
    if (totalMin < 1) return t('< 1 min')
    const h = Math.floor(totalMin / 60)
    const m = totalMin % 60
    return h === 0
      ? t('{m} min', { m })
      : t('{h} hr {m} min', { h: h.toLocaleString(i18n.locale), m })
  }

  function openOnlineAlbum(album: OnlineAlbum) {
    selectedOnlineAlbum = album
    void online.openAlbum(album)
  }
</script>

{#if selectedOnlineAlbum}
  <OnlineAlbumDetail
    album={selectedOnlineAlbum}
    onBack={() => {
      selectedOnlineAlbum = null
      online.closeAlbum()
    }}
  />
{:else}
  <div class="h-full overflow-y-auto pb-8">
    {#if profile}
      {@const ctx = `artist:${profile.name.toLowerCase()}`}
      <!-- Spotify-style banner: the portrait fills it, the name sits large
           at the bottom on a darkening gradient. -->
      <div class="relative isolate flex h-[min(42vh,360px)] min-h-64 items-end overflow-hidden text-white">
        {#if portrait}
          <Cover cover={portrait} title={profile.name} class="absolute inset-0 -z-20 size-full rounded-none object-cover object-[center_30%] text-8xl" />
        {:else}
          <TintedBackdrop background="linear-gradient(135deg, {tint.top}, {tint.surface})" />
        {/if}
        <div class="absolute inset-0 -z-10 bg-gradient-to-b from-black/10 via-black/25 to-black/75"></div>
        <button
          type="button"
          class="absolute top-4 left-4 rounded-full bg-black/40 p-1.5 text-white/90 outline-none hover:bg-black/60 hover:text-white focus-visible:ring-2 focus-visible:ring-white/70"
          aria-label={t('Back')}
          title={t('Back')}
          onclick={onBack}
        >
          <Icon name="back" class="size-5" />
        </button>
        <div class="min-w-0 px-6 pb-6">
          <p class="text-sm font-medium text-white/90">{t('Artist')}</p>
          <h2
            class={[
              'line-clamp-2 pb-2 leading-[1.05] font-black tracking-tight break-words drop-shadow-lg',
              profile.name.length <= 14 ? 'text-7xl xl:text-8xl' : profile.name.length <= 28 ? 'text-6xl' : 'text-4xl',
            ]}
          >
            {profile.name}
          </h2>
          <p class="mt-1 flex flex-wrap items-center gap-x-1.5 text-sm text-white/85">
            <span>{count(profile.albumCount, '{n} album', '{n} albums')}</span>
            <span aria-hidden="true">•</span>
            <span>{count(profile.trackCount, '{n} track', '{n} tracks')}</span>
            {#if profile.playCount > 0}
              <span aria-hidden="true">•</span>
              <span>
                {t('Your listens: {time} · {plays}', {
                  time: formatHoursMins(profile.listenedMs),
                  plays: count(profile.playCount, '{n} play', '{n} plays'),
                })}
              </span>
            {/if}
          </p>
        </div>
      </div>

      <div class="relative isolate">
        <TintedBackdrop background="linear-gradient(180deg, {tint.surface} 0%, transparent 100%)" />
        <div class="flex items-center gap-4 px-6 pt-5 pb-4">
          <button
            type="button"
            disabled={profile.trackCount === 0}
            aria-label={t(player.isActiveFrom(ctx) ? 'Pause' : 'Play')}
            title={t(player.isActiveFrom(ctx) ? 'Pause' : 'Play')}
            class="flex size-14 items-center justify-center rounded-full bg-accent-500 text-zinc-950 shadow-lg shadow-black/30 outline-none transition hover:scale-105 hover:bg-accent-400 focus-visible:ring-2 focus-visible:ring-white/80 disabled:opacity-50"
            onclick={() => player.playOrToggle(ctx, () => artists.play(profile!.name, 0, false))}
          >
            <Icon name={player.isActiveFrom(ctx) ? 'pause' : 'play'} class="size-7" />
          </button>
          <ShuffleButton
            disabled={profile.trackCount === 0}
            onClick={() => void artists.play(profile!.name, randomTrackIndex(profile!.trackCount), true)}
          />
          {#if profile.genres.length > 0}
            <div class="ml-2 flex min-w-0 flex-wrap gap-1.5">
              {#each profile.genres as g (g)}
                <span class="rounded-full bg-zinc-200/70 px-2.5 py-0.5 text-xs text-zinc-700 dark:bg-white/10 dark:text-white/85">{g}</span>
              {/each}
            </div>
          {/if}
        </div>
      </div>

      <div class="flex flex-col gap-8 px-5">
        {#if allPopularRows.length > 0}
          <section>
            <h3 class="mb-3 px-2 text-2xl font-bold">{t('Popular')}</h3>
            <div class="flex flex-col">
              {#each visiblePopular as entry, i (entry.track.id)}
                {@const tr = entry.track}
                {@const active = tr.path === currentPath}
                {@const idx = trackIndexById.get(tr.id) ?? 0}
                <div
                  role="button"
                  tabindex="0"
                  title={tr.path}
                  class={[
                    'group grid h-14 grid-cols-[1.75rem_2.5rem_minmax(0,1fr)_minmax(5rem,10rem)_2rem_3.5rem_2rem] items-center gap-3 rounded-md px-2 text-sm outline-none focus-visible:ring-2 focus-visible:ring-accent-500',
                    selection.has(scope, tr.path)
                      ? 'bg-accent-500/20 text-zinc-900 dark:bg-accent-400/20 dark:text-white'
                      : active
                        ? 'bg-accent-50 text-accent-900 dark:bg-accent-950/40 dark:text-accent-100'
                        : 'text-zinc-700 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800/50',
                  ]}
                  aria-pressed={selection.has(scope, tr.path)}
                  onclick={(e) => selection.click(e, scope, i, tr, (j) => visiblePopular[j]?.track)}
                  ondblclick={() => void artists.play(profile!.name, idx)}
                  oncontextmenu={(e) =>
                    trackMenu.fromEvent(e, tr, {
                      onPlay: () => void artists.play(profile!.name, idx),
                    })}
                  onkeydown={(e) => {
                    if (e.target !== e.currentTarget) return
                    if (selection.key(e, scope, visiblePopular.length, (j) => visiblePopular[j]?.track)) return
                    if (e.key === 'Enter') void artists.play(profile!.name, idx)
                  }}
                >
                  <span class="text-right text-sm tabular-nums text-zinc-400">
                    {#if active && player.snapshot.status === 'playing'}
                      <Equalizer class="ml-auto text-accent-600 dark:text-accent-400" />
                    {:else}
                      {i + 1}
                    {/if}
                  </span>
                  <Cover cover={tr.cover} title={tr.title} class="size-10 rounded text-[10px]" />
                  <!-- Title with the artist under it, like Spotify. -->
                  <span class="min-w-0">
                    <span class="flex min-w-0 items-center">
                      <TitleLink title={tr.title} albumId={tr.albumId} class={active ? 'font-medium text-accent-600 dark:text-accent-400' : 'font-medium text-zinc-900 dark:text-zinc-100'} />
                      <ExtBadge path={tr.path} />
                    </span>
                    <span class="block truncate text-[13px] text-zinc-500"><ArtistLinks artist={tr.artist} /></span>
                  </span>
                  <span class="text-right text-sm tabular-nums text-zinc-500">
                    {entry.playCount.toLocaleString(i18n.locale)}
                  </span>
                  <span class="flex justify-center">
                    <FavoriteButton trackId={tr.id} title={tr.title} revealOnHover />
                  </span>
                  <span class="text-right text-sm tabular-nums text-zinc-500">
                    {formatTime(tr.durationMs === null ? null : tr.durationMs / 1000)}
                  </span>
                  <span class="flex justify-end opacity-0 group-focus-within:opacity-100 group-hover:opacity-100 pointer-coarse:opacity-100">
                    <AddToPlaylist
                      trackIds={[tr.id]}
                      track={tr}
                      editTags
                      onPlay={() => void artists.play(profile!.name, idx)}
                      label={t('More actions for “{title}”', { title: tr.title })}
                    />
                  </span>
                </div>
              {/each}
            </div>
            {#if allPopularRows.length > POPULAR_COLLAPSED}
              <button
                type="button"
                aria-expanded={showAllTracks}
                class="mt-3 ml-2 rounded-md px-2 py-1 text-sm font-bold text-zinc-500 transition hover:text-zinc-900 focus-visible:ring-2 focus-visible:ring-accent-500 focus-visible:outline-none dark:text-zinc-400 dark:hover:text-zinc-100"
                onclick={() => (showAllTracks = !showAllTracks)}
              >
                {showAllTracks ? t('Show less') : t('See more')}
              </button>
            {/if}
          </section>
        {/if}

        <!-- Local albums -->
        {#if profile.albums.length > 0}
          <section>
            <h3 class="mb-3 px-2 text-2xl font-bold">{t('Albums in library')}</h3>
            <div class="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
              {#each profile.albums as a (a.id)}
                <button
                  type="button"
                  class="group flex flex-col gap-2 rounded-lg p-1 text-left outline-none focus-visible:ring-2 focus-visible:ring-accent-500"
                  onclick={() => onOpenAlbum?.(a.id)}
                >
                  <Cover
                    cover={a.cover}
                    title={a.title}
                    class="aspect-square w-full rounded-lg shadow-sm transition group-hover:scale-[1.02]"
                  />
                  <div class="min-w-0">
                    <p class="truncate text-sm font-medium">{a.title}</p>
                    <p class="truncate text-xs text-zinc-500">
                      {a.year ? `${a.year} · ` : ''}{count(a.trackCount, '{n} track', '{n} tracks')}
                    </p>
                  </div>
                </button>
              {/each}
            </div>
          </section>
        {/if}

        <!-- Online missing discography -->
        {#if missingAlbums.length > 0}
          <section>
            <h3 class="mb-3 px-2 text-2xl font-bold">{t('More albums (Online)')}</h3>
            <div class="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
              {#each missingAlbums as a (a.id)}
                <button
                  type="button"
                  class="group flex flex-col gap-2 rounded-lg p-1 text-left outline-none focus-visible:ring-2 focus-visible:ring-accent-500"
                  onclick={() => openOnlineAlbum(a)}
                >
                  <Cover
                    cover={a.cover}
                    title={a.title}
                    class="aspect-square w-full rounded-lg shadow-sm transition group-hover:scale-[1.02]"
                  />
                  <div class="min-w-0">
                    <p class="truncate text-sm font-medium">{a.title}</p>
                    <p class="truncate text-xs text-zinc-500">
                      {a.year ? `${a.year} · ` : ''}{count(a.trackCount, '{n} track', '{n} tracks')}
                    </p>
                  </div>
                </button>
              {/each}
            </div>
          </section>
        {/if}

        {#if bio}
          <section>
            <h3 class="mb-3 px-2 text-2xl font-bold">{t('About')}</h3>
            <div class="max-w-3xl rounded-2xl border border-zinc-200 bg-white p-5 text-sm leading-relaxed text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900/60 dark:text-zinc-300">
              {bio}
            </div>
          </section>
        {/if}
      </div>
    {/if}
  </div>
{/if}

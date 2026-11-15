<script lang="ts">
  import { invoke } from '@tauri-apps/api/core'
  import Cover from '../Cover.svelte'
  import Icon from '../Icon.svelte'
  import OnlineAlbumDetail from '../OnlineAlbumDetail.svelte'
  import TintedBackdrop from '../TintedBackdrop.svelte'
  import MobileSheet from './MobileSheet.svelte'
  import PageHeader from './PageHeader.svelte'
  import StickyPlay from './StickyPlay.svelte'
  import TrackItem from './TrackItem.svelte'
  import { popLayer, pushLayer } from './layers'
  import { underTopBar } from './titleWatch'
  import { artists, type ArtistOnlineInfo, type ArtistProfile } from '../artists.svelte'
  import { favorites } from '../favorites.svelte'
  import { history } from '../history.svelte'
  import { count, i18n, t } from '../i18n.svelte'
  import { library } from '../library.svelte'
  import type { Rgb } from '../nowCover.svelte'
  import { online, type OnlineAlbum } from '../online.svelte'
  import { player, randomTrackIndex, type PlayerSnapshot } from '../player.svelte'
  import { tintFrom } from '../tint'

  let {
    name,
    onBack,
    onOpenAlbum,
  }: {
    name: string
    onBack: () => void
    onOpenAlbum: (albumId: number) => void
  } = $props()

  let profile = $state<ArtistProfile | null>(null)
  let onlineInfo = $state<ArtistOnlineInfo | null>(null)
  let selectedOnlineAlbum = $state<OnlineAlbum | null>(null)
  let showFavorites = $state(false)
  let color = $state<Rgb | null>(null)
  let titleHidden = $state(false)

  $effect(() => {
    void name
    selectedOnlineAlbum = null
    showFavorites = false
    onlineInfo = null
    titleHidden = false
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

  const trackIndexById = $derived.by(() => {
    const map = new Map<number, number>()
    if (!profile) return map
    profile.tracks.forEach((tr, idx) => map.set(tr.id, idx))
    return map
  })

  const likedTracks = $derived.by(() => {
    void favorites.version
    if (!profile) return []
    return profile.tracks.filter((tr) => favorites.has(tr.id))
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
    // A second tap while it is open must not stack another layer.
    if (selectedOnlineAlbum !== null) return
    selectedOnlineAlbum = album
    void online.openAlbum(album)
    pushLayer(() => {
      selectedOnlineAlbum = null
      online.closeAlbum()
    })
  }

  function openFavoritesSheet() {
    if (showFavorites || likedTracks.length === 0) return
    showFavorites = true
    pushLayer(() => {
      showFavorites = false
    })
  }

  async function playLikedAt(index: number) {
    if (likedTracks.length === 0) return
    try {
      const snap = await invoke<PlayerSnapshot>('queue_replace', {
        paths: likedTracks.map((tr) => tr.path),
        startIndex: index,
      })
      player.applySnapshot(snap)
    } catch (e) {
      player.error = String(e)
    }
  }
</script>

<div class="absolute inset-0 flex flex-col bg-zinc-950">
  <header
    class="absolute inset-x-0 top-0 z-10 flex h-14 items-center gap-2 px-2 transition-colors"
    class:bg-zinc-900={titleHidden}
  >
    <button
      type="button"
      class="rounded-full bg-black/45 p-2.5 text-white active:bg-black/65"
      aria-label={t('Back')}
      onclick={onBack}
    >
      <Icon name="back" class="size-6" />
    </button>
    {#if profile}
      <h1 class={['min-w-0 flex-1 truncate text-base font-semibold transition-opacity', !titleHidden && 'opacity-0']}>
        {profile.name}
      </h1>
    {/if}
  </header>

  <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
    {#if profile}
      {@const ctx = `artist:${profile.name.toLowerCase()}`}
      <!-- Spotify-style edge-to-edge hero portrait: big left-aligned name on
           a bottom gradient scrim melting cleanly into the dark background. -->
      <div class="relative isolate flex h-[min(42svh,320px)] min-h-64 flex-col justify-end overflow-hidden text-white">
        {#if portrait}
          <Cover
            cover={portrait}
            title={profile.name}
            class="absolute inset-0 -z-20 size-full rounded-none object-cover object-[center_25%] text-7xl"
          />
        {:else}
          <TintedBackdrop background="linear-gradient(135deg, {tint.top} 0%, {tint.surface} 100%)" />
        {/if}
        <div class="pointer-events-none absolute inset-0 -z-10 bg-gradient-to-b from-black/35 via-black/15 via-45% to-zinc-950"></div>
        <div class="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-1/2 bg-gradient-to-t from-zinc-950 via-black/45 to-transparent"></div>
        <div class="px-4 pb-2">
          <h2
            class={[
              'line-clamp-2 leading-[1.03] font-black tracking-tight break-words text-white drop-shadow-md',
              profile.name.length <= 16 ? 'text-[2.25rem]' : profile.name.length <= 28 ? 'text-3xl' : 'text-2xl',
            ]}
            {@attach underTopBar((hidden) => (titleHidden = hidden))}
          >
            {profile.name}
          </h2>
          <p class="mt-1.5 flex items-center gap-1.5 text-xs font-medium text-white/90">
            <Icon name="artist" class="size-3.5 shrink-0 text-accent-400" />
            <span>{t('Artist')}</span>
          </p>
        </div>
      </div>

      <p class="px-4 pt-1.5 text-[13px] text-zinc-400">
        {count(profile.albumCount, '{n} album', '{n} albums')} · {count(
          profile.trackCount,
          '{n} track',
          '{n} tracks',
        )}{#if profile.playCount > 0}{' '}· {formatHoursMins(profile.listenedMs)} · {count(
            profile.playCount,
            '{n} play',
            '{n} plays',
          )}{/if}
      </p>

      <StickyPlay
        top="44px"
        playing={player.isActiveFrom(ctx)}
        disabled={profile.tracks.length === 0}
        onclick={() => player.playOrToggle(ctx, () => artists.play(profile!.name, 0, false))}
      />
      <div class="flex h-16 items-center gap-2 px-4 pb-2">
        <div class="flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden">
          {#each profile.genres.slice(0, 2) as g (g)}
            <span class="truncate rounded-full border border-zinc-600 px-3.5 py-1 text-xs font-semibold text-zinc-100">
              {g}
            </span>
          {/each}
        </div>
        <button
          type="button"
          disabled={profile.tracks.length === 0}
          class="rounded-full p-2.5 text-zinc-300 active:bg-white/10 disabled:opacity-40"
          aria-label={t('Shuffle play')}
          onclick={() =>
            void artists.play(profile!.name, randomTrackIndex(profile!.trackCount), true)}
        >
          <Icon name="shuffle" class="size-6" />
        </button>
        <span class="size-14 shrink-0" aria-hidden="true"></span>
      </div>

      {#if likedTracks.length > 0}
        <button
          type="button"
          class="mt-1 mb-2 flex w-full items-center gap-3 px-4 py-2 text-left active:bg-white/5"
          onclick={openFavoritesSheet}
        >
          <div class="relative size-11 shrink-0">
            <Cover cover={portrait} title={profile.name} class="size-11 rounded-full text-base" />
            <span class="absolute -right-0.5 -bottom-0.5 flex size-4.5 items-center justify-center rounded-full bg-accent-500 text-zinc-950 ring-2 ring-zinc-950">
              <Icon name="star" class="size-2.5" />
            </span>
          </div>
          <div class="min-w-0 flex-1">
            <span class="block truncate text-[15px] font-semibold text-zinc-50">{t('Favorites')}</span>
            <span class="block truncate text-xs text-zinc-400">
              {count(likedTracks.length, '{n} song', '{n} songs')} · {profile.name}
            </span>
          </div>
          <Icon name="chevronRight" class="size-5 shrink-0 text-zinc-400" />
        </button>
      {/if}

      {#if profile.popularTracks.length > 0}
        <section class="mt-2">
          <h3 class="px-4 pb-1 text-lg font-bold">{t('Popular')}</h3>
            {#each profile.popularTracks.slice(0, 5) as item, idx (item.track.id)}
              {@const qIdx = trackIndexById.get(item.track.id) ?? 0}
              <TrackItem
                title={item.track.title}
                subtitle={item.playCount > 0
                  ? [count(item.playCount, '{n} play', '{n} plays'), item.track.album]
                      .filter(Boolean)
                      .join(' · ')
                  : item.track.album}
                path={item.track.path}
                cover={item.track.cover}
                trackId={item.track.id}
                track={item.track}
                artist=""
                extraMeta={item.playCount > 0 ? count(item.playCount, '{n} play', '{n} plays') : ''}
                number={idx + 1}
                onPlay={() => void artists.play(profile!.name, qIdx)}
              />
            {/each}
          </section>
        {/if}

        {#if bio}
          <section class="mt-5 px-4">
            <h3 class="mb-2 text-base font-bold">{t('About')}</h3>
            <p class="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4 text-sm leading-relaxed text-zinc-300">
              {bio}
            </p>
          </section>
        {/if}

        {#if profile.albums.length > 0}
          <section class="mt-5">
            <h3 class="px-4 pb-2 text-base font-bold">{t('Albums in library')}</h3>
            <div class="flex gap-3 overflow-x-auto px-4 pb-2">
              {#each profile.albums as album (album.id)}
                <button
                  type="button"
                  class="w-32 shrink-0 text-left active:opacity-70"
                  onclick={() => onOpenAlbum(album.id)}
                >
                  <Cover
                    cover={album.cover}
                    title={album.title}
                    class="aspect-square w-full rounded-md text-2xl shadow-lg shadow-black/40"
                  />
                  <span class="mt-1.5 block truncate text-[13px] font-semibold text-zinc-100">
                    {album.title}
                  </span>
                  <span class="block truncate text-xs text-zinc-400">
                    {album.year ? `${album.year} · ` : ''}{count(
                      album.trackCount,
                      '{n} track',
                      '{n} tracks',
                    )}
                  </span>
                </button>
              {/each}
            </div>
          </section>
        {/if}

        {#if missingAlbums.length > 0}
          <section class="mt-5">
            <h3 class="px-4 pb-2 text-base font-bold">{t('More albums (Online)')}</h3>
            <div class="flex gap-3 overflow-x-auto px-4 pb-2">
              {#each missingAlbums as oa (oa.id)}
                <button
                  type="button"
                  class="w-32 shrink-0 text-left active:opacity-70"
                  onclick={() => openOnlineAlbum(oa)}
                >
                  <Cover
                    cover={oa.cover ?? oa.coverUrl}
                    title={oa.title}
                    class="aspect-square w-full rounded-md text-2xl shadow-lg shadow-black/40"
                  />
                  <span class="mt-1.5 block truncate text-[13px] font-semibold text-zinc-100">
                    {oa.title}
                  </span>
                  <span class="block truncate text-xs text-zinc-400">
                    {oa.year ?? ''}
                  </span>
                </button>
              {/each}
            </div>
          </section>
        {/if}

        {#if profile.tracks.length > 0}
          <section class="mt-5">
            <h3 class="px-4 pb-1 text-base font-bold">{t('All tracks')}</h3>
            {#each profile.tracks as track, idx (track.id)}
              <TrackItem
                title={track.title}
                subtitle={[track.album, track.year].filter(Boolean).join(' · ')}
                path={track.path}
                cover={track.cover}
                trackId={track.id}
                {track}
                artist=""
                extraMeta={track.year ? String(track.year) : ''}
                onPlay={() => void artists.play(profile!.name, idx)}
                selectScope={`m:artist:${profile!.name}`}
                index={idx}
              />
            {/each}
          </section>
        {/if}
      {:else}
        <div class="h-[min(42svh,320px)] min-h-64 w-full animate-pulse bg-zinc-900"></div>
        <div class="space-y-3 px-4 pt-3">
          <div class="h-3.5 w-36 animate-pulse rounded bg-zinc-800"></div>
          <div class="flex items-center justify-between pt-1">
            <div class="h-7 w-20 animate-pulse rounded-full bg-zinc-800"></div>
            <div class="size-14 animate-pulse rounded-full bg-zinc-800"></div>
          </div>
        </div>
      {/if}
  </div>
</div>

{#if showFavorites && profile}
  <MobileSheet onBack={popLayer}>
    <div class="absolute inset-0 flex flex-col bg-zinc-950">
      <PageHeader title={`${t('Favorites')} · ${profile.name}`} onBack={popLayer} />
      <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
        {#each likedTracks as track, idx (track.id)}
          <TrackItem
            title={track.title}
            subtitle={[track.album, track.year].filter(Boolean).join(' · ')}
            path={track.path}
            cover={track.cover}
            trackId={track.id}
            {track}
            artist=""
            extraMeta={track.year ? String(track.year) : ''}
            onPlay={() => void playLikedAt(idx)}
            index={idx}
          />
        {/each}
      </div>
    </div>
  </MobileSheet>
{/if}

{#if selectedOnlineAlbum}
  <MobileSheet onBack={popLayer}>
    <div class="absolute inset-0 flex flex-col bg-zinc-950 pt-2">
      <OnlineAlbumDetail album={selectedOnlineAlbum} onBack={popLayer} />
    </div>
  </MobileSheet>
{/if}

<script lang="ts">
  import TitleLink from './TitleLink.svelte'
  import { count, t } from './i18n.svelte'
  import ArtistLinks from './ArtistLinks.svelte'
  import Cover from './Cover.svelte'
  import FavoriteButton from './FavoriteButton.svelte'
  import Icon from './Icon.svelte'
  import JamButton from './JamButton.svelte'
  import { artists, splitArtistNames, type ArtistProfile } from './artists.svelte'
  import { trackMenu } from './contextMenu.svelte'
  import { library, type TrackRow } from './library.svelte'
  import { lyrics, findActiveIndex } from './lyrics.svelte'
  import { nowCover } from './nowCover.svelte'
  import { player } from './player.svelte'
  import { tintFrom } from './tint'
  import { trackCovers } from './trackCovers.svelte'

  let {
    onClose,
    onExpand,
    onOpenQueue,
  }: {
    onClose: () => void
    onExpand: () => void
    onOpenQueue: () => void
  } = $props()

  const snap = $derived(player.snapshot)
  const cur = $derived(snap.current)
  const tint = $derived(tintFrom(nowCover.color))
  const isLocalTrack = $derived(
    cur ? !cur.path.startsWith('http://') && !cur.path.startsWith('https://') : false,
  )
  const primaryArtist = $derived(cur ? (splitArtistNames(cur.artist)[0] ?? '') : '')

  let artistProfile = $state<ArtistProfile | null>(null)
  $effect(() => {
    const name = primaryArtist
    void library.stats.version
    if (!name) {
      artistProfile = null
      return
    }
    let stale = false
    artists
      .profile(name)
      .then((profile) => {
        if (!stale) artistProfile = profile
      })
      .catch(() => {
        if (!stale) artistProfile = null
      })
    return () => {
      stale = true
    }
  })

  const previewLines = $derived.by(() => {
    const res = lyrics.result
    if (!res || (res.kind !== 'synced' && res.kind !== 'plain')) return []
    if (res.kind === 'plain') {
      return res.lines
        .filter((line) => line.trim() !== '')
        .slice(0, 4)
        .map((text, idx) => ({ text, active: idx === 0 }))
    }
    const activeIdx = findActiveIndex(res.lines, player.position)
    const start = Math.max(0, activeIdx)
    return res.lines
      .slice(start, start + 5)
      .map((line, offset) => ({
        text: line.text.trim() === '' ? '♪' : line.text,
        active: activeIdx >= 0 && start + offset === activeIdx,
      }))
      .slice(0, 4)
  })
</script>

<header class="flex shrink-0 items-center justify-between gap-2 px-4 pt-4 pb-2">
  <h2 class="truncate text-sm font-semibold text-zinc-900 dark:text-zinc-100">
    {nowCover.track?.album || t('Now playing')}
  </h2>
  <div class="flex shrink-0 items-center gap-0.5">
    <JamButton iconOnly />
    {#if cur}
      <button
        type="button"
        class="rounded-full p-1.5 text-zinc-500 outline-none transition hover:bg-zinc-200/80 hover:text-zinc-900 focus-visible:ring-2 focus-visible:ring-accent-500 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
        onclick={onExpand}
        aria-label={t('Expand view')}
        title={t('Expand view')}
      >
        <Icon name="expand" class="size-4" />
      </button>
    {/if}
    <button
      type="button"
      class="rounded-full p-1.5 text-zinc-500 outline-none transition hover:bg-zinc-200/80 hover:text-zinc-900 focus-visible:ring-2 focus-visible:ring-accent-500 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
      onclick={onClose}
      aria-label={t('Close right panel')}
      title={t('Close right panel')}
    >
      <Icon name="close" class="size-4" />
    </button>
  </div>
</header>

{#if cur}
  {@const menuRow: TrackRow = nowCover.track ?? {
    id: -1,
    title: cur.title,
    artist: cur.artist,
    album: '',
    albumId: null,
    trackNo: null,
    discNo: null,
    year: null,
    durationMs: null,
    path: cur.path,
    cover: nowCover.cover,
    plays: 0,
  }}
  <div class="min-h-0 flex-1 space-y-4 overflow-y-auto px-4 pt-1 pb-5">
    <Cover
      cover={nowCover.cover}
      title={cur.title}
      class="aspect-square w-full rounded-xl text-6xl shadow-lg"
    />

    <div
      role="region"
      aria-label={t('Now playing')}
      class="flex items-start justify-between gap-3"
      oncontextmenu={(e) => trackMenu.fromEvent(e, menuRow)}
    >
      <div class="min-w-0 flex-1">
        <h3 class="truncate text-lg leading-snug font-bold text-zinc-900 dark:text-zinc-50" title={cur.title}>
          <TitleLink title={cur.title} path={cur.path} />
        </h3>
        <p class="truncate text-sm text-zinc-500 dark:text-zinc-400">
          {#if cur.artist}
            <ArtistLinks artist={cur.artist} />
          {:else}
            {t('Unknown artist')}
          {/if}
        </p>
      </div>
      {#if isLocalTrack}
        <FavoriteButton path={cur.path} title={cur.title} size="size-5" />
      {/if}
    </div>

    {#if previewLines.length > 0}
      <div
        class="rounded-xl p-4 text-white shadow-sm"
        style:background={tint.surface}
      >
        <div class="flex items-center justify-between gap-2">
          <span class="text-xs font-semibold text-white/90">{t('Lyrics preview')}</span>
          <button
            type="button"
            class="rounded-full bg-black/25 px-2.5 py-1 text-[11px] font-semibold text-white/90 transition hover:bg-black/40"
            onclick={() => lyrics.setOpen(!lyrics.open)}
          >
            {lyrics.open ? t('Close lyrics') : t('Show lyrics')}
          </button>
        </div>
        <button
          type="button"
          class="mt-3 block w-full space-y-1.5 text-left text-[15px] leading-snug font-bold outline-none"
          onclick={() => lyrics.setOpen(true)}
        >
          {#each previewLines as line, idx (idx)}
            <p
              class={line.active ? 'text-white' : ''}
              style:color={line.active ? undefined : tint.dim}
            >
              {line.text}
            </p>
          {/each}
        </button>
      </div>
    {/if}

    {#if artistProfile}
      <div class="overflow-hidden rounded-xl border border-zinc-200/80 bg-white/80 dark:border-zinc-800 dark:bg-zinc-900/90">
        {#if artistProfile.image || artistProfile.fallbackCover}
          <div class="relative aspect-[16/10] w-full overflow-hidden">
            <Cover
              cover={artistProfile.image ?? artistProfile.fallbackCover}
              title={artistProfile.name}
              class="h-full w-full text-4xl"
            />
            <div class="pointer-events-none absolute inset-x-0 top-0 h-16 bg-gradient-to-b from-black/65 to-transparent"></div>
            <span class="absolute top-3 left-3 text-xs font-semibold text-white drop-shadow">
              {t('About the artist')}
            </span>
          </div>
        {:else}
          <p class="px-4 pt-3 text-xs font-semibold text-zinc-500 dark:text-zinc-400">
            {t('About the artist')}
          </p>
        {/if}
        <div class="space-y-1.5 p-4">
          <button
            type="button"
            class="block text-left text-base font-bold text-zinc-900 hover:underline dark:text-zinc-100"
            onclick={() => artists.open(artistProfile!.name)}
          >
            {artistProfile.name}
          </button>
          {#if artistProfile.playCount > 0}
            <p class="text-xs text-zinc-500 dark:text-zinc-400">
              {count(artistProfile.playCount, '{n} play', '{n} plays')}
            </p>
          {/if}
          {#if artistProfile.bio}
            <p class="line-clamp-4 text-xs leading-relaxed text-zinc-600 dark:text-zinc-400">
              {artistProfile.bio}
            </p>
          {/if}
        </div>
      </div>
    {/if}

    {#if snap.nextTrack}
      {@const next = snap.nextTrack}
      <!-- Spotify-style "Next in queue": what plays after this song
           (shuffle and repeat applied); clicking it skips to it. -->
      <section
        aria-labelledby="np-next-heading"
        class="rounded-xl border border-zinc-200/80 bg-white/80 p-4 dark:border-zinc-800 dark:bg-zinc-900/90"
      >
        <div class="mb-3 flex items-center justify-between gap-2">
          <h3 id="np-next-heading" class="text-sm font-bold text-zinc-900 dark:text-zinc-100">{t('Next in queue')}</h3>
          <button
            type="button"
            class="text-xs font-semibold text-zinc-500 hover:text-zinc-900 hover:underline dark:text-zinc-400 dark:hover:text-zinc-100"
            onclick={onOpenQueue}
          >
            {t('Open queue')}
          </button>
        </div>
        <button
          type="button"
          class="group -m-1.5 flex w-[calc(100%+0.75rem)] items-center gap-3 rounded-lg p-1.5 text-left hover:bg-zinc-200/70 dark:hover:bg-zinc-800/80"
          title={t('Play “{title}”', { title: next.title })}
          onclick={() => void player.next()}
        >
          <span class="relative shrink-0">
            <Cover cover={trackCovers.get(next.path) ?? null} title={next.title} class="size-12 rounded-md text-xs" />
            <span class="absolute inset-0 flex items-center justify-center rounded-md bg-black/50 text-white opacity-0 transition-opacity group-hover:opacity-100">
              <Icon name="play" class="size-5" />
            </span>
          </span>
          <span class="min-w-0 flex-1">
            <span class="block truncate text-sm font-medium text-zinc-900 dark:text-zinc-100">{next.title}</span>
            <span class="block truncate text-xs text-zinc-500 dark:text-zinc-400">{next.artist || t('Unknown artist')}</span>
          </span>
        </button>
      </section>
    {/if}
  </div>
{:else}
  <div class="flex flex-1 items-center justify-center px-6 text-center text-sm text-zinc-500">
    {t('Nothing playing.')}
  </div>
{/if}

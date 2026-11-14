<script lang="ts">
  import AddToPlaylist from './AddToPlaylist.svelte'
  import AlbumLink from './AlbumLink.svelte'
  import ArtistLinks from './ArtistLinks.svelte'
  import Cover from './Cover.svelte'
  import Equalizer from './Equalizer.svelte'
  import ExtBadge from './ExtBadge.svelte'
  import FavoriteButton from './FavoriteButton.svelte'
  import Icon from './Icon.svelte'
  import ShuffleButton from './ShuffleButton.svelte'
  import TintedBackdrop from './TintedBackdrop.svelte'
  import { trackMenu } from './contextMenu.svelte'
  import { genreColor } from './genreColor'
  import { count, i18n, t } from './i18n.svelte'
  import { library, type GenreDetail } from './library.svelte'
  import { formatTime, player, randomTrackIndex } from './player.svelte'

  let {
    name,
    onBack,
    onOpenAlbum,
  }: {
    name: string
    onBack: () => void
    onOpenAlbum: (albumId: number) => void
  } = $props()

  let detail = $state<GenreDetail | null>(null)
  let loading = $state(true)

  $effect(() => {
    void library.stats.version
    const wanted = name
    let stale = false
    loading = true
    library
      .genreDetail(wanted)
      .then((res) => {
        if (stale) return
        detail = res
        loading = false
      })
      .catch((e) => {
        if (!stale) {
          player.error = String(e)
          loading = false
        }
      })
    return () => {
      stale = true
    }
  })

  const baseColor = $derived(genreColor(detail?.name ?? name))
  const heroCover = $derived(
    detail?.albums.find((a) => a.cover)?.cover ??
      detail?.tracks.find((tr) => tr.cover)?.cover ??
      null,
  )
  const totalMs = $derived(
    (detail?.tracks ?? []).reduce((acc, tr) => acc + (tr.durationMs ?? 0), 0),
  )
  const currentPath = $derived(player.snapshot.current?.path ?? null)

  function formatDurationSummary(ms: number): string {
    const mins = Math.floor(ms / 60_000)
    if (mins < 1) return t('< 1 min')
    const h = Math.floor(mins / 60)
    const m = mins % 60
    return h === 0
      ? t('{m} min', { m })
      : t('{h} hr {m} min', { h: h.toLocaleString(i18n.locale), m })
  }
</script>

<div class="pb-4">
  <button
    type="button"
    class="mb-4 rounded-lg px-2 py-1 text-sm text-zinc-600 hover:bg-zinc-200/70 dark:text-zinc-300 dark:hover:bg-zinc-800"
    onclick={onBack}
  >
    {t('← Search')}
  </button>

  <div
    class="relative isolate mb-6 flex flex-wrap items-end gap-6 overflow-hidden rounded-2xl p-6 text-white"
  >
    <TintedBackdrop background="linear-gradient(135deg, {baseColor}, #111318)" />
    {#if heroCover}
      <Cover
        cover={heroCover}
        title={detail?.name ?? name}
        class="size-40 shrink-0 rounded-xl text-5xl shadow-2xl shadow-black/40 sm:size-44"
      />
    {:else}
      <div
        class="flex size-40 shrink-0 items-center justify-center rounded-xl bg-white/15 shadow-2xl shadow-black/40 sm:size-44"
      >
        <Icon name="music" class="size-16 text-white/85" />
      </div>
    {/if}

    <div class="min-w-0 flex-1">
      <p class="text-xs font-semibold tracking-widest text-white/75 uppercase">{t('Genre')}</p>
      <h2 class="mt-1 truncate pb-1 text-4xl leading-tight font-bold tracking-tight sm:text-5xl">
        {detail?.name ?? name}
      </h2>
      {#if detail}
        <p class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-white/75">
          <span>{count(detail.tracks.length, '{n} track', '{n} tracks')}</span>
          {#if detail.albums.length > 0}
            <span>·</span>
            <span>{count(detail.albums.length, '{n} album', '{n} albums')}</span>
          {/if}
          {#if totalMs > 0}
            <span>·</span>
            <span>{formatDurationSummary(totalMs)}</span>
          {/if}
        </p>
      {/if}

      <div class="mt-4 flex flex-wrap items-center gap-2">
        <button
          type="button"
          disabled={!detail || detail.tracks.length === 0}
          class="flex items-center gap-2 rounded-full bg-accent-500 py-2 pr-5 pl-4 text-sm font-semibold text-zinc-950 transition hover:scale-[1.03] hover:bg-accent-400 disabled:cursor-not-allowed disabled:opacity-50"
          onclick={() => detail && void library.playGenre(detail.name, 0, false)}
        >
          <Icon name="play" class="size-5" />
          {t('Play')}
        </button>
        <ShuffleButton
          disabled={!detail || detail.tracks.length === 0}
          onClick={() =>
            detail &&
            void library.playGenre(
              detail.name,
              randomTrackIndex(detail.tracks.length),
              true,
            )}
        />
      </div>
    </div>
  </div>

  {#if loading && !detail}
    <p class="text-sm text-zinc-500">{t('Loading…')}</p>
  {:else if detail && detail.tracks.length === 0}
    <p class="text-sm text-zinc-500">{t('No tracks found for this genre.')}</p>
  {:else if detail}
    <div class="flex flex-col gap-8">
      {#if detail.albums.length > 0}
        <section>
          <h3 class="mb-3 text-base font-semibold">{t('Albums')}</h3>
          <div
            class="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
          >
            {#each detail.albums as a (a.id)}
              <button
                type="button"
                class="group flex flex-col gap-2 rounded-lg p-1 text-left outline-none focus-visible:ring-2 focus-visible:ring-accent-500"
                onclick={() => onOpenAlbum(a.id)}
              >
                <Cover
                  cover={a.cover}
                  title={a.title}
                  class="aspect-square w-full rounded-lg shadow-sm transition group-hover:scale-[1.02]"
                />
                <div class="min-w-0">
                  <p class="truncate text-sm font-medium">{a.title}</p>
                  <p class="truncate text-xs text-zinc-500">
                    {a.albumArtist}{a.year ? ` · ${a.year}` : ''}
                  </p>
                </div>
              </button>
            {/each}
          </div>
        </section>
      {/if}

      <section>
        <h3 class="mb-3 text-base font-semibold">{t('Songs')}</h3>
        <div class="flex flex-col gap-0.5">
          {#each detail.tracks as tr, i (tr.id)}
            {@const active = tr.path === currentPath}
            <div
              role="button"
              tabindex="0"
              title={tr.path}
              class={[
                'group grid grid-cols-[1.75rem_2.25rem_minmax(0,2fr)_minmax(0,1.5fr)_4.25rem_3.5rem] items-center gap-3 rounded-lg px-2 py-1.5 text-sm outline-none focus-visible:ring-2 focus-visible:ring-accent-500',
                active
                  ? 'bg-accent-50 text-accent-900 dark:bg-accent-950/40 dark:text-accent-100'
                  : 'text-zinc-700 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800/50',
              ]}
              ondblclick={() => void library.playGenre(detail!.name, i)}
              oncontextmenu={(e) =>
                trackMenu.fromEvent(e, tr, {
                  onPlay: () => void library.playGenre(detail!.name, i),
                })}
              onkeydown={(e) =>
                e.target === e.currentTarget &&
                e.key === 'Enter' &&
                void library.playGenre(detail!.name, i)}
            >
              <span class="text-right text-xs tabular-nums text-zinc-400">
                {#if active && player.snapshot.status === 'playing'}
                  <Equalizer class="text-accent-600 dark:text-accent-400" />
                {:else}
                  {i + 1}
                {/if}
              </span>
              <Cover cover={tr.cover} title={tr.title} class="size-9 rounded text-[10px]" />
              <span class="min-w-0">
                <span class="flex items-center truncate font-medium">
                  <span class="truncate">{tr.title}</span>
                  <ExtBadge path={tr.path} />
                </span>
                <span class="block truncate text-xs text-zinc-500">
                  <ArtistLinks artist={tr.artist} />
                </span>
              </span>
              <span class="truncate text-xs text-zinc-500">
                <AlbumLink album={tr.album} albumId={tr.albumId} />
              </span>
              <span class="flex items-center justify-end gap-0.5">
                <FavoriteButton trackId={tr.id} title={tr.title} revealOnHover />
                <span
                  class="opacity-0 group-focus-within:opacity-100 group-hover:opacity-100 pointer-coarse:opacity-100"
                >
                  <AddToPlaylist
                    trackIds={[tr.id]}
                    track={tr}
                    editTags
                    onPlay={() => void library.playGenre(detail!.name, i)}
                    label={t('More actions for “{title}”', { title: tr.title })}
                  />
                </span>
              </span>
              <span class="text-right text-xs tabular-nums text-zinc-500">
                {formatTime(tr.durationMs === null ? null : tr.durationMs / 1000)}
              </span>
            </div>
          {/each}
        </div>
      </section>
    </div>
  {/if}
</div>

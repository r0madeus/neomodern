<script lang="ts">
  import { selection } from './trackSelection.svelte'
  import { appSettings } from './appSettings.svelte'
  import { count, i18n, t } from './i18n.svelte'
  import { invoke } from '@tauri-apps/api/core'
  import Cover from './Cover.svelte'
  import Equalizer from './Equalizer.svelte'
  import Icon from './Icon.svelte'
  import ShuffleButton from './ShuffleButton.svelte'
  import ActionsMenu from './ActionsMenu.svelte'
  import CollectionHeader from './CollectionHeader.svelte'
  import { playlists } from './playlists.svelte'
  import AddToPlaylist from './AddToPlaylist.svelte'
  import ArtistLinks from './ArtistLinks.svelte'
  import ExtBadge from './ExtBadge.svelte'
  import FavoriteButton from './FavoriteButton.svelte'
  import { metadataMatch } from './metadata.svelte'
  import { tagEditor } from './tags.svelte'
  import { library, type AlbumRow, type TrackRow } from './library.svelte'
  import { pinned } from './pinned.svelte'
  import { player, formatTime, randomTrackIndex } from './player.svelte'
  import { tintFrom } from './tint'
  import { trackMenu } from './contextMenu.svelte'
  import type { Rgb } from './nowCover.svelte'

  let { albumId, onBack }: { albumId: number; onBack: () => void } = $props()

  let data = $state<{ album: AlbumRow; tracks: TrackRow[] } | null>(null)

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

  const currentPath = $derived(player.snapshot.current?.path ?? null)

  // Header on the album cover's colour.
  let color = $state<Rgb | null>(null)
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

  let choosingPlaylist = $state(false)
  const totalMs = $derived(data ? data.tracks.reduce((sum, tr) => sum + (tr.durationMs ?? 0), 0) : 0)
  function hoursMins(ms: number): string {
    const totalMin = Math.round(ms / 60_000)
    if (totalMin < 1) return t('< 1 min')
    const h = Math.floor(totalMin / 60)
    const m = totalMin % 60
    return h === 0 ? t('{m} min', { m }) : t('{h} hr {m} min', { h, m })
  }
  // #, title, plays, save, length, "…" (header and rows share it).
  const ROW_COLS =
    'grid grid-cols-[2rem_minmax(0,1fr)_minmax(4rem,12rem)_2rem_3.5rem_2rem] items-center gap-x-4'
  const menuItem =
    'flex w-full items-center gap-2.5 px-3 py-2 text-left outline-none hover:bg-zinc-100 focus-visible:bg-zinc-100 dark:hover:bg-zinc-800 dark:focus-visible:bg-zinc-800'
</script>

<div class="h-full overflow-y-auto pb-6">
  {#if data}
    <CollectionHeader
      top={tint.top}
      surface={tint.surface}
      label={t('Album')}
      titleText={data.album.title}
      {onBack}
      backLabel={t('Albums')}
    >
      {#snippet cover()}
        <Cover cover={data!.album.cover} title={data!.album.title} class="size-52 rounded-md text-6xl shadow-2xl shadow-black/50 xl:size-56" />
      {/snippet}
      {#snippet meta()}
        <span class="font-bold text-white"><ArtistLinks artist={data!.album.albumArtist} onNavigate={onBack} /></span>
        {#if data!.album.year}<span aria-hidden="true">•</span><span>{data!.album.year}</span>{/if}
        <span aria-hidden="true">•</span>
        <span>{count(data!.album.trackCount, '{n} song', '{n} songs')}{totalMs > 0 ? `, ${hoursMins(totalMs)}` : ''}</span>
      {/snippet}
      {#snippet actions()}
        <button
          type="button"
          class="flex size-14 items-center justify-center rounded-full bg-accent-500 text-zinc-950 shadow-lg shadow-black/30 outline-none transition hover:scale-105 hover:bg-accent-400 focus-visible:ring-2 focus-visible:ring-white/80 disabled:opacity-50"
          aria-label={t(player.isActiveFrom(`album:${albumId}`) ? 'Pause' : 'Play')}
          title={t(player.isActiveFrom(`album:${albumId}`) ? 'Pause' : 'Play')}
          disabled={data!.tracks.length === 0}
          onclick={() => player.playOrToggle(`album:${albumId}`, () => library.playAlbum(albumId, 0, false))}
        >
          <Icon name={player.isActiveFrom(`album:${albumId}`) ? 'pause' : 'play'} class="size-7" />
        </button>
        <ShuffleButton
          disabled={data!.tracks.length === 0}
          onClick={() => void library.playAlbum(albumId, randomTrackIndex(data!.tracks.length), true)}
        />
        <button
          type="button"
          aria-pressed={pinned.isPinned('album', albumId)}
          aria-label={t(pinned.isPinned('album', albumId) ? 'Unpin' : 'Pin')}
          title={t(pinned.isPinned('album', albumId) ? 'Unpin' : 'Pin')}
          class={[
            'rounded-full p-2 outline-none transition focus-visible:ring-2 focus-visible:ring-white/70',
            pinned.isPinned('album', albumId) ? 'text-accent-400 hover:text-accent-300' : 'text-white/70 hover:text-white',
          ]}
          onclick={() => void pinned.toggle('album', albumId)}
        >
          <Icon name="pin" class="size-6" />
        </button>
        <ActionsMenu label={t('More actions for “{title}”', { title: data!.album.title })}>
          {#snippet children(close)}
            <button
              type="button"
              role="menuitem"
              aria-expanded={choosingPlaylist}
              class={[menuItem, 'justify-between']}
              onclick={() => (choosingPlaylist = !choosingPlaylist)}
            >
              <span class="flex items-center gap-2.5"><Icon name="plus" class="size-4 text-zinc-500" />{t('Add to playlist')}</span>
              <Icon name="chevronRight" class={['size-4 text-zinc-400 transition-transform', choosingPlaylist && 'rotate-90'].filter(Boolean).join(' ')} />
            </button>
            {#if choosingPlaylist}
              <div class="mx-2 mb-1 max-h-48 overflow-y-auto rounded-lg bg-zinc-100/70 py-1 dark:bg-zinc-800/60">
                <button
                  type="button"
                  role="menuitem"
                  class={[menuItem, 'text-accent-700 dark:text-accent-300']}
                  onclick={async () => {
                    close()
                    const made = await playlists.create(t('My playlist #{n}', { n: playlists.list.length + 1 }))
                    if (made) await playlists.addAlbum(made, albumId)
                  }}
                >
                  <Icon name="plus" class="size-4" />{t('New playlist')}
                </button>
                {#each playlists.list as p (p.id)}
                  <button
                    type="button"
                    role="menuitem"
                    class={menuItem}
                    onclick={() => {
                      close()
                      void playlists.addAlbum(p, albumId)
                    }}
                  >
                    <span class="truncate">{p.name}</span>
                  </button>
                {/each}
              </div>
            {/if}
            <button
              type="button"
              role="menuitem"
              class={menuItem}
              onclick={() => {
                close()
                tagEditor.open(data!.tracks.map((track) => track.id), t('Edit album tags'))
              }}
            >
              <Icon name="sliders" class="size-4 text-zinc-500" />{t('Edit tags…')}
            </button>
            <button
              type="button"
              role="menuitem"
              class={[menuItem, 'disabled:opacity-50']}
              disabled={!appSettings.allowMetadata}
              title={appSettings.allowMetadata ? undefined : t('Turned off in Settings')}
              onclick={() => {
                close()
                metadataMatch.openAlbum(albumId)
              }}
            >
              <Icon name="search" class="size-4 text-zinc-500" />{t('Find info')}
            </button>
          {/snippet}
        </ActionsMenu>
      {/snippet}
    </CollectionHeader>
    <div class="px-5">
    <!-- Columns like Spotify's album list: #, title, plays, then save,
         length and "…". The header names them. -->
    <div class={[ROW_COLS, 'border-b border-zinc-200 px-3 pb-2 text-xs font-medium tracking-wide text-zinc-400 uppercase dark:border-zinc-800']}>
      <span class="text-right">#</span>
      <span>{t('Title')}</span>
      <span>{t('Plays')}</span>
      <span></span>
      <span class="text-right">{t('Time')}</span>
      <span></span>
    </div>
    <ol class="mt-1">
      {#each data.tracks as track, i (track.id)}
        <li
          class={[
            ROW_COLS,
            'group h-12 rounded-md px-3 text-sm',
            selection.has(`album:${albumId}`, track.path)
              ? 'bg-accent-500/20 text-zinc-900 dark:bg-accent-400/20 dark:text-white'
              : track.path === currentPath
                ? 'bg-accent-50 text-accent-900 dark:bg-accent-950/40 dark:text-accent-100'
                : 'text-zinc-700 hover:bg-zinc-100/70 dark:text-zinc-300 dark:hover:bg-zinc-800/50',
          ]}
          oncontextmenu={(e) =>
            trackMenu.fromEvent(e, track, { onPlay: () => void library.playAlbum(albumId, i) })}
        >
          <button
            class="col-span-3 grid h-full grid-cols-subgrid items-center text-left outline-none focus-visible:ring-2 focus-visible:ring-accent-500"
            aria-pressed={selection.has(`album:${albumId}`, track.path)}
            onclick={(e) => {
              if (!selection.click(e, `album:${albumId}`, i, track, (j) => data?.tracks[j])) {
                library.playAlbum(albumId, i)
              }
            }}
            onkeydown={(e) => selection.key(e, `album:${albumId}`, data?.tracks.length ?? 0, (j) => data?.tracks[j])}
          >
            <span class="text-right text-sm tabular-nums text-zinc-400">
              {#if track.path === currentPath && player.snapshot.status === 'playing'}
                <Equalizer class="ml-auto text-accent-600 dark:text-accent-400" />
              {:else}
                {track.trackNo ?? i + 1}
              {/if}
            </span>
            <span class="flex min-w-0 items-center">
              <span class={['truncate font-medium', track.path === currentPath && 'text-accent-600 dark:text-accent-400']}>{track.title}</span><ExtBadge path={track.path} />
            </span>
            <span class="text-sm tabular-nums text-zinc-500">
              {track.plays.toLocaleString(i18n.locale)}
            </span>
          </button>
          <span class="flex justify-center">
            <FavoriteButton trackId={track.id} title={track.title} revealOnHover />
          </span>
          <span class="text-right text-sm tabular-nums text-zinc-500">
            {formatTime(track.durationMs === null ? null : track.durationMs / 1000)}
          </span>
          <span class="flex justify-end opacity-0 group-focus-within:opacity-100 group-hover:opacity-100 pointer-coarse:opacity-100">
            <AddToPlaylist
              trackIds={[track.id]}
              {track}
              editTags
              onPlay={() => void library.playAlbum(albumId, i)}
              label={t('More actions for “{title}”', { title: track.title })}
            />
          </span>
        </li>
      {/each}
    </ol>
    </div>
  {:else}
    <p class="p-5 text-zinc-500">{t("Loading…")}</p>
  {/if}
</div>

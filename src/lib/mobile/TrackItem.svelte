<script lang="ts">
  import { t } from '../i18n.svelte'
  import AlbumLink from '../AlbumLink.svelte'
  import ArtistLinks from '../ArtistLinks.svelte'
  import Cover from '../Cover.svelte'
  import Equalizer from '../Equalizer.svelte'
  import FavoriteButton from '../FavoriteButton.svelte'
  import AddToPlaylist from '../AddToPlaylist.svelte'
  import type { TrackRow } from '../library.svelte'
  import { player } from '../player.svelte'
  import Icon from '../Icon.svelte'
  import { longPress, selection } from '../trackSelection.svelte'

  // One song row on phones: cover, title, clickable artist · album links, and a menu.
  let {
    title,
    subtitle = '',
    path,
    cover = null,
    trackId = null,
    track = null,
    artist,
    album,
    albumId,
    extraMeta = '',
    number = null,
    selectScope = null,
    index = 0,
    onPlay,
    onRemoveFromPlaylist,
  }: {
    title: string
    subtitle?: string
    path: string
    cover?: string | null
    trackId?: number | null
    track?: TrackRow | null
    artist?: string
    album?: string
    albumId?: number | null
    extraMeta?: string
    /** Show a track number instead of the cover (album pages). */
    number?: number | null
    /** Enables multi-select (long press) in this list; `index` orders it. */
    selectScope?: string | null
    index?: number
    onPlay: () => void
    /** On a playlist page: the menu offers "Remove from this playlist". */
    onRemoveFromPlaylist?: () => void
  } = $props()

  const selectable = $derived(selectScope !== null && track !== null)
  const selecting = $derived(selectable && selection.touchMode && selection.scope === selectScope)
  const picked = $derived(selectable && selection.has(selectScope!, path))

  function activate() {
    if (selecting && track) selection.tap(selectScope!, index, track)
    else onPlay()
  }

  function press() {
    if (selectable && track) selection.start(selectScope!, index, track)
  }

  const effArtist = $derived(artist !== undefined ? artist : (track?.artist ?? ''))
  const effAlbum = $derived(album !== undefined ? album : (track?.album ?? ''))
  const effAlbumId = $derived(albumId !== undefined ? albumId : (track?.albumId ?? null))
  const useLinks = $derived(effArtist !== '' || effAlbum !== '')

  const current = $derived(player.snapshot.current?.path === path)
  const playing = $derived(current && player.snapshot.status === 'playing')
</script>

<div class={['flex h-16 items-center gap-3 pr-1 pl-4 active:bg-white/5', picked && 'bg-accent-500/15']}>
  <div
    role="button"
    tabindex="0"
    aria-pressed={selecting ? picked : undefined}
    class="flex min-w-0 flex-1 items-center gap-3 text-left outline-none"
    use:longPress={press}
    onclick={activate}
    onkeydown={(e) => e.target === e.currentTarget && e.key === 'Enter' && activate()}
  >
    {#if selecting}
      <span
        class={[
          'flex size-6 shrink-0 items-center justify-center rounded-full border-2',
          picked ? 'border-accent-400 bg-accent-400 text-zinc-950' : 'border-zinc-500',
        ]}
        aria-hidden="true"
      >
        {#if picked}<Icon name="check" class="size-4" />{/if}
      </span>
    {/if}
    {#if number !== null}
      <span class={['w-6 shrink-0 text-center text-sm tabular-nums', current ? 'text-accent-400' : 'text-zinc-500']}>
        {#if playing}<Equalizer />{:else}{number}{/if}
      </span>
    {:else}
      <span class="relative shrink-0">
        <Cover {cover} {title} class="size-12 rounded text-sm" />
        {#if playing}
          <span class="absolute inset-0 flex items-center justify-center rounded bg-black/50 text-accent-300">
            <Equalizer />
          </span>
        {/if}
      </span>
    {/if}
    <span class="min-w-0 flex-1">
      <span class={['block truncate text-[15px] leading-tight', current ? 'text-accent-400' : 'text-zinc-50']}>{title}</span>
      <span class="mt-1 block truncate text-[13px] leading-tight text-zinc-400">
        {#if useLinks}
          {#if extraMeta}{extraMeta}{#if effArtist || effAlbum} · {/if}{/if}{#if effArtist}<ArtistLinks
              artist={effArtist}
              linkClass="hover:text-accent-400 active:underline"
            />{/if}{#if effArtist && effAlbum} · {/if}{#if effAlbum}<AlbumLink
              album={effAlbum}
              albumId={effAlbumId}
              linkClass="hover:text-accent-400 active:underline"
            />{/if}
        {:else}
          {subtitle}
        {/if}
      </span>
    </span>
  </div>
  {#if trackId !== null && !selecting}
    <FavoriteButton {trackId} {title} size="size-5" light />
    <AddToPlaylist
      trackIds={[trackId]}
      {track}
      {onPlay}
      {onRemoveFromPlaylist}
      editTags
      label={t('More actions for “{title}”', { title })}
      class="p-3 text-zinc-400"
    />
  {/if}
</div>

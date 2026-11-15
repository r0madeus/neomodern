<script lang="ts">
  import Cover from '../Cover.svelte'
  import Icon from '../Icon.svelte'
  import PlaylistCover from '../PlaylistCover.svelte'
  import { artists, type ArtistRow } from '../artists.svelte'
  import { favorites } from '../favorites.svelte'
  import { count, i18n, t } from '../i18n.svelte'
  import { library, type AlbumRow } from '../library.svelte'
  import { pinned } from '../pinned.svelte'
  import { playlists } from '../playlists.svelte'
  import { portal } from '../portal'

  // Songs, Albums, Artists and the stats are on Home and in the chips
  // here; music folders are at the top of Settings; importing is under +.
  let {
    onOpenPlaylist,
    onOpenFavorites,
    onOpenAlbum,
    onOpenArtist,
    onOpenPage,
  }: {
    onOpenPlaylist: (id: number) => void
    onOpenFavorites: () => void
    onOpenAlbum: (albumId: number) => void
    onOpenArtist: (name: string) => void
    onOpenPage: (page: 'folders' | 'settings') => void
  } = $props()

  const VIEW_KEY = 'neomodern.mobile.libraryView'
  type ViewMode = 'grid' | 'list'
  type FilterKind = 'all' | 'playlists' | 'albums' | 'artists'
  type SortMode = 'recents' | 'alpha'

  function loadViewMode(): ViewMode {
    try {
      const v = localStorage.getItem(VIEW_KEY)
      if (v === 'list' || v === 'grid') return v
    } catch {
      // ignore unavailable storage
    }
    return 'grid'
  }

  let viewMode = $state<ViewMode>(loadViewMode())
  let filterKind = $state<FilterKind>('all')
  let sortMode = $state<SortMode>('recents')
  let searching = $state(false)
  let query = $state('')
  let createOpen = $state(false)
  let albumRows = $state<AlbumRow[]>([])
  let artistRows = $state<ArtistRow[]>([])

  $effect(() => {
    void library.stats.version
    let stale = false
    Promise.all([library.albumsPage('')(0, 200), artists.page('')(0, 200)])
      .then(([albs, arts]) => {
        if (stale) return
        albumRows = albs.items
        artistRows = arts.items
      })
      .catch(() => {})
    return () => {
      stale = true
    }
  })

  function toggleViewMode() {
    viewMode = viewMode === 'grid' ? 'list' : 'grid'
    try {
      localStorage.setItem(VIEW_KEY, viewMode)
    } catch {
      // ignore unavailable storage
    }
  }

  function toggleFilter(kind: Exclude<FilterKind, 'all'>) {
    filterKind = filterKind === kind ? 'all' : kind
  }

  // Like Spotify: a numbered playlist is made and opened; rename it there.
  async function create() {
    createOpen = false
    const made = await playlists.create(t('My playlist #{n}', { n: playlists.list.length + 1 }))
    if (made) onOpenPlaylist(made.id)
  }

  async function importM3u() {
    createOpen = false
    const made = await playlists.importM3u()
    if (made) onOpenPlaylist(made.id)
  }

  type LibraryItem =
    | {
        key: string
        kind: 'favorites'
        title: string
        subtitle: string
        pinned: true
        accentTitle: true
        onOpen: () => void
      }
    | {
        key: string
        kind: 'playlist'
        title: string
        subtitle: string
        pinned: boolean
        accentTitle: false
        cover: string | null
        albumCovers: string[]
        onOpen: () => void
      }
    | {
        key: string
        kind: 'album'
        title: string
        subtitle: string
        pinned: boolean
        accentTitle: false
        cover: string | null
        onOpen: () => void
      }
    | {
        key: string
        kind: 'artist'
        title: string
        subtitle: string
        pinned: boolean
        accentTitle: false
        cover: string | null
        onOpen: () => void
      }

  const items = $derived.by<LibraryItem[]>(() => {
    const out: LibraryItem[] = []
    const q = query.trim().toLowerCase()
    const matches = (text: string, sub = '') =>
      q === '' || text.toLowerCase().includes(q) || sub.toLowerCase().includes(q)

    if (filterKind === 'all' || filterKind === 'playlists') {
      const favSub = t('Playlist')
      if (matches(t('Favorites'), favSub)) {
        out.push({
          key: 'favorites',
          kind: 'favorites',
          title: t('Favorites'),
          subtitle: favSub,
          pinned: true,
          accentTitle: true,
          onOpen: onOpenFavorites,
        })
      }
      for (const p of playlists.list) {
        const sub = t('Playlist')
        if (!matches(p.name, sub)) continue
        out.push({
          key: `playlist:${p.id}`,
          kind: 'playlist',
          title: p.name,
          subtitle: sub,
          pinned: pinned.isPinned('playlist', p.id),
          accentTitle: false,
          cover: p.cover,
          albumCovers: p.albumCovers,
          onOpen: () => onOpenPlaylist(p.id),
        })
      }
    }

    if (filterKind === 'all' || filterKind === 'albums') {
      for (const a of albumRows) {
        const sub = t('Album · {details}', { details: a.albumArtist })
        if (!matches(a.title, a.albumArtist)) continue
        out.push({
          key: `album:${a.id}`,
          kind: 'album',
          title: a.title,
          subtitle: sub,
          pinned: pinned.isPinned('album', a.id),
          accentTitle: false,
          cover: a.cover,
          onOpen: () => onOpenAlbum(a.id),
        })
      }
    }

    if (filterKind === 'all' || filterKind === 'artists') {
      const sub = t('Artist')
      for (const ar of artistRows) {
        if (!matches(ar.name, sub)) continue
        out.push({
          key: `artist:${ar.name}`,
          kind: 'artist',
          title: ar.name,
          subtitle: sub,
          pinned: false,
          accentTitle: false,
          cover: ar.cover,
          onOpen: () => onOpenArtist(ar.name),
        })
      }
    }

    if (sortMode === 'alpha') {
      out.sort((a, b) => a.title.localeCompare(b.title, i18n.locale))
    } else {
      const rank = (it: LibraryItem) => {
        if (it.kind === 'favorites') return 0
        if (it.pinned) return 1
        if (it.kind === 'playlist') return 2
        if (it.kind === 'album') return 3
        return 4
      }
      out.sort((a, b) => rank(a) - rank(b))
    }
    return out
  })
</script>

<div class="flex h-full flex-col">
  <!-- Spotify-style Your Library header -->
  <header class="shrink-0 px-4 pt-3.5 pb-2">
    <div class="flex items-center gap-3">
      <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-zinc-800 text-accent-400">
        <Icon name="library" class="size-4" />
      </span>
      <h1 class="min-w-0 flex-1 truncate text-2xl font-bold tracking-tight">
        {t('Your Library')}
      </h1>
      <button
        type="button"
        class="rounded-full p-2 text-zinc-200 active:bg-white/10"
        aria-label={t('Search your library')}
        onclick={() => {
          searching = !searching
          if (!searching) query = ''
        }}
      >
        <Icon name="search" class="size-6" />
      </button>
      <button
        type="button"
        class="rounded-full p-2 text-zinc-200 active:bg-white/10"
        aria-label={t('Create')}
        aria-haspopup="menu"
        aria-expanded={createOpen}
        onclick={() => (createOpen = true)}
      >
        <Icon name="plus" class="size-6" />
      </button>
      <button
        type="button"
        class="-mr-2 rounded-full p-2 text-zinc-400 active:bg-white/10"
        aria-label={t('Settings')}
        onclick={() => onOpenPage('settings')}
      >
        <Icon name="settings" class="size-5" />
      </button>
    </div>

    <!-- Filter chips -->
    <div class="mt-3 flex items-center gap-2 overflow-x-auto pb-1 no-scrollbar">
      {#if filterKind !== 'all'}
        <button
          type="button"
          class="flex size-8 shrink-0 items-center justify-center rounded-full bg-zinc-800 text-zinc-200 active:bg-zinc-700"
          aria-label={t('Clear filter')}
          onclick={() => (filterKind = 'all')}
        >
          <Icon name="close" class="size-4" />
        </button>
      {/if}
      {#each [
        { id: 'playlists', label: 'Playlists' },
        { id: 'albums', label: 'Albums' },
        { id: 'artists', label: 'Artists' },
      ] as const as chip (chip.id)}
        <button
          type="button"
          class={[
            'shrink-0 rounded-full px-3.5 py-1.5 text-[13px] font-medium transition',
            filterKind === chip.id
              ? 'bg-accent-500 font-semibold text-zinc-950'
              : 'bg-zinc-800/90 text-zinc-100 active:bg-zinc-700',
          ]}
          onclick={() => toggleFilter(chip.id)}
        >
          {t(chip.label)}
        </button>
      {/each}
    </div>
  </header>

  <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
    {#if searching}
      <div class="px-4 pt-1 pb-2.5">
        <div class="relative flex items-center">
          <Icon name="search" class="pointer-events-none absolute left-3 size-4 text-zinc-400" />
          <input
            type="search"
            bind:value={query}
            placeholder={t('Filter your library…')}
            aria-label={t('Filter your library…')}
            class="h-10 w-full rounded-full bg-zinc-800/90 pr-9 pl-9 text-sm text-zinc-100 outline-none placeholder:text-zinc-400 focus:ring-2 focus:ring-accent-500"
            {@attach (el) => el.focus()}
          />
          {#if query}
            <button
              type="button"
              aria-label={t('Clear search')}
              class="absolute right-2 rounded-full p-1 text-zinc-400 active:bg-white/10"
              onclick={() => (query = '')}
            >
              <Icon name="close" class="size-4" />
            </button>
          {/if}
        </div>
      </div>
    {/if}


    {#if library.scanning}
      <p class="flex items-center gap-2 px-4 pb-2 text-sm text-accent-400" role="status">
        <span class="size-2 animate-pulse rounded-full bg-accent-400"></span>
        {library.scan
          ? t('Scanning · {n} files', { n: library.scan.scanned.toLocaleString(i18n.locale) })
          : t('Scanning…')}
      </p>
    {/if}

    <!-- Sort + Grid/List view bar -->
    <div class="flex items-center justify-between px-4 py-2">
      <button
        type="button"
        class="flex items-center gap-1.5 py-1 text-[13px] font-medium text-zinc-200 active:opacity-70"
        aria-label={t('Toggle sort')}
        onclick={() => (sortMode = sortMode === 'recents' ? 'alpha' : 'recents')}
      >
        <Icon name="sort" class="size-4 text-zinc-300" />
        {t(sortMode === 'recents' ? 'Recents' : 'Alphabetical')}
      </button>
      <button
        type="button"
        class="-mr-1.5 rounded-full p-1.5 text-zinc-200 active:bg-white/10"
        aria-label={t(viewMode === 'grid' ? 'List view' : 'Grid view')}
        onclick={toggleViewMode}
      >
        <Icon name={viewMode === 'grid' ? 'list' : 'grid'} class="size-5" />
      </button>
    </div>

    <!-- Unified library items in Grid (3-col) or List view -->
    {#if items.length === 0}
      <p class="px-4 py-8 text-center text-sm text-zinc-400">
        {query.trim() ? t('No results for “{q}”', { q: query.trim() }) : t('Your library is empty.')}
      </p>
    {:else if viewMode === 'grid'}
      <div class="grid grid-cols-3 gap-x-3 gap-y-4 px-4 pt-1">
        {#each items as item (item.key)}
          <button
            type="button"
            class="flex min-w-0 flex-col text-left active:opacity-80"
            onclick={item.onOpen}
          >
            {#if item.kind === 'favorites'}
              <span class="flex aspect-square w-full items-center justify-center rounded-md bg-gradient-to-br from-indigo-600 via-accent-500 to-accent-300 text-white shadow-sm">
                <Icon name="star" class="size-10" />
              </span>
            {:else if item.kind === 'playlist'}
              <PlaylistCover
                cover={item.cover}
                albumCovers={item.albumCovers}
                name={item.title}
                class="aspect-square w-full rounded-md text-xl"
                iconClass="size-8"
              />
            {:else if item.kind === 'artist'}
              <Cover
                cover={item.cover}
                title={item.title}
                class="aspect-square w-full rounded-full text-xl"
              />
            {:else}
              <Cover
                cover={item.cover}
                title={item.title}
                class="aspect-square w-full rounded-md text-xl"
              />
            {/if}

            <span
              class={[
                'mt-2 line-clamp-2 text-[13px] leading-snug font-medium',
                item.accentTitle ? 'text-accent-400' : 'text-zinc-100',
              ]}
            >
              {item.title}
            </span>
            <span class="mt-0.5 flex items-center gap-1 truncate text-[11px] text-zinc-400">
              {#if item.pinned}
                <Icon name="pin" class="size-3 shrink-0 rotate-45 text-accent-400" />
              {/if}
              <span class="truncate">{item.subtitle}</span>
            </span>
          </button>
        {/each}
      </div>
    {:else}
      <div class="flex flex-col px-4 pt-1">
        {#each items as item (item.key)}
          <button
            type="button"
            class="flex items-center gap-3 rounded-lg py-1.5 text-left active:bg-white/5"
            onclick={item.onOpen}
          >
            {#if item.kind === 'favorites'}
              <span class="flex size-15 shrink-0 items-center justify-center rounded bg-gradient-to-br from-indigo-600 via-accent-500 to-accent-300 text-white">
                <Icon name="star" class="size-7" />
              </span>
            {:else if item.kind === 'playlist'}
              <PlaylistCover
                cover={item.cover}
                albumCovers={item.albumCovers}
                name={item.title}
                class="size-15 shrink-0 rounded text-lg"
                iconClass="size-6"
              />
            {:else if item.kind === 'artist'}
              <Cover
                cover={item.cover}
                title={item.title}
                class="size-15 shrink-0 rounded-full text-lg"
              />
            {:else}
              <Cover
                cover={item.cover}
                title={item.title}
                class="size-15 shrink-0 rounded text-lg"
              />
            {/if}

            <span class="min-w-0 flex-1">
              <span
                class={[
                  'block truncate text-[15px] font-medium',
                  item.accentTitle ? 'text-accent-400' : 'text-zinc-100',
                ]}
              >
                {item.title}
              </span>
              <span class="mt-0.5 flex items-center gap-1 truncate text-[13px] text-zinc-400">
                {#if item.pinned}
                  <Icon name="pin" class="size-3.5 shrink-0 rotate-45 text-accent-400" />
                {/if}
                <span class="truncate">{item.subtitle}</span>
              </span>
            </span>
          </button>
        {/each}
      </div>
    {/if}

  </div>
</div>

{#if createOpen}
  <!-- Spotify-style "+" sheet, above the mini player and the tabs. -->
  <div use:portal class="fixed inset-0 z-[60] flex items-end bg-black/60" role="presentation" onclick={() => (createOpen = false)}>
    <div
      role="menu"
      tabindex="-1"
      class="w-full rounded-t-2xl bg-zinc-900 px-2 pt-2 pb-[calc(1rem+var(--inset-bottom,0px))] text-zinc-100 shadow-2xl"
      onclick={(e) => e.stopPropagation()}
      onkeydown={(e) => e.key === 'Escape' && (createOpen = false)}
    >
      <div class="mx-auto mb-2 h-1 w-10 rounded-full bg-zinc-600"></div>
      <button type="button" role="menuitem" class="flex w-full items-center gap-4 rounded-lg px-3 py-3 text-left active:bg-white/5" onclick={() => void create()}>
        <span class="flex size-11 shrink-0 items-center justify-center rounded-full bg-zinc-800">
          <Icon name="queue" class="size-5" />
        </span>
        <span class="min-w-0 flex-1">
          <span class="block text-[15px] font-medium">{t('Playlist')}</span>
          <span class="block text-xs text-zinc-400">{t('Build a playlist with songs')}</span>
        </span>
      </button>
      <button type="button" role="menuitem" class="flex w-full items-center gap-4 rounded-lg px-3 py-3 text-left active:bg-white/5" onclick={() => void importM3u()}>
        <span class="flex size-11 shrink-0 items-center justify-center rounded-full bg-zinc-800">
          <Icon name="upload" class="size-5" />
        </span>
        <span class="min-w-0 flex-1">
          <span class="block text-[15px] font-medium">{t('Import playlist')}</span>
          <span class="block text-xs text-zinc-400">{t('An M3U file exported from NeoModern on another device')}</span>
        </span>
      </button>
    </div>
  </div>
{/if}

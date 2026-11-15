<script lang="ts">
  import { pinned } from './pinned.svelte'
  import { invoke } from '@tauri-apps/api/core'
  import { tick } from 'svelte'
  import Icon from './Icon.svelte'
  import { appSettings } from './appSettings.svelte'
  import { artists, splitArtistNames } from './artists.svelte'
  import { favorites } from './favorites.svelte'
  import { count, t } from './i18n.svelte'
  import { library } from './library.svelte'
  import { player } from './player.svelte'
  import { playlists, type PlaylistInfo } from './playlists.svelte'
  import { tagEditor } from './tags.svelte'
  import { trackMenu } from './contextMenu.svelte'
  import Cover from './Cover.svelte'
  import SaveToMenu from './SaveToMenu.svelte'
  import { popLayer, pushLayer } from './mobile/layers'
  import { fade, fly } from 'svelte/transition'
  import { motionDuration } from './motion'

  const WIDTH = 228
  const SUB_WIDTH = 220

  let menu = $state<HTMLDivElement | null>(null)
  let submenuEl = $state<HTMLDivElement | null>(null)
  let sub = $state<'playlists' | 'artists' | 'sleep' | null>(null)
  let creating = $state(false)
  let playlistName = $state('')
  let pos = $state({ left: 0, top: 0 })
  let subPos = $state({ left: 0, top: 0 })

  const ctx = $derived(trackMenu.current)
  const artistList = $derived(ctx ? splitArtistNames(ctx.track.artist) : [])
  const hasLibId = $derived(ctx ? ctx.track.id > 0 : false)
  const hasAlbum = $derived(ctx ? ctx.track.albumId !== null : false)
  const isLocal = $derived(
    ctx ? !ctx.track.path.startsWith('http://') && !ctx.track.path.startsWith('https://') : false,
  )
  const canReveal = $derived(appSettings.platform !== 'android' && isLocal)
  const starred = $derived(
    ctx ? (ctx.track.id > 0 ? favorites.has(ctx.track.id) : favorites.hasPath(ctx.track.path)) : false,
  )

  function portal(node: HTMLElement) {
    document.body.appendChild(node)
    return { destroy: () => node.remove() }
  }

  // Phones get Spotify's bottom sheet instead of the popup menu: half open
  // at first, scroll up for the rest, drag down or Back to close.
  const NARROW = '(max-width: 639px)'
  let mobile = $state(window.matchMedia(NARROW).matches)
  $effect(() => {
    const mq = window.matchMedia(NARROW)
    const onChange = () => (mobile = mq.matches)
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  })
  // The sheet is a history layer so Android's Back closes it.
  let layerOpen = false
  $effect(() => {
    if (!ctx || !mobile || layerOpen) return
    layerOpen = true
    pushLayer(() => {
      layerOpen = false
      sub = null
      trackMenu.close()
    })
  })

  /** Closes the menu; `then` runs after it is gone (on phones the sheet's
   *  history layer must be popped before another screen opens). */
  function close(then?: () => void) {
    sub = null
    creating = false
    playlistName = ''
    trackMenu.close()
    if (layerOpen) {
      layerOpen = false
      popLayer(then)
    } else {
      then?.()
    }
  }

  // "Add to playlist" on a phone opens the save sheet (playlists, new
  // playlist, favourites) once the menu is closed.
  let saveFor = $state<{ trackId: number; title: string } | null>(null)
  function openSave() {
    const c = ctx
    if (!c || c.track.id <= 0) return
    saveFor = { trackId: c.track.id, title: c.track.title }
    close()
  }

  function goQueue() {
    close(() => trackMenu.openQueue())
  }

  // Drag down from the top of the sheet to close it.
  let scroller = $state<HTMLDivElement | null>(null)
  let pullY = $state(0)
  let pullStart: number | null = null
  function onSheetTouchStart(e: TouchEvent) {
    pullStart = scroller && scroller.scrollTop <= 0 ? e.touches[0].clientY : null
  }
  function onSheetTouchMove(e: TouchEvent) {
    if (pullStart === null) return
    const dy = e.touches[0].clientY - pullStart
    pullY = dy > 0 ? dy : 0
  }
  function onSheetTouchEnd() {
    if (pullY > 90) close()
    pullY = 0
    pullStart = null
  }

  function items(): HTMLElement[] {
    return menu ? [...menu.querySelectorAll<HTMLElement>('[role="menuitem"]')] : []
  }

  $effect(() => {
    const c = ctx
    if (!c) {
      sub = null
      creating = false
      playlistName = ''
      return
    }
    sub = null
    creating = false
    playlistName = ''
    void tick().then(() => {
      if (!menu) return
      const w = menu.offsetWidth || WIDTH
      const h = menu.offsetHeight || 280
      const rawLeft = c.alignRight ? c.x - w : c.x
      const left = Math.max(8, Math.min(rawLeft, window.innerWidth - w - 8))
      const top = Math.max(8, Math.min(c.y, window.innerHeight - h - 8))
      pos = { left, top }
      menu.focus()
    })
  })

  function openSub(kind: 'playlists' | 'artists' | 'sleep', rowEl?: HTMLElement | null) {
    sub = kind
    creating = false
    const menuRect = menu?.getBoundingClientRect()
    const rowRect = rowEl?.getBoundingClientRect()
    const rightSpace = window.innerWidth - ((menuRect?.right ?? pos.left + WIDTH) + 4)
    const left =
      rightSpace >= SUB_WIDTH + 8
        ? (menuRect?.right ?? pos.left + WIDTH) + 4
        : Math.max(8, (menuRect?.left ?? pos.left) - SUB_WIDTH - 4)
    const rawTop = rowRect?.top ?? pos.top
    const top = Math.max(8, Math.min(rawTop, window.innerHeight - 280 - 8))
    subPos = { left, top }
  }

  $effect(() => {
    if (!ctx) return
    const onPointer = (e: PointerEvent) => {
      const target = e.target as Node
      if (!menu?.contains(target) && !submenuEl?.contains(target)) close()
    }
    const onScroll = (e: Event) => {
      const target = e.target as Node
      if (!menu?.contains(target) && !submenuEl?.contains(target)) close()
    }
    const onResize = () => close()
    window.addEventListener('pointerdown', onPointer, true)
    window.addEventListener('scroll', onScroll, true)
    window.addEventListener('resize', onResize)
    return () => {
      window.removeEventListener('pointerdown', onPointer, true)
      window.removeEventListener('scroll', onScroll, true)
      window.removeEventListener('resize', onResize)
    }
  })

  // Submenus are portaled outside the menu element, so Escape needs its own handler there.
  function onSubKey(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault()
      e.stopPropagation()
      close()
    }
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault()
      e.stopPropagation()
      close()
    } else if (e.key === 'Tab') {
      close()
    } else if (!creating && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
      e.preventDefault()
      const list = items()
      const at = list.indexOf(document.activeElement as HTMLElement)
      const next =
        e.key === 'ArrowDown' ? (at + 1) % list.length : (at - 1 + list.length) % list.length
      list[next]?.focus()
    }
  }

  async function doPlay() {
    const c = ctx
    if (!c) return
    close()
    // No fallback: replacing the whole queue with one song would be surprising.
    c.onPlay?.()
  }

  async function doPlayNext() {
    const c = ctx
    if (!c) return
    close()
    await player.playNext(c.track.path)
    playlists.flash(t('Queued to play next'))
  }

  async function doAddQueue() {
    const c = ctx
    if (!c) return
    close()
    await player.appendFiles([c.track.path])
    playlists.flash(t('Added to queue'))
  }

  async function doToggleFavorite() {
    const c = ctx
    if (!c) return
    close()
    if (c.track.id > 0) await favorites.toggle(c.track.id)
    else await favorites.toggleByPath(c.track.path)
  }

  async function addToPlaylist(p: PlaylistInfo) {
    const c = ctx
    if (!c || c.track.id <= 0) return
    close()
    await playlists.addTracks(p, [c.track.id])
  }

  async function startCreate() {
    creating = true
    await tick()
    submenuEl?.querySelector<HTMLInputElement>('input')?.focus()
  }

  async function createPlaylist() {
    const c = ctx
    const trimmed = playlistName.trim()
    if (!c || c.track.id <= 0 || trimmed === '') return
    const made = await playlists.create(trimmed, [c.track.id])
    close()
    if (made) {
      playlists.flash(
        t('Added {count} to new playlist “{name}”', {
          count: count(1, '{n} track', '{n} tracks'),
          name: made.name,
        }),
      )
    }
  }

  function goArtist(name?: string) {
    const target = name ?? artistList[0]
    if (!target) return
    close(() => artists.open(target))
  }

  function goAlbum() {
    const albumId = ctx?.track.albumId
    if (albumId === null || albumId === undefined) return
    close(() => library.openAlbum(albumId))
  }

  function toggleAlbumPin() {
    const albumId = ctx?.track.albumId
    if (albumId === null || albumId === undefined) return
    close()
    void pinned.toggle('album', albumId)
  }

  function doEditTags() {
    const c = ctx
    if (!c || c.track.id <= 0) return
    close()
    tagEditor.open([c.track.id], t('Edit tags'))
  }

  async function doReveal() {
    const c = ctx
    if (!c) return
    close()
    try {
      await invoke('app_reveal_file', { path: c.track.path })
    } catch (e) {
      player.error = String(e)
    }
  }

  async function doCopy() {
    const c = ctx
    if (!c) return
    const text = c.track.artist ? `${c.track.artist} - ${c.track.title}` : c.track.title
    close()
    try {
      await navigator.clipboard.writeText(text)
      playlists.flash(t('Copied to clipboard'))
    } catch (e) {
      player.error = String(e)
    }
  }

  // Sleep timer, like Spotify's track menu; the player bar only shows it
  // while it runs.
  const SLEEP_MINUTES = [5, 10, 15, 30, 45, 60]
  const sleepActive = $derived(player.snapshot.sleepEndsAt !== null || player.snapshot.sleepEndOfTrack)
  function setSleep(minutes: number | null, endOfTrack = false) {
    close()
    void player.setSleepTimer(minutes, endOfTrack)
  }

  const itemCls =
    'flex w-full items-center gap-2.5 px-3 py-1.5 text-left outline-none hover:bg-zinc-100 focus-visible:bg-zinc-100 dark:hover:bg-zinc-800 dark:focus-visible:bg-zinc-800'
</script>

{#if ctx && mobile}
  {@const tr = ctx.track}
  <div
    use:portal
    bind:this={menu}
    role="menu"
    aria-label={tr.title}
    tabindex="-1"
    onkeydown={onKey}
    class="fixed inset-0 z-[90] text-zinc-100"
  >
    <div class="absolute inset-0 bg-black/60" transition:fade={{ duration: motionDuration(150) }}></div>
    <div
      bind:this={scroller}
      role="presentation"
      class="no-scrollbar absolute inset-0 overflow-y-auto overscroll-contain"
      ontouchstart={onSheetTouchStart}
      ontouchmove={onSheetTouchMove}
      ontouchend={onSheetTouchEnd}
      ontouchcancel={onSheetTouchEnd}
    >
      <div class="flex min-h-full flex-col">
        <!-- The empty top part: tapping it closes; it scrolls away to show
             the whole menu. -->
        <button type="button" class="min-h-[40vh] flex-1" aria-label={t('Close')} tabindex="-1" onclick={() => close()}></button>
        <div
          class="rounded-t-2xl bg-zinc-900 pb-[calc(1rem+var(--inset-bottom,0px))] shadow-2xl"
          style:transform={pullY > 0 ? `translateY(${pullY}px)` : undefined}
          transition:fly={{ y: 320, duration: motionDuration(220), opacity: 1 }}
        >
          <div class="flex justify-center pt-2.5 pb-1.5"><span class="h-1 w-10 rounded-full bg-zinc-600"></span></div>
          <div class="flex items-center gap-3 border-b border-zinc-800 px-4 pt-2 pb-4">
            <Cover cover={tr.cover} title={tr.title} class="size-14 shrink-0 rounded text-sm" />
            <div class="min-w-0">
              <p class="truncate text-base font-medium">{tr.title}</p>
              <p class="truncate text-sm text-zinc-400">
                {[tr.artist, tr.album].filter(Boolean).join(' • ')}
              </p>
            </div>
          </div>
          <div class="flex flex-col py-1">
            {#snippet row(icon: import('./Icon.svelte').Name, label: string, action: () => void, accent = false)}
              <button
                type="button"
                role="menuitem"
                class="flex w-full items-center gap-4 px-4 py-3.5 text-left text-[15px] active:bg-white/5"
                onclick={action}
              >
                <Icon name={icon} class={accent ? 'size-6 shrink-0 text-accent-400' : 'size-6 shrink-0 text-zinc-300'} />
                <span class="min-w-0 truncate">{label}</span>
              </button>
            {/snippet}
            {@render row('share', t('Copy song info'), () => void doCopy())}
            {#if hasLibId}
              {@render row('plusCircle', t('Add to playlist'), openSave)}
            {/if}
            {#if ctx.onRemoveFromPlaylist}
              {@render row('minusCircle', t('Remove from this playlist'), () => {
                const fn = ctx?.onRemoveFromPlaylist
                close()
                fn?.()
              })}
            {/if}
            {#if ctx.onRemoveFromQueue}
              {@render row('minusCircle', t('Remove from queue'), () => {
                const fn = ctx?.onRemoveFromQueue
                close()
                fn?.()
              })}
            {/if}
            {@render row(
              starred ? 'checkCircle' : 'plusCircle',
              starred ? t('Remove from favorites') : t('Add to favorites'),
              () => void doToggleFavorite(),
              starred,
            )}
            {@render row('queueAdd', t('Add to queue'), () => void doAddQueue())}
            {@render row('queue', t('Play next'), () => void doPlayNext())}
            {#if trackMenu.canOpenQueue}
              {@render row('list', t('Go to queue'), goQueue)}
            {/if}
            {#if hasAlbum}
              {@render row('album', t('Go to album'), goAlbum)}
            {/if}
            {#each artistList as name, i (`${name}:${i}`)}
              {@render row('artist', artistList.length === 1 ? t('Go to artist') : name, () => goArtist(name))}
            {/each}
            {#if hasAlbum}
              {@render row(
                'pin',
                t(pinned.isPinned('album', tr.albumId!) ? 'Unpin album' : 'Pin album'),
                toggleAlbumPin,
              )}
            {/if}
            {#if hasLibId}
              {@render row('sliders', t('Edit tags…'), doEditTags)}
            {/if}
            {#if canReveal}
              {@render row('folder', t('Show in folder'), () => void doReveal())}
            {/if}
          </div>
        </div>
      </div>
    </div>
  </div>
{:else if ctx}
  <div
    use:portal
    bind:this={menu}
    role="menu"
    aria-label={ctx.track.title}
    tabindex="-1"
    onkeydown={onKey}
    class="fixed z-50 flex flex-col rounded-xl border border-zinc-200 bg-white py-1 text-sm text-zinc-800 shadow-xl dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
    style:left="{pos.left}px"
    style:top="{pos.top}px"
    style:width="{WIDTH}px"
  >
    {#if ctx.onPlay}
      <button type="button" role="menuitem" class={itemCls} onclick={() => void doPlay()}>
        <Icon name="play" class="size-4 shrink-0 text-zinc-500" />
        <span class="truncate">{t('Play')}</span>
      </button>
    {/if}
    <button type="button" role="menuitem" class={itemCls} onclick={() => void doPlayNext()}>
      <Icon name="queue" class="size-4 shrink-0 text-zinc-500" />
      <span class="truncate">{t('Play next')}</span>
    </button>
    <button type="button" role="menuitem" class={itemCls} onclick={() => void doAddQueue()}>
      <Icon name="plus" class="size-4 shrink-0 text-zinc-500" />
      <span class="truncate">{t('Add to queue')}</span>
    </button>

    <div class="my-1 border-t border-zinc-100 dark:border-zinc-800" role="separator"></div>

    <button type="button" role="menuitem" class={itemCls} onclick={() => void doToggleFavorite()}>
      <Icon
        name={starred ? 'checkCircle' : 'plusCircle'}
        class={['size-4 shrink-0', starred ? 'text-accent-500' : 'text-zinc-500'].join(' ')}
      />
      <span class="truncate">
        {starred ? t('Remove from favorites') : t('Add to favorites')}
      </span>
    </button>

    {#if hasLibId}
      <button
        type="button"
        role="menuitem"
        aria-haspopup="menu"
        aria-expanded={sub === 'playlists'}
        class={[itemCls, 'justify-between', sub === 'playlists' ? 'bg-zinc-100 dark:bg-zinc-800' : '']}
        onmouseenter={(e) => openSub('playlists', e.currentTarget)}
        onclick={(e) => openSub('playlists', e.currentTarget)}
      >
        <span class="flex min-w-0 items-center gap-2.5">
          <Icon name="plus" class="size-4 shrink-0 text-zinc-500" />
          <span class="truncate">{t('Add to playlist')}</span>
        </span>
        <Icon name="chevronRight" class="size-4 shrink-0 text-zinc-400" />
      </button>
    {/if}

    <button
      type="button"
      role="menuitem"
      aria-haspopup="menu"
      aria-expanded={sub === 'sleep'}
      class={[itemCls, 'justify-between', sub === 'sleep' ? 'bg-zinc-100 dark:bg-zinc-800' : '']}
      onmouseenter={(e) => openSub('sleep', e.currentTarget)}
      onclick={(e) => openSub('sleep', e.currentTarget)}
    >
      <span class="flex min-w-0 items-center gap-2.5">
        <Icon name="moon" class={sleepActive ? 'size-4 shrink-0 text-accent-500' : 'size-4 shrink-0 text-zinc-500'} />
        <span class="truncate">{t('Sleep timer')}</span>
      </span>
      <Icon name="chevronRight" class="size-4 shrink-0 text-zinc-400" />
    </button>

    {#if ctx.onRemoveFromPlaylist}
      <button
        type="button"
        role="menuitem"
        class={itemCls}
        onclick={() => {
          const fn = ctx.onRemoveFromPlaylist
          close()
          fn?.()
        }}
      >
        <Icon name="close" class="size-4 shrink-0 text-zinc-500" />
        <span class="truncate">{t('Remove from playlist')}</span>
      </button>
    {/if}

    {#if ctx.onRemoveFromQueue}
      <button
        type="button"
        role="menuitem"
        class={itemCls}
        onclick={() => {
          const fn = ctx.onRemoveFromQueue
          close()
          fn?.()
        }}
      >
        <Icon name="close" class="size-4 shrink-0 text-zinc-500" />
        <span class="truncate">{t('Remove from queue')}</span>
      </button>
    {/if}

    {#if artistList.length > 0 || hasAlbum}
      <div class="my-1 border-t border-zinc-100 dark:border-zinc-800" role="separator"></div>
      {#if artistList.length === 1}
        <button type="button" role="menuitem" class={itemCls} onclick={() => goArtist()}>
          <Icon name="artist" class="size-4 shrink-0 text-zinc-500" />
          <span class="truncate">{t('Go to artist')}</span>
        </button>
      {:else if artistList.length > 1}
        <button
          type="button"
          role="menuitem"
          aria-haspopup="menu"
          aria-expanded={sub === 'artists'}
          class={[itemCls, 'justify-between', sub === 'artists' ? 'bg-zinc-100 dark:bg-zinc-800' : '']}
          onmouseenter={(e) => openSub('artists', e.currentTarget)}
          onclick={(e) => openSub('artists', e.currentTarget)}
        >
          <span class="flex min-w-0 items-center gap-2.5">
            <Icon name="artist" class="size-4 shrink-0 text-zinc-500" />
            <span class="truncate">{t('Go to artist')}</span>
          </span>
          <Icon name="chevronRight" class="size-4 shrink-0 text-zinc-400" />
        </button>
      {/if}
      {#if hasAlbum}
        <button type="button" role="menuitem" class={itemCls} onclick={goAlbum}>
          <Icon name="album" class="size-4 shrink-0 text-zinc-500" />
          <span class="truncate">{t('Go to album')}</span>
        </button>
        {@const albumPinned = pinned.isPinned('album', ctx.track.albumId!)}
        <button type="button" role="menuitem" class={itemCls} onclick={toggleAlbumPin}>
          <Icon name="pin" class="size-4 shrink-0 text-zinc-500" />
          <span class="truncate">{t(albumPinned ? 'Unpin album' : 'Pin album')}</span>
        </button>
      {/if}
    {/if}

    {#if hasLibId || canReveal}
      <div class="my-1 border-t border-zinc-100 dark:border-zinc-800" role="separator"></div>
      {#if hasLibId}
        <button type="button" role="menuitem" class={itemCls} onclick={doEditTags}>
          <Icon name="sliders" class="size-4 shrink-0 text-zinc-500" />
          <span class="truncate">{t('Edit tags…')}</span>
        </button>
      {/if}
      {#if canReveal}
        <button type="button" role="menuitem" class={itemCls} onclick={() => void doReveal()}>
          <Icon name="folder" class="size-4 shrink-0 text-zinc-500" />
          <span class="truncate">{t('Show in folder')}</span>
        </button>
      {/if}
    {/if}

    <div class="my-1 border-t border-zinc-100 dark:border-zinc-800" role="separator"></div>
    <button type="button" role="menuitem" class={itemCls} onclick={() => void doCopy()}>
      <Icon name="music" class="size-4 shrink-0 text-zinc-500" />
      <span class="truncate">{t('Copy song info')}</span>
    </button>
  </div>

  {#if sub === 'playlists' && hasLibId}
    <div
      use:portal
      bind:this={submenuEl}
      tabindex="-1"
      onkeydown={onSubKey}
      role="menu"
      aria-label={t('Add to playlist')}
      class="fixed z-50 flex max-h-72 flex-col overflow-hidden rounded-xl border border-zinc-200 bg-white py-1 text-sm text-zinc-800 shadow-xl dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
      style:left="{subPos.left}px"
      style:top="{subPos.top}px"
      style:width="{SUB_WIDTH}px"
    >
      {#if creating}
        <form
          class="flex flex-col gap-2 p-2"
          onsubmit={(e) => {
            e.preventDefault()
            void createPlaylist()
          }}
        >
          <input
            class="rounded-md border border-zinc-200 bg-white px-2 py-1 outline-none focus-visible:ring-2 focus-visible:ring-accent-500 dark:border-zinc-700 dark:bg-zinc-950"
            placeholder={t('Playlist name')}
            aria-label={t('New playlist name')}
            bind:value={playlistName}
          />
          <div class="flex justify-end gap-2">
            <button
              type="button"
              class="rounded-md px-2 py-1 text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
              onclick={() => (creating = false)}
            >
              {t('Cancel')}
            </button>
            <button
              type="submit"
              class="rounded-md bg-accent-600 px-2 py-1 font-medium text-white hover:bg-accent-500 disabled:opacity-50"
              disabled={playlistName.trim() === ''}
            >
              {t('Create')}
            </button>
          </div>
        </form>
      {:else}
        <div class="min-h-0 overflow-y-auto">
          {#each playlists.list as p (p.id)}
            <button
              type="button"
              role="menuitem"
              class="flex w-full items-center justify-between gap-2 px-3 py-1.5 text-left outline-none hover:bg-zinc-100 focus-visible:bg-zinc-100 dark:hover:bg-zinc-800 dark:focus-visible:bg-zinc-800"
              onclick={() => void addToPlaylist(p)}
            >
              <span class="truncate">{p.name}</span>
              <span class="text-xs tabular-nums text-zinc-400">{p.trackCount.toLocaleString()}</span>
            </button>
          {:else}
            <p class="px-3 py-1.5 text-xs text-zinc-500">{t('No playlists yet.')}</p>
          {/each}
        </div>
        <button
          type="button"
          role="menuitem"
          class="flex w-full items-center gap-2 border-t border-zinc-100 px-3 py-1.5 text-left text-accent-700 outline-none hover:bg-zinc-100 focus-visible:bg-zinc-100 dark:border-zinc-800 dark:text-accent-300 dark:hover:bg-zinc-800 dark:focus-visible:bg-zinc-800"
          onclick={() => void startCreate()}
        >
          <Icon name="plus" class="size-4" /> {t('New playlist…')}
        </button>
      {/if}
    </div>
  {:else if sub === 'sleep'}
    <div
      use:portal
      bind:this={submenuEl}
      tabindex="-1"
      onkeydown={onSubKey}
      role="menu"
      aria-label={t('Sleep timer')}
      class="fixed z-50 flex flex-col rounded-xl border border-zinc-200 bg-white py-1 text-sm text-zinc-800 shadow-xl dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
      style:left="{subPos.left}px"
      style:top="{subPos.top}px"
      style:width="{SUB_WIDTH}px"
    >
      {#each SLEEP_MINUTES as m (m)}
        <button type="button" role="menuitem" class={itemCls} onclick={() => setSleep(m)}>
          {m === 60 ? t('1 hour') : t('{n} minutes', { n: m })}
        </button>
      {/each}
      <button type="button" role="menuitem" class={[itemCls, 'justify-between']} onclick={() => setSleep(null, true)}>
        <span>{t('End of this song')}</span>
        {#if player.snapshot.sleepEndOfTrack}<Icon name="check" class="size-4 text-accent-600 dark:text-accent-400" />{/if}
      </button>
      {#if sleepActive}
        <div class="my-1 border-t border-zinc-100 dark:border-zinc-800" role="separator"></div>
        <button type="button" role="menuitem" class={[itemCls, 'text-red-600 dark:text-red-400']} onclick={() => setSleep(null)}>
          {t('Turn off timer')}
        </button>
      {/if}
    </div>
  {:else if sub === 'artists' && artistList.length > 1}
    <div
      use:portal
      bind:this={submenuEl}
      tabindex="-1"
      onkeydown={onSubKey}
      role="menu"
      aria-label={t('Go to artist')}
      class="fixed z-50 flex max-h-72 flex-col overflow-y-auto rounded-xl border border-zinc-200 bg-white py-1 text-sm text-zinc-800 shadow-xl dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
      style:left="{subPos.left}px"
      style:top="{subPos.top}px"
      style:width="{SUB_WIDTH}px"
    >
      {#each artistList as name, i (`${name}:${i}`)}
        <button
          type="button"
          role="menuitem"
          class={itemCls}
          onclick={() => goArtist(name)}
        >
          <Icon name="artist" class="size-4 shrink-0 text-zinc-500" />
          <span class="truncate">{name}</span>
        </button>
      {/each}
    </div>
  {/if}
{/if}

{#if saveFor}
  <SaveToMenu trackId={saveFor.trackId} title={saveFor.title} anchor={new DOMRect()} onClose={() => (saveFor = null)} />
{/if}

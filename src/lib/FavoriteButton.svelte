<script lang="ts">
  // Spotify-style save: a "+" circle adds the song to Favorites; once saved
  // (a filled check), a click opens "Add to playlist" (SaveToMenu), where
  // it can also be removed from Favorites.
  import { invoke } from '@tauri-apps/api/core'
  import Icon from './Icon.svelte'
  import SaveToMenu from './SaveToMenu.svelte'
  import { favorites } from './favorites.svelte'
  import { t } from './i18n.svelte'
  import type { TrackRow } from './library.svelte'

  let {
    trackId = null,
    path = null,
    title = '',
    size = 'size-4',
    light = false,
    revealOnHover = false,
  }: {
    trackId?: number | null
    path?: string | null
    title?: string
    size?: string
    light?: boolean
    /** Hide inactive star until the row is hovered or focused. */
    revealOnHover?: boolean
  } = $props()

  const active = $derived(
    trackId !== null ? favorites.has(trackId) : favorites.hasPath(path),
  )
  const label = $derived(
    active
      ? t('Add “{title}” to a playlist', { title })
      : t('Add “{title}” to favorites', { title }),
  )

  let menu = $state<{ trackId: number; anchor: DOMRect } | null>(null)

  let popping = $state(false)
  let popTimer: ReturnType<typeof setTimeout> | undefined

  async function openMenu(button: HTMLElement) {
    let id = trackId
    if (id === null && path) {
      // Now playing and similar places only know the path.
      const row = await invoke<TrackRow | null>('library_track_by_path', { path }).catch(() => null)
      id = row?.id ?? null
    }
    if (id === null) {
      // Not in the library (a stream): no playlists, just unsave it.
      if (path) void favorites.toggleByPath(path)
      return
    }
    menu = { trackId: id, anchor: button.getBoundingClientRect() }
  }

  function toggle(e: MouseEvent) {
    e.stopPropagation()
    if (active) {
      void openMenu(e.currentTarget as HTMLElement)
      return
    }
    popping = false
    clearTimeout(popTimer)
    queueMicrotask(() => {
      popping = true
      popTimer = setTimeout(() => (popping = false), 300)
    })
    if (trackId !== null) void favorites.toggle(trackId)
    else if (path) void favorites.toggleByPath(path)
  }
</script>

<button
  type="button"
  aria-pressed={active}
  aria-label={label}
  title={label}
  class={[
    'shrink-0 rounded p-1 outline-none transition focus-visible:ring-2 focus-visible:ring-accent-500 active:scale-90',
    active
      ? light
        ? 'text-accent-300 opacity-100 hover:bg-white/10'
        : 'text-accent-500 opacity-100 hover:bg-zinc-200/70 dark:text-accent-400 dark:hover:bg-zinc-800'
      : [
          light
            ? 'text-white/60 hover:bg-white/10 hover:text-white'
            : 'text-zinc-400 hover:bg-zinc-200/70 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-100',
          revealOnHover && 'opacity-0 group-focus-within:opacity-100 group-hover:opacity-100 pointer-coarse:opacity-100',
        ],
  ]}
  onclick={toggle}
  ondblclick={(e) => e.stopPropagation()}
  onkeydown={(e) => e.stopPropagation()}
>
  <Icon name={active ? 'checkCircle' : 'plusCircle'} class={popping ? `${size} animate-star-pop` : size} />
</button>
{#if menu}
  <SaveToMenu trackId={menu.trackId} {title} anchor={menu.anchor} onClose={() => (menu = null)} />
{/if}

<script lang="ts">
  // "Add to playlist" for a saved song, like Spotify's: search, new playlist,
  // Favorites and every playlist with a tick for where the song is now.
  // Changes are staged and applied on Done; unticking Favorites removes it.
  import { invoke } from '@tauri-apps/api/core'
  import { onMount } from 'svelte'
  import Icon from './Icon.svelte'
  import PlaylistCover from './PlaylistCover.svelte'
  import { appSettings } from './appSettings.svelte'
  import { favorites } from './favorites.svelte'
  import { count, t } from './i18n.svelte'
  import { player } from './player.svelte'
  import { playlists } from './playlists.svelte'
  import { portal } from './portal'

  let {
    trackId,
    title,
    anchor,
    onClose,
  }: {
    trackId: number
    title: string
    anchor: DOMRect
    onClose: () => void
  } = $props()

  const WIDTH = 340
  const mobile = $derived(appSettings.platform === 'android' || window.innerWidth < 640)

  let query = $state('')
  let inFavorites = $state(false)
  let saved = $state<Set<number>>(new Set())
  let initialSaved = new Set<number>()
  let picked = $state<Set<number>>(new Set())
  let busy = $state(false)
  let menu = $state<HTMLElement | null>(null)

  onMount(() => {
    inFavorites = favorites.has(trackId)
    invoke<number[]>('playlists_with_track', { trackId })
      .then((ids) => {
        initialSaved = new Set(ids)
        saved = new Set(ids)
        picked = new Set(ids)
      })
      .catch((e) => (player.error = String(e)))
    const onDown = (e: PointerEvent) => {
      if (menu && !menu.contains(e.target as Node)) onClose()
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    // Next tick: the click that opened the menu must not close it.
    const id = setTimeout(() => document.addEventListener('pointerdown', onDown, true))
    document.addEventListener('keydown', onKey, true)
    window.addEventListener('resize', onClose)
    return () => {
      clearTimeout(id)
      document.removeEventListener('pointerdown', onDown, true)
      document.removeEventListener('keydown', onKey, true)
      window.removeEventListener('resize', onClose)
    }
  })

  const q = $derived(query.trim().toLocaleLowerCase())
  const matches = $derived(
    playlists.list.filter((p) => q === '' || p.name.toLocaleLowerCase().includes(q)),
  )
  const savedIn = $derived(matches.filter((p) => saved.has(p.id)))
  const others = $derived(matches.filter((p) => !saved.has(p.id)))
  const showFavorites = $derived(q === '' || t('Favorites').toLocaleLowerCase().includes(q))

  // Above the button when there is room, else below; kept on screen.
  const place = $derived.by(() => {
    const height = Math.min(460, window.innerHeight - 24)
    const below = anchor.bottom + 8
    const top = below + height < window.innerHeight - 8 ? below : Math.max(8, anchor.top - height - 8)
    const left = Math.max(8, Math.min(window.innerWidth - WIDTH - 8, anchor.right - WIDTH))
    return { top, left, height }
  })

  function toggle(id: number) {
    const next = new Set(picked)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    picked = next
  }

  async function newPlaylist() {
    const name = query.trim() || t('My playlist #{n}', { n: playlists.list.length + 1 })
    const made = await playlists.create(name, [trackId])
    if (made) {
      playlists.flash(t('Added to “{name}”', { name: made.name }))
      onClose()
    }
  }

  async function done() {
    if (busy) return
    busy = true
    try {
      if (!inFavorites && favorites.has(trackId)) await favorites.toggle(trackId)
      if (inFavorites && !favorites.has(trackId)) await favorites.toggle(trackId)
      for (const p of playlists.list) {
        const was = initialSaved.has(p.id)
        const now = picked.has(p.id)
        if (now && !was) await invoke('playlist_add_tracks', { id: p.id, trackIds: [trackId] })
        if (!now && was) await invoke('playlist_remove_track', { id: p.id, trackId })
      }
      await playlists.refresh()
      onClose()
    } catch (e) {
      player.error = String(e)
    } finally {
      busy = false
    }
  }

  const row =
    'flex w-full items-center gap-3 rounded-md px-2 py-1.5 text-left hover:bg-zinc-100 dark:hover:bg-zinc-800'
</script>

{#snippet tick(on: boolean)}
  <span
    class={[
      'ml-auto flex size-5 shrink-0 items-center justify-center rounded-full border-2',
      on ? 'border-accent-500 bg-accent-500 text-zinc-950' : 'border-zinc-400 dark:border-zinc-500',
    ]}
    aria-hidden="true"
  >
    {#if on}<Icon name="check" class="size-3.5" />{/if}
  </span>
{/snippet}

{#snippet entry(p: (typeof playlists.list)[number])}
  <button type="button" role="checkbox" aria-checked={picked.has(p.id)} class={row} onclick={() => toggle(p.id)}>
    <PlaylistCover cover={p.cover} albumCovers={p.albumCovers} name={p.name} class="size-10 shrink-0 rounded" iconClass="size-5" />
    <span class="min-w-0">
      <span class="block truncate text-sm font-medium">{p.name}</span>
      <span class="block text-xs text-zinc-500">{count(p.trackCount, '{n} song', '{n} songs')}</span>
    </span>
    {@render tick(picked.has(p.id))}
  </button>
{/snippet}

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div use:portal class={mobile ? 'fixed inset-0 z-[110] flex items-end bg-black/50' : ''} onclick={(e) => e.stopPropagation()} ondblclick={(e) => e.stopPropagation()}>
  <div
    bind:this={menu}
    role="dialog"
    aria-label={t('Add “{title}” to a playlist', { title })}
    class={[
      'flex flex-col overflow-hidden border border-zinc-200 bg-white text-zinc-900 shadow-2xl dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100',
      mobile ? 'max-h-[80vh] w-full rounded-t-2xl' : 'fixed z-[110] rounded-xl',
    ]}
    style:top={mobile ? undefined : `${place.top}px`}
    style:left={mobile ? undefined : `${place.left}px`}
    style:width={mobile ? undefined : `${WIDTH}px`}
    style:max-height={mobile ? undefined : `${place.height}px`}
    style:padding-bottom={mobile ? 'var(--inset-bottom, 0px)' : undefined}
  >
    <div class="flex flex-col gap-2 p-3 pb-2">
      <p class="px-1 text-sm font-semibold">{t('Add to playlist')}</p>
      <label class="flex items-center gap-2 rounded-md bg-zinc-100 px-2.5 py-1.5 dark:bg-zinc-800">
        <Icon name="search" class="size-4 text-zinc-500" />
        <input
          class="min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-zinc-500"
          placeholder={t('Find a playlist')}
          bind:value={query}
        />
      </label>
      <button type="button" class={row} onclick={() => void newPlaylist()}>
        <span class="flex size-10 shrink-0 items-center justify-center"><Icon name="plus" class="size-5" /></span>
        <span class="text-sm font-medium">{t('New playlist')}</span>
      </button>
    </div>
    <div class="min-h-0 flex-1 overflow-y-auto border-t border-zinc-200 px-3 py-2 dark:border-zinc-800">
      {#if showFavorites || savedIn.length > 0}
        <p class="px-2 pt-1 pb-1 text-xs font-semibold text-zinc-500">{t('Saved in')}</p>
        {#if showFavorites}
          <button type="button" role="checkbox" aria-checked={inFavorites} class={row} onclick={() => (inFavorites = !inFavorites)}>
            <span class="flex size-10 shrink-0 items-center justify-center rounded bg-gradient-to-br from-accent-400 to-indigo-600 text-white">
              <Icon name="star" class="size-5" />
            </span>
            <span class="min-w-0">
              <span class="block truncate text-sm font-medium">{t('Favorites')}</span>
              <span class="block text-xs text-zinc-500">{count(favorites.ids.size, '{n} song', '{n} songs')}</span>
            </span>
            {@render tick(inFavorites)}
          </button>
        {/if}
        {#each savedIn as p (p.id)}{@render entry(p)}{/each}
      {/if}
      {#if others.length > 0}
        <p class="px-2 pt-3 pb-1 text-xs font-semibold text-zinc-500">{t('Playlists')}</p>
        {#each others as p (p.id)}{@render entry(p)}{/each}
      {/if}
    </div>
    <div class="flex justify-end gap-2 border-t border-zinc-200 p-3 dark:border-zinc-800">
      <button type="button" class="rounded-full px-4 py-1.5 text-sm font-medium text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800" onclick={onClose}>
        {t('Cancel')}
      </button>
      <button
        type="button"
        class="rounded-full bg-accent-500 px-5 py-1.5 text-sm font-semibold text-zinc-950 hover:bg-accent-400 disabled:opacity-50"
        disabled={busy}
        onclick={() => void done()}
      >
        {t('Done')}
      </button>
    </div>
  </div>
</div>

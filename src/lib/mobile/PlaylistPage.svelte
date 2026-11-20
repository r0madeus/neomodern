<script lang="ts">
  import { count, t } from '../i18n.svelte'
  import Icon from '../Icon.svelte'
  import PlaylistCover from '../PlaylistCover.svelte'
  import PlaylistCoverModal from '../PlaylistCoverModal.svelte'
  import ActionsMenu from '../ActionsMenu.svelte'
  import { portal } from '../portal'
  import { underTopBar } from './titleWatch'
  import TrackItem from './TrackItem.svelte'
  import StickyPlay from './StickyPlay.svelte'
  import { playlists } from '../playlists.svelte'
  import { player } from '../player.svelte'
  import { pinned } from '../pinned.svelte'
  import type { TrackRow } from '../library.svelte'
  import { invoke } from '@tauri-apps/api/core'
  import { formatTime } from '../player.svelte'
  import type { Rgb } from '../nowCover.svelte'
  import { tintFrom } from '../tint'
  import TintedBackdrop from '../TintedBackdrop.svelte'
  import ProfileAvatar from '../ProfileAvatar.svelte'
  import { profiles } from '../profiles.svelte'

  let { id, onBack }: { id: number; onBack: () => void } = $props()

  const info = $derived(playlists.byId(id))
  let tracks = $state<TrackRow[]>([])
  let editingCover = $state(false)
  // The bar's title appears once the big title is under the bar.
  let titleHidden = $state(false)

  // Deleting asks once more in a bottom sheet; the page then closes.
  let confirmingDelete = $state(false)
  async function deletePlaylist() {
    confirmingDelete = false
    if (await playlists.delete(id)) onBack()
  }

  $effect(() => {
    void playlists.version
    const count = info?.trackCount ?? 0
    let stale = false
    void playlists.tracks(id, count).then((rows) => {
      if (!stale) tracks = rows
    })
    return () => (stale = true)
  })

  // Rename in a bottom sheet (Spotify's "Name & details").
  let renaming = $state(false)
  let nameDraft = $state('')
  function startRename() {
    nameDraft = info?.name ?? ''
    renaming = true
  }
  async function saveRename(e: SubmitEvent) {
    e.preventDefault()
    const name = nameDraft.trim()
    if (!name || !info) return
    if (name === info.name || (await playlists.rename(id, name))) renaming = false
  }

  const totalSeconds = $derived(tracks.reduce((sum, tr) => sum + (tr.durationMs ?? 0), 0) / 1000)

  // The page is tinted with the colour of its cover (a chosen image, else
  // the first album cover of the collage), like Spotify.
  let color = $state<Rgb | null>(null)
  $effect(() => {
    const custom = info?.cover && !info.cover.startsWith('preset:') ? info.cover : null
    const cover = custom ?? info?.albumCovers[0] ?? null
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

  async function shufflePlay() {
    if (tracks.length === 0) return
    await player.setShuffle(true)
    await playlists.play(id, Math.floor(Math.random() * tracks.length))
  }
</script>

<div class="absolute inset-0 flex flex-col bg-zinc-950">
  <!-- Spotify-style bar over the scrolling list (the play button sticks
       to its edge): back, the name once the big title is under the bar,
       and "…" for the rest (export). -->
  <!-- pr-[22px]: the round "…" sits right above the round play button. -->
  <header class="absolute inset-x-0 top-0 z-10 flex h-14 items-center gap-2 pr-[22px] pl-2 transition-colors" class:bg-zinc-900={titleHidden}>
    <button class="rounded-full bg-black/30 p-2.5 text-white active:bg-black/50" aria-label={t('Back')} onclick={onBack}>
      <Icon name="back" class="size-6" />
    </button>
    <h1 class={['min-w-0 flex-1 truncate pr-14 text-base font-semibold transition-opacity', !titleHidden && 'opacity-0']}>
      {info?.name ?? ''}
    </h1>
    {#if info}
      <ActionsMenu
        label={t('More actions for “{title}”', { title: info.name })}
        triggerClass="rounded-full bg-black/30 p-2.5 text-white outline-none active:bg-black/50"
        iconClass="size-6"
      >
        {#snippet children(close)}
          <button
            type="button"
            role="menuitem"
            class="flex w-full items-center gap-3 px-4 py-3 text-left outline-none active:bg-zinc-100 dark:active:bg-zinc-800"
            onclick={() => {
              close()
              startRename()
            }}
          >
            <Icon name="sliders" class="size-5 text-zinc-500" />
            {t('Rename')}
          </button>
          <button
            type="button"
            role="menuitem"
            class="flex w-full items-center gap-3 px-4 py-3 text-left outline-none active:bg-zinc-100 dark:active:bg-zinc-800"
            onclick={() => {
              close()
              if (info) void playlists.exportM3u(info)
            }}
          >
            <Icon name="upload" class="size-5 text-zinc-500" />
            {t('Export…')}
          </button>
          <button
            type="button"
            role="menuitem"
            class="flex w-full items-center gap-3 px-4 py-3 text-left outline-none active:bg-zinc-100 dark:active:bg-zinc-800"
            onclick={() => {
              close()
              editingCover = true
            }}
          >
            <Icon name="image" class="size-5 text-zinc-500" />
            {t('Cover')}
          </button>
          <button
            type="button"
            role="menuitem"
            class="flex w-full items-center gap-3 border-t border-zinc-200 px-4 py-3 text-left text-red-600 outline-none active:bg-zinc-100 dark:border-zinc-800 dark:text-red-400 dark:active:bg-zinc-800"
            onclick={() => {
              close()
              confirmingDelete = true
            }}
          >
            <Icon name="trash" class="size-5" />
            {t('Delete playlist')}
          </button>
        {/snippet}
      </ActionsMenu>
    {/if}
  </header>
  <div class="min-h-0 flex-1 overflow-y-auto pb-[var(--mobile-bar-clear,5rem)]">
    {#if info}
      <div class="relative isolate overflow-hidden px-4 pt-16 pb-3">
        <TintedBackdrop background="linear-gradient(180deg, {tint.top} 0%, {tint.surface} 60%, var(--color-zinc-950) 100%)" />
        <button
          type="button"
          class="mx-auto block aspect-square w-[62%] max-w-72 overflow-hidden rounded-sm shadow-2xl shadow-black/60 active:scale-[0.98]"
          aria-label={t('Playlist cover')}
          onclick={() => (editingCover = true)}
        >
          <PlaylistCover
            cover={info.cover}
            albumCovers={info.albumCovers}
            name={info.name}
            class="size-full rounded-sm text-5xl"
            iconClass="size-20"
          />
        </button>
        <h2 class="mt-6 text-[1.7rem] leading-tight font-bold tracking-tight" {@attach underTopBar((hidden) => (titleHidden = hidden))}>
          {info.name}
        </h2>
        {#if profiles.current}
          <!-- Spotify shows the owner: here, the profile it belongs to. -->
          <p class="mt-2.5 flex min-w-0 items-center gap-2 text-sm font-bold text-zinc-50">
            <ProfileAvatar profile={profiles.current} class="size-6 text-[10px]" />
            <span class="truncate">{profiles.current.name}</span>
          </p>
        {/if}
        <p class="mt-2 text-[13px] text-zinc-400">
          {[t('Playlist'), count(info.trackCount, '{n} song', '{n} songs'), totalSeconds > 0 ? formatTime(totalSeconds) : '']
            .filter(Boolean)
            .join(' • ')}
        </p>
      </div>
      {#if tracks.length > 0}
        <!-- The play button sticks at the bar's lower edge once scrolled. -->
        <StickyPlay
          dockShift={52}
          playing={player.isActiveFrom(`playlist:${id}`)}
          onclick={() => player.playOrToggle(`playlist:${id}`, () => playlists.play(id, 0))}
        />
      {/if}
      <div class="flex h-16 items-center gap-1 px-2.5 pb-2">
        <button
          class={['rounded-full p-2.5 active:bg-white/10', pinned.isPinned('playlist', id) ? 'text-accent-400' : 'text-zinc-300']}
          aria-label={t(pinned.isPinned('playlist', id) ? 'Unpin' : 'Pin')}
          aria-pressed={pinned.isPinned('playlist', id)}
          onclick={() => void pinned.toggle('playlist', id)}
        >
          <Icon name="pin" class="size-6" />
        </button>
        <button
          class="rounded-full p-2.5 text-zinc-300 active:bg-white/10"
          aria-label={t('Export…')}
          onclick={() => info && void playlists.exportM3u(info)}
        >
          <Icon name="share" class="size-6" />
        </button>
        <span class="flex-1"></span>
        {#if tracks.length > 0}
          <button class="rounded-full p-3 text-zinc-300 active:bg-white/10" aria-label={t('Shuffle play')} onclick={shufflePlay}>
            <Icon name="shuffle" class="size-6" />
          </button>
          <span class="mr-1.5 size-14 shrink-0" aria-hidden="true"></span>
        {/if}
      </div>
      <!-- Spotify-style chips under the action row. -->
      <div class="flex gap-2 overflow-x-auto px-4 pb-3 no-scrollbar">
        <button
          type="button"
          class="flex shrink-0 items-center gap-2 rounded-full bg-zinc-800/90 px-4 py-2 text-sm font-semibold text-zinc-100 active:bg-zinc-700"
          onclick={startRename}
        >
          <Icon name="sliders" class="size-4" />
          {t('Rename')}
        </button>
        <button
          type="button"
          class="flex shrink-0 items-center gap-2 rounded-full bg-zinc-800/90 px-4 py-2 text-sm font-semibold text-zinc-100 active:bg-zinc-700"
          onclick={() => (editingCover = true)}
        >
          <Icon name="image" class="size-4" />
          {t('Cover')}
        </button>
      </div>
      {#if tracks.length === 0}
        <p class="px-8 pt-6 text-center text-sm text-zinc-400">
          {t("This playlist is empty. Use the ⋯ menu on a song or album to add tracks.")}
        </p>
      {/if}
      {#each tracks as track, i (`${i}:${track.id}`)}
        <TrackItem
          title={track.title}
          subtitle={track.artist}
          path={track.path}
          cover={track.cover}
          trackId={track.id}
          {track}
          album=""
          onPlay={() => playlists.play(id, i)}
          onRemoveFromPlaylist={() => void playlists.removeAt(id, [i])}
        />
      {/each}
    {/if}
  </div>
</div>

{#if renaming && info}
  <div use:portal class="fixed inset-0 z-[90] flex items-end bg-black/60" role="presentation" onclick={() => (renaming = false)}>
    <div
      role="dialog"
      aria-modal="true"
      aria-label={t('Rename')}
      tabindex="-1"
      class="w-full rounded-t-2xl bg-zinc-900 px-4 pt-5 pb-[calc(1rem+var(--inset-bottom,0px))] text-zinc-100"
      onclick={(e) => e.stopPropagation()}
      onkeydown={(e) => e.key === 'Escape' && (renaming = false)}
    >
    <form onsubmit={saveRename}>
      <label class="flex flex-col gap-2">
        <span class="text-lg font-bold">{t('Playlist name')}</span>
        <!-- svelte-ignore a11y_autofocus -->
        <input
          class="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2.5 text-base focus:border-accent-500 focus:outline-none"
          maxlength="200"
          autofocus
          bind:value={nameDraft}
        />
      </label>
      <div class="mt-5 flex gap-3">
        <button type="button" class="flex-1 rounded-full bg-zinc-800 py-3 font-semibold active:bg-zinc-700" onclick={() => (renaming = false)}>
          {t('Cancel')}
        </button>
        <button type="submit" class="flex-1 rounded-full bg-accent-500 py-3 font-semibold text-zinc-950 active:bg-accent-400 disabled:opacity-50" disabled={nameDraft.trim() === ''}>
          {t('Save')}
        </button>
      </div>
    </form>
    </div>
  </div>
{/if}

{#if editingCover && info}
  <PlaylistCoverModal playlist={info} onClose={() => (editingCover = false)} />
{/if}

{#if confirmingDelete && info}
  <div use:portal class="fixed inset-0 z-[90] flex items-end bg-black/60" role="presentation" onclick={() => (confirmingDelete = false)}>
    <div
      role="alertdialog"
      aria-modal="true"
      aria-label={t('Delete playlist')}
      tabindex="-1"
      class="w-full rounded-t-2xl bg-zinc-900 px-4 pt-5 pb-[calc(1rem+var(--inset-bottom,0px))] text-zinc-100"
      onclick={(e) => e.stopPropagation()}
      onkeydown={(e) => e.key === 'Escape' && (confirmingDelete = false)}
    >
      <p class="text-lg font-bold">{t('Delete “{name}”?', { name: info.name })}</p>
      <p class="mt-1 text-sm text-zinc-400">{t('The songs stay in your library.')}</p>
      <div class="mt-5 flex gap-3">
        <button type="button" class="flex-1 rounded-full bg-zinc-800 py-3 font-semibold active:bg-zinc-700" onclick={() => (confirmingDelete = false)}>
          {t('Cancel')}
        </button>
        <button type="button" class="flex-1 rounded-full bg-red-600 py-3 font-semibold text-white active:bg-red-500" onclick={() => void deletePlaylist()}>
          {t('Delete')}
        </button>
      </div>
    </div>
  </div>
{/if}

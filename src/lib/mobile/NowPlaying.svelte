<script lang="ts">
  import TitleLink from '../TitleLink.svelte'
  import SleepTimerButton from '../SleepTimerButton.svelte'
  import { t } from '../i18n.svelte'
  import { fly } from 'svelte/transition'
  import AlbumLink from '../AlbumLink.svelte'
  import ArtistLinks from '../ArtistLinks.svelte'
  import Cover from '../Cover.svelte'
  import FavoriteButton from '../FavoriteButton.svelte'
  import Icon from '../Icon.svelte'
  import CurrentLine from '../CurrentLine.svelte'
  import LyricLines from '../LyricLines.svelte'
  import TintedBackdrop from '../TintedBackdrop.svelte'
  import { motionDuration, viewportHeight } from '../motion'
  import { player, formatTime } from '../player.svelte'
  import { lyrics } from '../lyrics.svelte'
  import LyricsShare from '../LyricsShare.svelte'
  import { nowCover } from '../nowCover.svelte'
  import { tintFrom } from '../tint'
  import { trackCovers } from '../trackCovers.svelte'
  import { TrackSwipe } from '../trackSwipe.svelte'
  import type { TrackInfo } from '../player.svelte'

  // Full-screen player tinted with the cover's colour. Scrolling down shows
  // the lyrics card; swipe down at the top (or back) closes it.
  let { onClose, onQueue, onLyrics }: { onClose: () => void; onQueue: () => void; onLyrics: () => void } = $props()

  let dragging = $state<number | null>(null)
  let pull = $state(0)
  // Swipe the cover left / right for the next / previous song.
  const swipe = new TrackSwipe()
  let axis = $state<'none' | 'x' | 'y'>('none')
  let gestureActive = false
  let canPull = false
  let canSwipe = false
  let startX = 0
  let startY = 0
  let scroller = $state<HTMLDivElement | null>(null)

  const snap = $derived(player.snapshot)
  const duration = $derived(snap.durationSeconds)
  const shown = $derived(dragging ?? player.position)
  const progress = $derived(duration ? Math.min(100, (shown / duration) * 100) : 0)
  const tint = $derived(tintFrom(nowCover.color))
  const hasLyrics = $derived(
    lyrics.result !== null && (lyrics.result.kind === 'synced' || lyrics.result.kind === 'plain'),
  )
  const isStream = $derived(!!snap.current && /^https?:\/\//i.test(snap.current.path))

  function onTouchStart(e: TouchEvent) {
    if (e.touches.length !== 1) return
    const target = e.target as HTMLElement
    if (target.closest('input, button')) return
    canPull = (scroller?.scrollTop ?? 0) === 0 && !target.closest('[data-no-pull]')
    canSwipe = !target.closest('[data-no-swipe]')
    if (!canPull && !canSwipe) return
    gestureActive = true
    axis = 'none'
    startX = e.touches[0].clientX
    startY = e.touches[0].clientY
    pull = 0
  }
  function onTouchMove(e: TouchEvent) {
    if (!gestureActive || e.touches.length !== 1) return
    const dx = e.touches[0].clientX - startX
    const dy = e.touches[0].clientY - startY

    if (axis === 'none') {
      if (canSwipe && Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy) * 1.25) {
        axis = 'x'
        pull = 0
      } else if (Math.abs(dy) > 10) {
        if (canPull && dy > 0) {
          axis = 'y'
          pull = 0.001
        } else {
          gestureActive = false
          return
        }
      } else {
        return
      }
    }

    if (axis === 'x') {
      swipe.drag(dx)
    } else if (axis === 'y') {
      pull = Math.max(0.001, dy)
    }
  }
  function onTouchEnd() {
    if (axis === 'x') {
      swipe.release()
    } else if (axis === 'y' && pull > 120) {
      gestureActive = false
      axis = 'none'
      onClose()
      return
    }
    gestureActive = false
    axis = 'none'
    pull = 0
  }
  function onTouchCancel() {
    if (axis === 'x') swipe.cancel()
    gestureActive = false
    axis = 'none'
    pull = 0
  }
  function coverOf(track: TrackInfo): string | null {
    if (nowCover.path === track.path && nowCover.cover) return nowCover.cover
    return trackCovers.get(track.path) ?? null
  }
  const panels = $derived([snap.previousTrack, snap.current, snap.nextTrack])
  function commitSeek() {
    if (dragging !== null) void player.seek(dragging)
    dragging = null
  }
</script>

<div
  class="fixed inset-0 z-40 isolate overflow-hidden text-white"
  style:transform={pull > 0 ? `translateY(${pull}px)` : undefined}
  style:transition={pull > 0 ? 'none' : 'transform 200ms ease-out'}
  transition:fly={{ y: viewportHeight(), duration: motionDuration(260), opacity: 1 }}
  ontouchstart={onTouchStart}
  ontouchmove={onTouchMove}
  ontouchend={onTouchEnd}
  ontouchcancel={onTouchCancel}
  role="dialog"
  tabindex="-1"
  aria-modal="true"
  aria-label={t("Now playing")}
>
  <TintedBackdrop background="linear-gradient(to bottom, {tint.top} 0%, var(--color-zinc-950) 92%)" duration={600} />
  <div bind:this={scroller} class="h-full overflow-x-hidden overflow-y-auto overscroll-contain">
    <section
      class="flex touch-pan-y flex-col px-6"
      style:min-height="100dvh"
      style:padding-top="var(--inset-top)"
      style:padding-bottom="calc(var(--inset-bottom) + 12px)"
    >
      <header class="flex h-14 shrink-0 items-center">
        <button class="-ml-3 rounded-full p-3 active:bg-white/10" aria-label={t("Close player")} onclick={onClose}>
          <Icon name="down" class="size-7" />
        </button>
        <div class="min-w-0 flex-1 text-center leading-tight">
          <p class="text-[11px] tracking-widest text-white/70 uppercase">{t("Now playing")}</p>
          {#if snap.queueLength > 0}
            <p class="text-sm font-bold">{t('{i} of {n}', { i: (snap.currentIndex ?? 0) + 1, n: snap.queueLength })}</p>
          {/if}
        </div>
        <span class="w-10"></span>
      </header>

      {#if snap.current}
        <!-- The strip is wider than the page by one gutter per side, so the
             neighbouring covers come in from the screen edge, not the margin. -->
        <div class="-mx-6 flex min-h-0 flex-1 items-center overflow-hidden pt-3" bind:clientWidth={swipe.width}>
          <div
            class="flex h-full w-[300%] shrink-0 will-change-transform"
            style:transform={swipe.transform}
            style:transition={swipe.transition}
          >
            {#each panels as track, i (i)}
              <div class="flex h-full w-1/3 shrink-0 items-center justify-center px-6" aria-hidden={i !== 1}>
                {#if track}
                  <Cover
                    cover={coverOf(track)}
                    title={track.title}
                    class="aspect-square max-h-full w-full rounded-lg text-7xl shadow-2xl shadow-black/50"
                  />
                {/if}
              </div>
            {/each}
          </div>
        </div>

        <div class="shrink-0">
          <CurrentLine />
          <div class="mt-1 flex items-center gap-3">
            <div class="min-w-0 flex-1">
              <h2 class="truncate text-[22px] leading-tight font-bold"><TitleLink title={snap.current.title} path={snap.current.path} linkClass="active:underline" /></h2>
              <p class="mt-0.5 truncate text-base text-white/70">
                {#if snap.current.artist}
                  <ArtistLinks artist={snap.current.artist} linkClass="hover:text-accent-400 active:underline" />
                {:else}
                  {t('Unknown artist')}
                {/if}
                {#if nowCover.track?.album}
                  <span class="opacity-60"> · </span>
                  <AlbumLink
                    album={nowCover.track.album}
                    albumId={nowCover.track.albumId}
                    linkClass="hover:text-accent-400 active:underline"
                  />
                {/if}
              </p>
            </div>
            {#if !snap.current.path.startsWith('http://') && !snap.current.path.startsWith('https://')}
              <FavoriteButton path={snap.current.path} title={snap.current.title} size="size-6" light />
            {/if}
          </div>

          <div class="mt-5" data-no-pull>
            <input
              type="range"
              class="seek touch light w-full"
              style:--progress="{progress}%"
              min="0"
              max={duration ?? 0}
              step="0.1"
              value={shown}
              disabled={!duration}
              aria-label={t("Seek")}
              oninput={(e) => (dragging = e.currentTarget.valueAsNumber)}
              onchange={commitSeek}
            />
            <div class="mt-1.5 flex justify-between text-xs tabular-nums text-white/60">
              <span>{formatTime(shown)}</span>
              <span>{formatTime(duration)}</span>
            </div>
          </div>

          <div class="mt-2 flex items-center justify-between">
            <button
              class={['relative rounded-full p-3 active:bg-white/10', snap.shuffle ? 'text-accent-400' : 'text-white']}
              aria-pressed={snap.shuffle}
              aria-label={t(snap.shuffle ? 'Shuffle on' : 'Shuffle off')}
              onclick={player.toggleShuffle}
            >
              <Icon name="shuffle" class="size-6" />
              {#if snap.shuffle}<span class="absolute bottom-1 left-1/2 size-1 -translate-x-1/2 rounded-full bg-accent-400"></span>{/if}
            </button>
            <button class="rounded-full p-2 active:bg-white/10" aria-label={t("Previous")} onclick={player.previous}>
              <Icon name="prev" class="size-10" />
            </button>
            <button
              class="flex size-[72px] items-center justify-center rounded-full bg-white text-zinc-950 active:scale-95"
              aria-label={t(snap.status === 'playing' ? 'Pause' : 'Play')}
              onclick={player.togglePause}
            >
              <Icon name={snap.status === 'playing' ? 'pause' : 'play'} class="size-9" />
            </button>
            <button class="rounded-full p-2 active:bg-white/10" aria-label={t("Next")} onclick={player.next}>
              <Icon name="next" class="size-10" />
            </button>
            <button
              class={['relative rounded-full p-3 active:bg-white/10', snap.repeat !== 'off' ? 'text-accent-400' : 'text-white']}
              aria-pressed={snap.repeat !== 'off'}
              aria-label={t(snap.repeat === 'one' ? 'Repeat one' : snap.repeat === 'all' ? 'Repeat all' : 'Repeat off')}
              onclick={player.cycleRepeat}
            >
              <Icon name={snap.repeat === 'one' ? 'repeatOne' : 'repeat'} class="size-6" />
              {#if snap.repeat !== 'off'}<span class="absolute bottom-1 left-1/2 size-1 -translate-x-1/2 rounded-full bg-accent-400"></span>{/if}
            </button>
          </div>

          <div class="mt-3 flex items-center justify-between">
            <button class="-ml-3 rounded-full p-3 text-white/80 active:bg-white/10" aria-label={t("Lyrics")} onclick={onLyrics}>
              <Icon name="lyrics" class="size-6" />
            </button>
            <SleepTimerButton mobile />
            <button class="-mr-3 rounded-full p-3 text-white/80 active:bg-white/10" aria-label={t("Queue")} onclick={onQueue}>
              <Icon name="queue" class="size-6" />
            </button>
          </div>
        </div>
      {/if}
    </section>

    <!-- Below the fold: the lyrics card. -->
    <section data-no-swipe class="px-4" style:padding-bottom="calc(var(--inset-bottom) + 24px)">
      <div class="overflow-hidden rounded-xl" style:background={tint.surface}>
        <div class="flex items-center justify-between px-4 pt-4 pb-1">
          <h3 class="text-base font-bold">{t("Lyrics")}</h3>
          <div class="flex items-center gap-2">
            {#if snap.current}
              <button
                class="rounded-full bg-black/25 p-2.5 active:bg-black/40 disabled:opacity-40"
                aria-label={t("Refresh lyrics")}
                disabled={lyrics.loading}
                onclick={() => snap.current && void lyrics.load(snap.current.path, duration, true)}
              >
                <Icon name="refresh" class={lyrics.loading ? 'size-4 animate-spin' : 'size-4'} />
              </button>
              {#if !isStream}
                <button
                  class="rounded-full bg-black/25 p-2.5 active:bg-black/40"
                  aria-label={t("Load .lrc file")}
                  onclick={() => snap.current && void lyrics.pickAndAttach(snap.current.path)}
                >
                  <Icon name="upload" class="size-4" />
                </button>
              {/if}
            {/if}
            {#if hasLyrics}
              <button class="rounded-full bg-black/25 p-2.5 active:bg-black/40" aria-label={t("Full-screen lyrics")} onclick={onLyrics}>
                <Icon name="expand" class="size-4" />
              </button>
            {/if}
          </div>
        </div>
        {#if lyrics.error}
          <p class="px-4 pb-1 text-sm text-red-200">{lyrics.error}</p>
        {/if}
        {#if hasLyrics}
          <!-- Preview like Spotify: a short card that follows the song by
               itself; tap it for the full-screen lyrics. -->
          <button
            type="button"
            class="block w-full text-left"
            aria-label={t('Full-screen lyrics')}
            onclick={onLyrics}
          >
            <LyricLines preview dim={tint.dim} class="h-[240px] px-4" />
          </button>
        {:else}
          <LyricLines dim={tint.dim} class="px-4" />
        {/if}
        <LyricsShare class="px-4 pt-2 pb-3" />
      </div>
    </section>
  </div>
</div>

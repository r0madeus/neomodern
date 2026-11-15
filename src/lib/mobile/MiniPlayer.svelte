<script lang="ts">
  import { t } from '../i18n.svelte'
  import Cover from '../Cover.svelte'
  import FavoriteButton from '../FavoriteButton.svelte'
  import Icon from '../Icon.svelte'
  import TintedBackdrop from '../TintedBackdrop.svelte'
  import { player } from '../player.svelte'
  import { nowCover } from '../nowCover.svelte'
  import { tintFrom } from '../tint'
  import { trackCovers } from '../trackCovers.svelte'
  import { TrackSwipe } from '../trackSwipe.svelte'
  import type { TrackInfo } from '../player.svelte'

  // Floating bar above the tabs; tapping it opens the full player.
  let { onOpen }: { onOpen: () => void } = $props()

  const snap = $derived(player.snapshot)
  const progress = $derived(
    snap.durationSeconds ? Math.min(100, (player.position / snap.durationSeconds) * 100) : 0,
  )
  const isLocal = $derived(
    !!snap.current &&
      !snap.current.path.startsWith('http://') &&
      !snap.current.path.startsWith('https://'),
  )

  // Swipe left / right for the next / previous song (see trackSwipe).
  const swipe = new TrackSwipe()
  let axis: 'none' | 'x' | 'y' = 'none'
  let startX = 0
  let startY = 0
  let swipedUntil = 0

  function onTouchStart(e: TouchEvent) {
    if (e.touches.length !== 1) return
    startX = e.touches[0].clientX
    startY = e.touches[0].clientY
    axis = 'none'
  }

  function onTouchMove(e: TouchEvent) {
    if (e.touches.length !== 1) return
    const dx = e.touches[0].clientX - startX
    const dy = e.touches[0].clientY - startY
    if (axis === 'none') {
      if (Math.abs(dx) > 8 && Math.abs(dx) > Math.abs(dy) * 1.2) axis = 'x'
      else if (Math.abs(dy) > 8) axis = 'y'
      else return
    }
    if (axis === 'x') swipe.drag(dx)
  }

  function onTouchEnd() {
    if (axis === 'x') {
      swipedUntil = Date.now() + 300
      swipe.release()
    }
    axis = 'none'
  }

  function onTouchCancel() {
    if (axis === 'x') swipe.cancel()
    axis = 'none'
  }

  function handleOpen() {
    if (Date.now() < swipedUntil) return
    onOpen()
  }

  function coverOf(track: TrackInfo): string | null {
    if (nowCover.path === track.path && nowCover.cover) return nowCover.cover
    return trackCovers.get(track.path) ?? null
  }

  const panels = $derived([snap.previousTrack, snap.current, snap.nextTrack])
</script>

{#if snap.current}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="relative isolate mx-2 mb-1 touch-pan-y overflow-hidden rounded-lg shadow-lg shadow-black/50"
    role="region"
    aria-label={t('Now playing')}
    ontouchstart={onTouchStart}
    ontouchmove={onTouchMove}
    ontouchend={onTouchEnd}
    ontouchcancel={onTouchCancel}
  >
    <TintedBackdrop background={tintFrom(nowCover.color).surface} duration={500} />
    <div class="flex h-14 items-center gap-1 pr-1 pl-2">
      <div class="min-w-0 flex-1 overflow-hidden" bind:clientWidth={swipe.width}>
        <div
          class="flex w-[300%] will-change-transform"
          style:transform={swipe.transform}
          style:transition={swipe.transition}
        >
          {#each panels as track, i (i)}
            <div class="w-1/3 min-w-0 shrink-0" aria-hidden={i !== 1}>
              {#if track}
                <button
                  class="flex w-full min-w-0 items-center gap-3 text-left"
                  tabindex={i === 1 ? 0 : -1}
                  onclick={handleOpen}
                  aria-label={t('Open player')}
                >
                  <Cover cover={coverOf(track)} title={track.title} class="size-10 shrink-0 rounded text-xs" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sm font-semibold text-zinc-50">{track.title}</span>
                    <span class="block truncate text-xs text-zinc-400">{track.artist || t('Unknown artist')}</span>
                  </span>
                </button>
              {/if}
            </div>
          {/each}
        </div>
      </div>
      {#if isLocal}
        <FavoriteButton path={snap.current.path} title={snap.current.title} size="size-5" light />
      {/if}
      <button class="rounded-full p-2.5 text-zinc-50 active:bg-white/10" aria-label={t(snap.status === 'playing' ? 'Pause' : 'Play')} onclick={player.togglePause}>
        <Icon name={snap.status === 'playing' ? 'pause' : 'play'} class="size-7" />
      </button>
    </div>
    <div class="absolute inset-x-2 bottom-0 h-0.5 overflow-hidden rounded-full bg-white/20">
      <div class="h-full w-full origin-left bg-white" style:transform="scaleX({progress / 100})"></div>
    </div>
  </div>
{/if}

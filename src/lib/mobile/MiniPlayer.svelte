<script lang="ts">
  import { t } from '../i18n.svelte'
  import Cover from '../Cover.svelte'
  import FavoriteButton from '../FavoriteButton.svelte'
  import Icon from '../Icon.svelte'
  import TintedBackdrop from '../TintedBackdrop.svelte'
  import { player } from '../player.svelte'
  import { nowCover } from '../nowCover.svelte'
  import { tintFrom } from '../tint'

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

  // Horizontal swipe gesture for next / previous track.
  let swipeX = $state(0)
  let axis = $state<'none' | 'x' | 'y'>('none')
  let startX = 0
  let startY = 0
  let swipedUntil = 0

  function onTouchStart(e: TouchEvent) {
    if (e.touches.length !== 1) return
    startX = e.touches[0].clientX
    startY = e.touches[0].clientY
    axis = 'none'
    swipeX = 0
  }

  function onTouchMove(e: TouchEvent) {
    if (e.touches.length !== 1) return
    const dx = e.touches[0].clientX - startX
    const dy = e.touches[0].clientY - startY

    if (axis === 'none') {
      if (Math.abs(dx) > 8 && Math.abs(dx) > Math.abs(dy) * 1.2) {
        axis = 'x'
      } else if (Math.abs(dy) > 8) {
        axis = 'y'
        return
      } else {
        return
      }
    }

    if (axis === 'x') {
      swipeX = Math.max(-110, Math.min(110, dx))
    }
  }

  function onTouchEnd() {
    if (axis === 'x') {
      swipedUntil = Date.now() + 260
      if (swipeX <= -52) {
        void player.next()
      } else if (swipeX >= 52) {
        void player.previous()
      }
    }
    axis = 'none'
    swipeX = 0
  }

  function onTouchCancel() {
    axis = 'none'
    swipeX = 0
  }

  function handleOpen() {
    if (Date.now() < swipedUntil) return
    onOpen()
  }
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
      <div class="min-w-0 flex-1 overflow-hidden">
        <button
          class={[
            'flex w-full min-w-0 items-center gap-3 text-left',
            axis === 'x' ? '' : 'transition-transform duration-200 ease-out',
          ]}
          style:transform={swipeX ? `translateX(${swipeX}px)` : undefined}
          style:opacity={swipeX ? Math.max(0.45, 1 - Math.abs(swipeX) / 140) : undefined}
          onclick={handleOpen}
          aria-label={t('Open player')}
        >
          <Cover cover={nowCover.cover} title={snap.current.title} class="size-10 shrink-0 rounded text-xs" />
          <span class="min-w-0 flex-1">
            <span class="block truncate text-sm font-semibold text-zinc-50">{snap.current.title}</span>
            <span class="block truncate text-xs text-zinc-400">{snap.current.artist || t('Unknown artist')}</span>
          </span>
        </button>
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

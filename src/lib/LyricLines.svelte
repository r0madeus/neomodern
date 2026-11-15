<script lang="ts">
  import { t } from './i18n.svelte'
  import { untrack } from 'svelte'
  import { fly } from 'svelte/transition'
  import { lyrics, findActiveIndex } from './lyrics.svelte'
  import { motionDuration } from './motion'
  import { player } from './player.svelte'

  // Lyrics on a tinted surface: the playing line is white, played lines are
  // faded, upcoming lines use the tint. Follows playback until the user
  // scrolls; tapping a synced line seeks there.
  let {
    big = false,
    preview = false,
    dim,
    class: className = '',
    scrollClass = '',
  }: {
    /** Full-screen size instead of the card size. */
    big?: boolean
    /** Spotify-style preview card: bigger text, follows the song on its
     *  own and cannot be scrolled or tapped line by line (the card opens
     *  the full-screen lyrics instead). */
    preview?: boolean
    dim: string
    class?: string
    scrollClass?: string
  } = $props()

  let box = $state<HTMLDivElement | null>(null)
  let follow = $state(true)

  const res = $derived(lyrics.result)
  const active = $derived(res?.kind === 'synced' ? findActiveIndex(res.lines, player.position) : -1)

  function scrollToActive(smooth: boolean) {
    if (!box || active < 0) {
      if (box && active < 0) box.scrollTo({ top: 0, behavior: smooth ? 'smooth' : 'instant' })
      return
    }
    const el = box.querySelector<HTMLElement>(`[data-i="${active}"]`)
    if (!el) return
    // Keep the playing line about a third from the top (not scrollIntoView,
    // which would also scroll the page around the card).
    // The small preview card keeps it nearer the middle, like Spotify.
    const at = preview ? 0.38 : 1 / 3
    box.scrollTo({ top: Math.max(0, el.offsetTop - box.clientHeight * at), behavior: smooth ? 'smooth' : 'instant' })
  }

  $effect(() => {
    void active
    if (follow) untrack(() => scrollToActive(true))
  })

  // The card may get its size after the active line was set (the player
  // slides in, the card is below the fold): line it up again, instantly.
  $effect(() => {
    if (!box) return
    const ro = new ResizeObserver(() => {
      if (untrack(() => follow)) untrack(() => scrollToActive(false))
    })
    ro.observe(box)
    return () => ro.disconnect()
  })

  // New track: back to the top, following again.
  $effect(() => {
    void lyrics.trackPath
    untrack(() => {
      follow = true
      box?.scrollTo({ top: 0 })
    })
  })

  // A finger or wheel on the lyrics means the user is reading: stop following.
  function watchManualScroll(el: HTMLElement) {
    if (preview) return
    const stop = () => {
      if (res?.kind === 'synced') follow = false
    }
    el.addEventListener('touchmove', stop, { passive: true })
    el.addEventListener('wheel', stop, { passive: true })
    return () => {
      el.removeEventListener('touchmove', stop)
      el.removeEventListener('wheel', stop)
    }
  }

  function resume() {
    follow = true
    scrollToActive(true)
  }
</script>

<div class={['relative min-h-0', className]}>
  <div
    bind:this={box}
    class={[
      'no-scrollbar relative h-full',
      preview ? 'pointer-events-none overflow-hidden' : 'overflow-y-auto overscroll-contain',
      scrollClass,
    ]}
    style:mask-image={preview ? 'linear-gradient(to bottom, transparent 0, #000 18%, #000 78%, transparent 100%)' : undefined}
    role="region"
    aria-label={t("Lyrics")}
    {@attach watchManualScroll}
  >
    {#if !res && lyrics.loading}
      <p class="py-6 text-base font-semibold" style:color={dim}>{t("Looking for lyrics…")}</p>
    {:else if !res || res.kind === 'notFound'}
      <p class="py-6 text-base font-semibold" style:color={dim}>{t("No lyrics for this song.")}</p>
    {:else if res.kind === 'instrumental'}
      <p class="py-6 text-base font-semibold" style:color={dim}>{t("♪ Instrumental")}</p>
    {:else if res.kind === 'plain'}
      <div class={['pt-6 pb-8 font-bold', big ? 'space-y-4 text-[26px] leading-snug' : preview ? 'space-y-3 text-[29px] leading-[1.15]' : 'space-y-3 text-[22px] leading-snug']}>
        {#each res.lines as line, i (i)}
          {#if line.trim() === ''}
            <div class="h-3" aria-hidden="true"></div>
          {:else}
            <p class="text-white">{line}</p>
          {/if}
        {/each}
      </div>
    {:else}
      <div class={['pt-6 pb-[40vh] font-bold', big ? 'space-y-5 text-[28px] leading-tight' : preview ? 'space-y-4 text-[29px] leading-[1.15]' : 'space-y-4 text-[22px] leading-snug']}>
        {#each res.lines as line, i (i)}
          {@const blank = line.text.trim() === ''}
          <svelte:element
            this={preview ? 'p' : 'button'}
            role={preview ? undefined : 'button'}
            data-i={i}
            class={[
              'block w-full origin-left text-left transition-[color,opacity,transform] duration-300',
              i === active && !blank && 'scale-[1.02]',
              blank && 'text-base',
            ]}
            style:color={i === active ? '#fff' : i < active ? 'rgb(255 255 255 / 0.5)' : dim}
            onclick={preview
              ? undefined
              : () => {
                  follow = true
                  void player.seek(line.timeSeconds)
                }}
          >
            {blank ? '♪' : line.text}
          </svelte:element>
        {/each}
      </div>
    {/if}
  </div>
  {#if !preview && !follow && res?.kind === 'synced'}
    <button
      type="button"
      transition:fly={{ y: 12, duration: motionDuration(180) }}
      class="absolute bottom-3 left-1/2 z-10 -translate-x-1/2 rounded-full bg-white px-4 py-2 text-sm font-semibold text-zinc-950 shadow-lg hover:bg-zinc-100"
      onclick={resume}
    >
      {t("Sync")}
    </button>
  {/if}
</div>

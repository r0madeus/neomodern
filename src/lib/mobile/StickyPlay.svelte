<script lang="ts">
  import { t } from '../i18n.svelte'
  import Icon from '../Icon.svelte'
  import { motionDuration } from '../motion'

  // The big round play button of an album, playlist or artist page, Spotify
  // style. It sits at the end of the action row; once that row scrolls under
  // the page's top bar it docks *inside* the bar: a little smaller,
  // vertically centred, left of the bar's "⋯" button (`dockShift`), so it
  // never hangs over the list.
  //
  // Put it right before the action row, inside the scrolling element, with
  // the page's 56px top bar overlaying that element from its top; the row
  // keeps a `size-14` gap where the button sits. The bar's title needs
  // `pr-14` so it does not run under the docked button.
  let {
    playing,
    disabled = false,
    onclick,
    dockShift = 0,
  }: {
    /** Show pause (this list is playing). */
    playing: boolean
    disabled?: boolean
    onclick: () => void
    /** How far left of the right edge it docks (the width of the bar's
     *  "⋯" button when there is one). */
    dockShift?: number
  } = $props()

  let docked = $state(false)

  // Docked once the button reaches the top of the scrolling element, which
  // is where `sticky top-0` holds it.
  function watch(el: HTMLElement) {
    const root = el.closest<HTMLElement>('.overflow-y-auto')
    if (!root) return
    const update = () => {
      docked = el.getBoundingClientRect().top - root.getBoundingClientRect().top <= 0.5
    }
    update()
    root.addEventListener('scroll', update, { passive: true })
    return () => root.removeEventListener('scroll', update)
  }
</script>

<div class="pointer-events-none sticky top-0 z-20 flex h-0 justify-end px-4" {@attach watch}>
  <button
    type="button"
    class="pointer-events-auto flex size-14 shrink-0 items-center justify-center rounded-full bg-accent-500 text-zinc-950 shadow-lg shadow-black/40 transition-transform ease-out active:brightness-90 disabled:opacity-50"
    style:transform={docked ? `translateX(-${dockShift}px) scale(0.79)` : 'none'}
    style:transition-duration="{motionDuration(160)}ms"
    aria-label={t(playing ? 'Pause' : 'Play')}
    {disabled}
    {onclick}
  >
    <Icon name={playing ? 'pause' : 'play'} class="size-7" />
  </button>
</div>

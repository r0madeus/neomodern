<script lang="ts">
  import { t } from '../i18n.svelte'
  import Icon from '../Icon.svelte'

  // The big round play button of an album or playlist page, Spotify style:
  // it sits at the end of the action row and, once the page scrolls far
  // enough, sticks to the bottom edge of the top bar (overlapping it a little).
  // Put it right before the action row, inside the scrolling element, with
  // the page's top bar overlaying that element; the row keeps a `size-14`
  // gap where the button sits.
  let {
    playing,
    disabled = false,
    onclick,
    top = '44px',
  }: {
    /** Show pause (this list is playing). */
    playing: boolean
    disabled?: boolean
    onclick: () => void
    /** Where it sticks: the top bar's height (56px) minus the overlap. */
    top?: string
  } = $props()
</script>

<div class="pointer-events-none sticky z-20 flex h-0 justify-end px-4" style:top>
  <button
    type="button"
    class="pointer-events-auto flex size-14 shrink-0 items-center justify-center rounded-full bg-accent-500 text-zinc-950 shadow-lg shadow-black/40 active:scale-95 disabled:opacity-50"
    aria-label={t(playing ? 'Pause' : 'Play')}
    {disabled}
    {onclick}
  >
    <Icon name={playing ? 'pause' : 'play'} class="size-7" />
  </button>
</div>

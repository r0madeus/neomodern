<script lang="ts">
  import type { Snippet } from 'svelte'
  import { t } from './i18n.svelte'
  import Icon from './Icon.svelte'
  import TintedBackdrop from './TintedBackdrop.svelte'

  // Spotify-style header for an album or playlist page: a full-width band
  // on the cover's colour with the cover, a small type label, a big title and
  // one line of details; below it a quiet row with a round play button and
  // icon actions. Everything else belongs in the row's "…" menu.
  let {
    top,
    surface,
    label,
    titleText,
    cover,
    title,
    meta,
    actions,
    onBack,
    backLabel,
  }: {
    /** Colours of the band (from the cover). */
    top: string
    surface: string
    /** "Album", "Playlist". */
    label: string
    /** Used to pick the title size; `title` renders it (may be an input). */
    titleText: string
    cover: Snippet
    title?: Snippet
    meta: Snippet
    actions: Snippet
    onBack?: () => void
    backLabel?: string
  } = $props()

  // Long names get smaller type so they still fit on one or two lines.
  const titleSize = $derived(
    titleText.length <= 18
      ? 'text-6xl xl:text-7xl'
      : titleText.length <= 32
        ? 'text-5xl xl:text-6xl'
        : 'text-4xl',
  )
</script>

<div class="relative isolate text-white">
  <TintedBackdrop
    background="linear-gradient(180deg, {top} 0%, {surface} 72%, color-mix(in srgb, {surface} 40%, transparent) 90%, transparent 100%)"
  />
  {#if onBack}
    <button
      type="button"
      class="absolute top-4 left-4 z-10 rounded-full bg-black/30 p-1.5 text-white/90 outline-none hover:bg-black/50 hover:text-white focus-visible:ring-2 focus-visible:ring-white/70"
      aria-label={backLabel ?? t('Back')}
      title={backLabel ?? t('Back')}
      onclick={onBack}
    >
      <Icon name="back" class="size-5" />
    </button>
  {/if}

  <div class={['flex items-end gap-6 px-6 pb-6', onBack ? 'pt-14' : 'pt-8']}>
    <div class="shrink-0">{@render cover()}</div>
    <div class="min-w-0 flex-1 pb-1">
      <p class="text-sm font-medium text-white/90">{label}</p>
      {#if title}
        {@render title()}
      {:else}
        <h2 class={['mt-1 line-clamp-2 pb-2 leading-[1.05] font-black tracking-tight break-words', titleSize]} title={titleText}>
          {titleText}
        </h2>
      {/if}
      <div class="mt-2 flex min-w-0 flex-wrap items-center gap-x-1.5 text-sm text-white/75">
        {@render meta()}
      </div>
    </div>
  </div>

  <div class="flex items-center gap-4 px-6 pt-1 pb-5">
    {@render actions()}
  </div>
</div>

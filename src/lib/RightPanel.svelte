<script lang="ts">
  import { t } from './i18n.svelte'
  import { fly } from 'svelte/transition'
  import NowPlayingSide from './NowPlayingSide.svelte'
  import QueueSide from './QueueSide.svelte'
  import ResizeHandle from './ResizeHandle.svelte'
  import { motionDuration } from './motion'
  import { createPanelResize } from './panelResize.svelte'

  export type RightPanelMode = 'nowPlaying' | 'queue'

  let {
    mode,
    onClose,
    onExpand,
    onOpenFiles,
    onSaved,
  }: {
    mode: RightPanelMode
    onClose: () => void
    onExpand: () => void
    onOpenFiles: (append: boolean) => void
    onSaved?: (id: number) => void
  } = $props()

  let innerWidth = $state(typeof window !== 'undefined' ? window.innerWidth : 1200)
  const resize = createPanelResize({
    storageKey: 'neomodern.rightPanel.width',
    defaultWidth: 340,
    minWidth: 270,
    maxWidth: 480,
    side: 'right',
    getMaxAllowed: () => Math.max(270, innerWidth - 460),
  })

  $effect(() => () => resize.destroy())
</script>

<svelte:window bind:innerWidth />

<aside
  aria-label={t(mode === 'queue' ? 'Queue' : 'Now playing')}
  transition:fly={{ x: 24, duration: motionDuration(180) }}
  class="relative flex shrink-0 flex-col border-l border-zinc-200/80 bg-zinc-100/70 dark:border-zinc-800/80 dark:bg-zinc-900/50"
  style:width="{resize.width}px"
>
  <ResizeHandle
    edge="left"
    dragging={resize.dragging}
    value={resize.width}
    min={resize.min}
    max={resize.max}
    label={t('Resize right panel')}
    onPointerDown={resize.onPointerDown}
    onKeyDown={resize.onKeyDown}
    onReset={resize.reset}
  />

  {#if mode === 'nowPlaying'}
    <NowPlayingSide {onClose} {onExpand} />
  {:else}
    <QueueSide {onClose} {onOpenFiles} {onSaved} />
  {/if}
</aside>

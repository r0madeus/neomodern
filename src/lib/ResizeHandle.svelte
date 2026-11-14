<script lang="ts">
  // Interactive border divider for horizontally resizing side panels.
  let {
    edge,
    dragging = false,
    value,
    min,
    max,
    label,
    onPointerDown,
    onKeyDown,
    onReset,
  }: {
    /** Which edge of the panel the handle sits on. */
    edge: 'left' | 'right'
    dragging?: boolean
    value: number
    min: number
    max: number
    label: string
    onPointerDown: (e: PointerEvent) => void
    onKeyDown: (e: KeyboardEvent) => void
    onReset: () => void
  } = $props()
</script>

<!-- WAI-ARIA Window Splitter pattern: focusable vertical separator for keyboard and pointer resize. -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
<div
  role="separator"
  aria-orientation="vertical"
  aria-label={label}
  aria-valuenow={value}
  aria-valuemin={min}
  aria-valuemax={max}
  tabindex="0"
  onpointerdown={onPointerDown}
  onkeydown={onKeyDown}
  ondblclick={onReset}
  class={[
    'group absolute inset-y-0 z-20 w-1.5 cursor-col-resize touch-none outline-none select-none',
    edge === 'right' ? '-right-[3px]' : 'left-0',
  ]}
>
  <span
    class={[
      'pointer-events-none absolute inset-y-0 w-0.5 transition-colors',
      edge === 'right' ? 'left-1/2 -translate-x-1/2' : 'left-0',
      dragging
        ? 'bg-accent-500'
        : 'bg-transparent group-hover:bg-accent-500/60 group-focus-visible:bg-accent-500',
    ]}
  ></span>
</div>

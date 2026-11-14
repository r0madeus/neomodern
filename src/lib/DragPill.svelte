<script lang="ts">
  // Floating track label attached to the cursor during a drag reorder.
  let {
    active,
    x,
    y,
    label,
  }: {
    active: boolean
    x: number
    y: number
    label: string
  } = $props()
</script>

{#if active && label}
  <div
    class="pointer-events-none fixed z-50 max-w-64 truncate rounded-lg bg-zinc-900/95 px-3 py-1.5 text-xs font-medium text-white shadow-xl ring-1 ring-white/15 dark:bg-zinc-800/95"
    style:left="{x + 14}px"
    style:top="{y - 16}px"
  >
    {label}
  </div>
{/if}

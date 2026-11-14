<script lang="ts">
  // Insertion line rendered inside a relatively-positioned list container during drag reorder.
  let {
    count,
    rowHeight,
    gap,
    from,
    to,
  }: {
    count: number
    rowHeight: number
    gap: number | null
    from: number | null
    to: number | null
  } = $props()
</script>

{#if from !== null && gap !== null && to !== null && to !== from}
  <div
    class="pointer-events-none absolute inset-x-3 z-20 flex items-center"
    style:top="{Math.max(0, Math.min(count * rowHeight - 2, gap * rowHeight - 1))}px"
  >
    <span class="-ml-1 size-2 rounded-full bg-accent-500"></span>
    <span class="h-0.5 flex-1 bg-accent-500"></span>
  </div>
{/if}

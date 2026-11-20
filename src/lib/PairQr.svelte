<script lang="ts">
  import type { PairQr } from './sync.svelte'

  // The pairing QR code (K23), drawn from the modules Rust computed. Always
  // dark on white with a quiet zone, also in dark mode, so cameras read it.
  let { qr, label }: { qr: PairQr; label: string } = $props()

  const QUIET = 4
  const path = $derived.by(() => {
    let d = ''
    for (let y = 0; y < qr.size; y++) {
      for (let x = 0; x < qr.size; x++) {
        if (qr.modules.charCodeAt(y * qr.size + x) === 49) d += `M${x} ${y}h1v1h-1z`
      }
    }
    return d
  })
</script>

<svg
  class="size-44 rounded-lg"
  viewBox="{-QUIET} {-QUIET} {qr.size + 2 * QUIET} {qr.size + 2 * QUIET}"
  shape-rendering="crispEdges"
  role="img"
  aria-label={label}
>
  <rect x={-QUIET} y={-QUIET} width={qr.size + 2 * QUIET} height={qr.size + 2 * QUIET} fill="#fff" />
  <path d={path} fill="#000" />
</svg>

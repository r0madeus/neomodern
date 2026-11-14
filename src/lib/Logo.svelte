<script lang="ts">
  // The NeoModern mark: an arch with a short line inside. Drawn in
  // currentColor; the app icons are generated from
  // src-tauri/icons/source (see the README there).
  let { class: className = '' }: { class?: string } = $props()
</script>

<svg viewBox="12 12 40 40" class={className} aria-hidden="true">
  <path
    d="M18 49V30a14 14 0 0 1 28 0v19M32 33v13"
    fill="none"
    stroke="currentColor"
    stroke-width="7.5"
    stroke-linecap="round"
  />
</svg>

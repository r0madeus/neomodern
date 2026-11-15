<script lang="ts">
  import { library } from './library.svelte'

  // A song's title that opens its album when clicked, like Spotify. Give
  // the album id when known; otherwise the path is looked up on click
  // (the player only knows the path). Without either it is plain text.
  let {
    title,
    albumId = null,
    path = null,
    class: className = '',
    linkClass = 'hover:underline',
  }: {
    title: string
    albumId?: number | null
    path?: string | null
    class?: string
    linkClass?: string
  } = $props()

  const linked = $derived((albumId !== null && albumId !== undefined) || !!path)

  async function open(e: MouseEvent) {
    e.stopPropagation()
    let id = albumId
    if ((id === null || id === undefined) && path) id = (await library.trackByPath(path))?.albumId ?? null
    if (id !== null && id !== undefined) library.openAlbum(id)
  }
</script>

{#if linked}
  <button
    type="button"
    tabindex="-1"
    class={['inline max-w-full truncate text-left outline-none', linkClass, className]}
    onclick={(e) => void open(e)}
    ondblclick={(e) => e.stopPropagation()}
  >{title}</button>
{:else}
  <span class={className}>{title}</span>
{/if}

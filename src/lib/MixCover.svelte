<script lang="ts">
  import Cover from './Cover.svelte'
  import Icon from './Icon.svelte'
  import { artists } from './artists.svelte'
  import { genreColor } from './genreColor'
  import { mixTitle, type DynamicMix } from './home.svelte'
  import PlaylistCover from './PlaylistCover.svelte'

  // The cover of an automatic mix, drawn here (no image is stored or sent
  // over IPC), with a design of its own per kind of mix, like the daily
  // mixes of the big streaming apps:
  //  - weekly favourites: a tilted cover over a big "7" (days)
  //  - on repeat: a round "record" inside rings
  //  - rediscover: a polaroid with sparkles
  //  - an artist's mix: the artist's profile photo (else an album cover) in
  //    a circle over a coloured band with the name
  //  - a genre's mix: tilted covers on the genre's colour
  // Sizes use container units, so it scales from a small tile to a hero.
  let { mix, class: className = '' }: { mix: DynamicMix; class?: string } = $props()

  const title = $derived(mixTitle(mix))
  const covers = $derived(mix.albumCovers)
  const first = $derived(covers[0] ?? null)
  const second = $derived(covers[1] ?? covers[0] ?? null)
  const third = $derived(covers[2] ?? covers[1] ?? covers[0] ?? null)
  const artistMix = $derived(mix.kind === 'focus-mix' && mix.subjectKind === 'artist')
  const genreMix = $derived(mix.kind === 'focus-mix' && mix.subjectKind !== 'artist')
  const tint = $derived(genreColor(mix.subject ?? title))

  // The artist's profile photo, when the app has one stored; else an album
  // cover. Reading the profile is local (the photo was fetched earlier).
  let portrait = $state<string | null>(null)
  $effect(() => {
    const name = artistMix ? mix.subject : null
    portrait = null
    if (!name) return
    let stale = false
    artists
      .profile(name)
      .then((p) => {
        if (!stale) portrait = p.image ?? p.fallbackCover ?? null
      })
      .catch(() => {})
    return () => {
      stale = true
    }
  })
  const photo = $derived(portrait ?? first)
</script>

<div
  class={['relative isolate aspect-square shrink-0 overflow-hidden text-white shadow-sm', className]}
  style="container-type: inline-size"
>
  {#if mix.kind === 'weekly-favorites'}
    <div class="absolute inset-0" style="background: linear-gradient(150deg, #19c3a1 0%, #0b6e63 55%, #06302e 100%)"></div>
    <span
      class="absolute -top-[10cqw] -left-[3cqw] font-black leading-none text-white/15 select-none"
      style="font-size: 78cqw">7</span
    >
    {#if first}
      <Cover
        cover={first}
        {title}
        class="absolute top-[12cqw] right-[9cqw] size-[52cqw] rotate-[7deg] rounded-[3cqw] shadow-xl shadow-black/50"
      />
    {/if}
    <div class="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/60 to-transparent px-[7cqw] pt-[14cqw] pb-[6cqw]">
      <p class="line-clamp-2 font-extrabold leading-[1.05] tracking-tight" style="font-size: 11cqw">{title}</p>
    </div>
  {:else if mix.kind === 'on-repeat'}
    <div class="absolute inset-0" style="background: linear-gradient(160deg, #6d5bf0 0%, #3a2aa8 55%, #150f4a 100%)"></div>
    <svg class="absolute inset-0 size-full text-white" viewBox="0 0 100 100" fill="none" aria-hidden="true">
      <circle cx="50" cy="44" r="42" stroke="currentColor" stroke-opacity="0.08" stroke-width="6" />
      <circle cx="50" cy="44" r="33" stroke="currentColor" stroke-opacity="0.13" stroke-width="4" />
      <circle cx="50" cy="44" r="26" stroke="currentColor" stroke-opacity="0.2" stroke-width="2" />
    </svg>
    {#if first}
      <Cover
        cover={first}
        {title}
        class="absolute top-[19cqw] left-1/2 size-[50cqw] -translate-x-1/2 rounded-full ring-[1.6cqw] ring-white/80 shadow-xl shadow-black/50"
      />
    {/if}
    <span class="absolute top-[7cqw] right-[7cqw] flex size-[11cqw] items-center justify-center rounded-full bg-white/20">
      <Icon name="repeat" class="size-[6.5cqw]" />
    </span>
    <p
      class="absolute inset-x-[7cqw] bottom-[6cqw] line-clamp-2 font-extrabold leading-[1.05] tracking-tight"
      style="font-size: 11cqw"
    >
      {title}
    </p>
  {:else if mix.kind === 'rediscover'}
    <div class="absolute inset-0" style="background: linear-gradient(145deg, #ffb347 0%, #e0701f 60%, #8f3a12 100%)"></div>
    <span class="absolute top-[8cqw] left-[9cqw] text-white/80 select-none" style="font-size: 12cqw">✦</span>
    <span class="absolute top-[30cqw] right-[8cqw] text-white/60 select-none" style="font-size: 8cqw">✦</span>
    <span class="absolute top-[52cqw] left-[6cqw] text-white/50 select-none" style="font-size: 6cqw">✦</span>
    {#if first}
      <div class="absolute top-[10cqw] left-1/2 -translate-x-1/2 -rotate-[6deg] bg-[#fffaf0] p-[2.6cqw] pb-[7cqw] shadow-xl shadow-black/40">
        <Cover cover={first} {title} class="size-[44cqw]" />
      </div>
    {/if}
    <p
      class="absolute inset-x-[7cqw] bottom-[6cqw] line-clamp-2 font-extrabold leading-[1.05] tracking-tight text-[#2b1304]"
      style="font-size: 11cqw"
    >
      {title}
    </p>
  {:else if artistMix}
    <div class="absolute inset-0 bg-[#f4f1ea]"></div>
    <div class="absolute inset-x-0 bottom-0 h-[38cqw]" style:background-color={tint}></div>
    <span class="absolute top-[6cqw] left-[7cqw] font-black tracking-[0.18em] text-black/70" style="font-size: 5cqw">MIX</span>
    <div
      class="absolute top-[11cqw] left-1/2 size-[56cqw] -translate-x-1/2 overflow-hidden rounded-full ring-[1.4cqw] ring-white shadow-lg shadow-black/30"
      style:background-color={tint}
    >
      {#if photo}
        <Cover cover={photo} {title} class="size-full" />
      {:else}
        <span class="flex size-full items-center justify-center text-white" style="font-size: 22cqw">
          <Icon name="music" class="size-[24cqw]" />
        </span>
      {/if}
    </div>
    <p
      class="absolute inset-x-[7cqw] bottom-[5cqw] line-clamp-2 text-center font-extrabold leading-[1.05] tracking-tight"
      style="font-size: 11cqw"
    >
      {title}
    </p>
  {:else if genreMix}
    <div class="absolute inset-0" style:background-color={tint}></div>
    <div class="absolute inset-0 bg-gradient-to-b from-white/10 to-black/25"></div>
    {#each [third, second, first] as c, i (i)}
      {#if c}
        <div
          class="absolute size-[40cqw] overflow-hidden rounded-[2.5cqw] shadow-xl shadow-black/45"
          style="top: {8 + i * 6}cqw; right: {-4 + (2 - i) * 14}cqw; transform: rotate({[-8, 4, 16][i]}deg)"
        >
          <Cover cover={c} {title} class="size-full" />
        </div>
      {/if}
    {/each}
    <p
      class="absolute inset-x-[7cqw] bottom-[6cqw] line-clamp-2 font-extrabold leading-[1.05] tracking-tight drop-shadow-sm"
      style="font-size: 12cqw"
    >
      {title}
    </p>
  {:else}
    <PlaylistCover cover={null} albumCovers={covers} name={title} class="size-full rounded-none" />
  {/if}
</div>

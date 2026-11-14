<script lang="ts">
  import { t } from './i18n.svelte'
  import { fade } from 'svelte/transition'
  import Icon from './Icon.svelte'
  import LyricLines from './LyricLines.svelte'
  import LyricsShare from './LyricsShare.svelte'
  import TintedBackdrop from './TintedBackdrop.svelte'
  import { lyrics, type LyricsSource } from './lyrics.svelte'
  import { motionDuration } from './motion'
  import { player } from './player.svelte'
  import { nowCover } from './nowCover.svelte'
  import { tintFrom } from './tint'

  const SOURCE_LABELS: Record<LyricsSource, string> = {
    localLrc: 'Local .lrc',
    lrclib: 'LRCLIB',
    embedded: 'Embedded tag',
    netease: 'NetEase',
  }

  const current = $derived(player.snapshot.current)
  const duration = $derived(player.snapshot.durationSeconds)
  const res = $derived(lyrics.result)
  const tint = $derived(tintFrom(nowCover.color))

  function refresh() {
    if (!current) return
    void lyrics.load(current.path, duration, true)
  }

  async function attachLocal() {
    if (!current || lyrics.loading) return
    await lyrics.pickAndAttach(current.path)
  }

  const iconButton =
    'rounded-full p-2 text-white/75 transition hover:bg-white/10 hover:text-white disabled:opacity-40 outline-none focus-visible:ring-2 focus-visible:ring-white/60'
</script>

<div
  transition:fade={{ duration: motionDuration(150) }}
  class="relative isolate flex h-full flex-col overflow-hidden text-white"
  role="region"
  aria-label={t('Lyrics')}
>
  <TintedBackdrop background={tint.surface} />
  <header class="flex shrink-0 items-center justify-between gap-3 px-8 pt-5 pb-2">
    <div class="flex min-w-0 items-center gap-2.5">
      {#if current}
        <p class="truncate text-sm font-semibold text-white/90" title={current.path}>
          {current.title}{current.artist ? ` · ${current.artist}` : ''}
        </p>
      {:else}
        <h2 class="text-sm font-semibold text-white/90">{t('Lyrics')}</h2>
      {/if}
      {#if res && res.kind !== 'notFound'}
        <span class="shrink-0 rounded bg-black/25 px-1.5 py-0.5 text-[11px] font-medium text-white/80">
          {t(SOURCE_LABELS[res.source])}
        </span>
      {/if}
    </div>
    <div class="flex shrink-0 items-center gap-0.5">
      <button
        type="button"
        class={iconButton}
        onclick={() => void attachLocal()}
        disabled={!current || lyrics.loading}
        aria-label={t('Load .lrc file')}
        title={t('Load .lrc file')}
      >
        <Icon name="upload" class="size-4" />
      </button>
      <button
        type="button"
        class={iconButton}
        onclick={refresh}
        disabled={!current || lyrics.loading}
        aria-label={t('Refresh lyrics')}
        title={t('Refresh lyrics')}
      >
        <Icon name="refresh" class={lyrics.loading ? 'size-4 animate-spin' : 'size-4'} />
      </button>
      <button
        type="button"
        class={iconButton}
        onclick={() => lyrics.setOpen(false)}
        aria-label={t('Close lyrics')}
        title={t('Close lyrics')}
      >
        <Icon name="close" class="size-4" />
      </button>
    </div>
  </header>

  {#if !current}
    <div class="flex flex-1 items-center justify-center px-8 text-center text-sm text-white/65">
      {t('Play a track to see lyrics.')}
    </div>
  {:else if (lyrics.error && (!res || res.kind === 'notFound')) || (!lyrics.loading && res?.kind === 'notFound')}
    <div class="flex flex-1 flex-col items-center justify-center gap-3 px-8 text-center">
      <p class="text-base text-white/80">{lyrics.error ?? t('No lyrics found.')}</p>
      <div class="flex items-center gap-2">
        <button
          type="button"
          class="rounded-full px-3.5 py-1.5 text-xs font-semibold text-white/85 hover:bg-white/10"
          onclick={refresh}
        >
          {t('Retry')}
        </button>
        <button
          type="button"
          class="rounded-full bg-white px-3.5 py-1.5 text-xs font-semibold text-zinc-950 hover:bg-white/90"
          onclick={() => void attachLocal()}
        >
          {t('Load .lrc')}
        </button>
      </div>
    </div>
  {:else}
    {#if lyrics.error}
      <p class="mx-auto w-full max-w-3xl px-8 pb-2 text-xs text-red-200">{lyrics.error}</p>
    {/if}
    <LyricLines
      big
      dim={tint.dim}
      class="mx-auto w-full max-w-3xl flex-1 px-8"
      scrollClass="[mask-image:linear-gradient(to_bottom,transparent,black_20px,black_88%,transparent)]"
    />
    <LyricsShare class="mx-auto w-full max-w-3xl shrink-0 px-8 pb-4" />
  {/if}
</div>

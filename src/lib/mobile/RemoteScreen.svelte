<script lang="ts">
  import { onMount, untrack } from 'svelte'
  import { fly } from 'svelte/transition'
  import Cover from '../Cover.svelte'
  import Equalizer from '../Equalizer.svelte'
  import Icon from '../Icon.svelte'
  import { t } from '../i18n.svelte'
  import { motionDuration, viewportHeight } from '../motion'
  import { formatTime } from '../player.svelte'
  import { sync } from '../sync.svelte'
  import { nextRepeat, remoteErrorKind } from '../syncLogic'

  // Remote control: what the paired computer plays, its controls and its
  // queue (docs/SYNC.md, goal 2). Everything goes through `remote_send`;
  // the computer's state comes back as events.
  let { onClose }: { onClose: () => void } = $props()

  const computer = $derived(sync.computer)
  const remote = $derived(computer?.connected ? sync.remote : null)
  const track = $derived(remote?.current ?? null)
  const playing = $derived(remote?.status === 'playing')

  // Position: interpolated between the ≤ 4/s updates (10 frames/s is enough
  // for a seek bar), only while playing and shown.
  let nowPerf = $state(performance.now())
  $effect(() => {
    if (!playing) return
    const id = setInterval(() => (nowPerf = performance.now()), 100)
    return () => clearInterval(id)
  })
  let dragging = $state<number | null>(null)
  const duration = $derived(sync.duration)
  const shown = $derived(dragging ?? sync.positionAt(nowPerf))
  const progress = $derived(duration ? Math.min(100, (shown / duration) * 100) : 0)
  function commitSeek() {
    if (dragging !== null) void sync.seek(dragging)
    dragging = null
  }

  // The phone's own cover of the same song, if it has it.
  let cover = $state<string | null>(null)
  $effect(() => {
    const key = track?.key ?? ''
    let stale = false
    cover = null
    void sync.coverForKey(key).then((c) => {
      if (!stale) cover = c
    })
    return () => (stale = true)
  })

  // The queue: loaded once when the screen opens or the computer
  // (re)connects; later changes reload it from the store (queueVersion).
  const connected = $derived(remote !== null)
  $effect(() => {
    if (!connected) return
    untrack(() => {
      if (sync.queueVersion < 0 && !sync.queueLoading) void sync.loadQueue(true)
    })
  })
  onMount(() => void sync.refreshRemote())
  // The computer sends "Next up" in play order (shuffle applied).
  const upNext = $derived(sync.queue.filter((e) => e.index !== remote?.currentIndex))

  let pendingIndex = $state<number | null>(null)
  async function playEntry(index: number) {
    if (pendingIndex !== null) return
    pendingIndex = index
    try {
      await sync.playIndex(index)
    } finally {
      pendingIndex = null
    }
  }

  // A refused command shows a short line for a few seconds.
  const errorText = $derived.by(() => {
    const e = sync.remoteError
    if (!e) return null
    switch (remoteErrorKind(e)) {
      case 'staleQueue':
        return t('The queue changed on the computer. The list was reloaded; try again.')
      case 'rateLimited':
        return t('Too many taps at once. Try again in a moment.')
      case 'notConnected':
        return t('Not connected to the computer.')
      case 'noAnswer':
        return t('The computer did not answer.')
      default:
        return e
    }
  })
  $effect(() => {
    if (!sync.remoteError) return
    const id = setTimeout(() => (sync.remoteError = null), 5000)
    return () => clearTimeout(id)
  })

  const reconnecting = $derived(sync.busy === 'syncNow')
  const syncError = $derived(sync.error?.action === 'syncNow' ? sync.error.message : null)

  const repeat = $derived(remote?.repeat ?? 'off')
  const btn = 'rounded-full p-3 active:bg-white/10 disabled:opacity-40'
</script>

<div
  class="fixed inset-0 z-40 isolate overflow-hidden bg-zinc-950 text-white"
  transition:fly={{ y: viewportHeight(), duration: motionDuration(260), opacity: 1 }}
  role="dialog"
  tabindex="-1"
  aria-modal="true"
  aria-label={t('Remote control')}
>
  <div class="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[55vh] bg-gradient-to-b from-accent-500/25 to-transparent"></div>
  <div class="h-full overflow-x-hidden overflow-y-auto overscroll-contain" style:padding-top="var(--inset-top)">
    <header class="flex h-14 shrink-0 items-center px-3">
      <button class="rounded-full p-3 active:bg-white/10" aria-label={t('Close remote control')} onclick={onClose}>
        <Icon name="down" class="size-7" />
      </button>
      <div class="min-w-0 flex-1 text-center leading-tight">
        <p class="text-[11px] tracking-widest text-white/70 uppercase">{t('Playing on')}</p>
        <p class="truncate text-sm font-bold">{computer?.name ?? t('Computer')}</p>
      </div>
      <span class="flex w-12 justify-center" role="status" aria-label={computer?.connected ? t('Connected') : t('Not connected')}>
        <span class={['size-2.5 rounded-full', computer?.connected ? 'bg-emerald-400' : 'bg-zinc-600']}></span>
      </span>
    </header>

    {#if !computer?.connected}
      <section class="flex flex-col items-center gap-4 px-8 pt-16 text-center" style:padding-bottom="calc(var(--inset-bottom) + 24px)">
        <span class="flex size-20 items-center justify-center rounded-full bg-zinc-900 text-zinc-400">
          <Icon name="computer" class="size-9" />
        </span>
        <div>
          <h2 class="text-lg font-bold">
            {computer ? t('Not connected to {device}', { device: computer.name }) : t('No computer is paired')}
          </h2>
          <p class="mt-1.5 text-sm text-zinc-400">
            {computer
              ? t('Make sure NeoModern is open on the computer, “Allow phone connections” is on, and both devices are on the same Wi-Fi.')
              : t('Pair with a computer in Settings › Computer.')}
          </p>
          {#if computer?.lastError}
            <p class="mt-2 text-xs text-red-300">{computer.lastError}</p>
          {/if}
          {#if syncError}
            <p class="mt-2 text-xs text-red-300" role="alert">{syncError}</p>
          {/if}
        </div>
        {#if computer}
          <button
            type="button"
            class="rounded-full bg-white px-6 py-2.5 text-sm font-semibold text-zinc-950 active:scale-95 disabled:opacity-60"
            disabled={reconnecting}
            onclick={() => void sync.syncNow()}
          >
            {reconnecting ? t('Connecting…') : t('Try again')}
          </button>
        {/if}
      </section>
    {:else if !remote}
      <p class="px-6 pt-16 text-center text-sm text-zinc-400" role="status">{t('Loading…')}</p>
    {:else}
      <section class="flex flex-col px-6">
        <div class="flex justify-center pt-2">
          <Cover
            {cover}
            title={track?.title ?? '♪'}
            class="aspect-square w-full max-w-[min(20rem,62vh)] rounded-lg text-6xl shadow-2xl shadow-black/50"
          />
        </div>

        <div class="mt-6 min-w-0">
          {#if track}
            <h2 class="truncate text-[22px] leading-tight font-bold">{track.title}</h2>
            <p class="mt-0.5 truncate text-base text-white/70">
              {track.artist || t('Unknown artist')}{#if track.album}<span class="opacity-60">{' · '}</span>{track.album}{/if}
            </p>
          {:else}
            <h2 class="text-[22px] leading-tight font-bold text-white/60">{t('Nothing is playing')}</h2>
          {/if}
        </div>

        <div class="mt-5">
          <input
            type="range"
            class="seek touch light w-full"
            style:--progress="{progress}%"
            min="0"
            max={duration ?? 0}
            step="0.1"
            value={shown}
            disabled={!duration || !track}
            aria-label={t('Seek')}
            oninput={(e) => (dragging = e.currentTarget.valueAsNumber)}
            onchange={commitSeek}
          />
          <div class="mt-1.5 flex justify-between text-xs tabular-nums text-white/60">
            <span>{formatTime(shown)}</span>
            <span>{formatTime(duration)}</span>
          </div>
        </div>

        <div class="mt-2 flex items-center justify-between">
          <button
            class={['relative', btn, remote.shuffle ? 'text-accent-400' : 'text-white']}
            aria-pressed={remote.shuffle}
            aria-label={t(remote.shuffle ? 'Shuffle on' : 'Shuffle off')}
            onclick={() => void sync.send({ kind: 'setShuffle', on: !remote.shuffle })}
          >
            <Icon name="shuffle" class="size-6" />
            {#if remote.shuffle}<span class="absolute bottom-1 left-1/2 size-1 -translate-x-1/2 rounded-full bg-accent-400"></span>{/if}
          </button>
          <button class="rounded-full p-2 active:bg-white/10" aria-label={t('Previous')} onclick={() => void sync.send({ kind: 'previous' })}>
            <Icon name="prev" class="size-10" />
          </button>
          <button
            class="flex size-[72px] items-center justify-center rounded-full bg-white text-zinc-950 active:scale-95"
            aria-label={t(playing ? 'Pause' : 'Play')}
            onclick={() => void sync.send({ kind: 'togglePause' })}
          >
            <Icon name={playing ? 'pause' : 'play'} class="size-9" />
          </button>
          <button class="rounded-full p-2 active:bg-white/10" aria-label={t('Next')} onclick={() => void sync.send({ kind: 'next' })}>
            <Icon name="next" class="size-10" />
          </button>
          <button
            class={['relative', btn, repeat !== 'off' ? 'text-accent-400' : 'text-white']}
            aria-pressed={repeat !== 'off'}
            aria-label={t(repeat === 'one' ? 'Repeat one' : repeat === 'all' ? 'Repeat all' : 'Repeat off')}
            onclick={() => void sync.send({ kind: 'setRepeat', mode: nextRepeat(repeat) })}
          >
            <Icon name={repeat === 'one' ? 'repeatOne' : 'repeat'} class="size-6" />
            {#if repeat !== 'off'}<span class="absolute bottom-1 left-1/2 size-1 -translate-x-1/2 rounded-full bg-accent-400"></span>{/if}
          </button>
        </div>

        <div class="mt-3 flex items-center gap-3 text-white/70">
          <Icon name={remote.volume === 0 ? 'mute' : 'volume'} class="size-5 shrink-0" />
          <input
            type="range"
            class="seek touch light w-full"
            style:--progress="{remote.volume}%"
            min="0"
            max="100"
            step="1"
            value={remote.volume}
            aria-label={t('Volume')}
            oninput={(e) => sync.setVolume(e.currentTarget.valueAsNumber)}
            onchange={() => sync.commitVolume()}
          />
          <span class="w-8 shrink-0 text-right text-xs tabular-nums">{Math.round(remote.volume)}</span>
        </div>

        {#if errorText}
          <div role="alert" class="mt-3">
            <button
              type="button"
              class="w-full rounded-lg bg-red-950/80 px-3 py-2 text-left text-sm text-red-200"
              onclick={() => (sync.remoteError = null)}
            >
              {errorText}
            </button>
          </div>
        {/if}
      </section>

      <section class="mt-6 px-2" style:padding-bottom="calc(var(--inset-bottom) + 24px)" aria-labelledby="remote-queue">
        <h3 id="remote-queue" class="px-4 pb-2 text-base font-bold">{t('Next up')}</h3>
        {#if upNext.length === 0 && !sync.queueLoading && !sync.queueHasMore}
          <p class="px-4 py-2 text-sm text-zinc-500">{t('Nothing else in the queue.')}</p>
        {:else}
          <ol>
            {#each upNext as entry (entry.index)}
              <li>
                <button
                  type="button"
                  class="flex h-14 w-full items-center gap-3 rounded-lg px-4 text-left active:bg-white/10 disabled:opacity-60"
                  disabled={pendingIndex !== null}
                  onclick={() => void playEntry(entry.index)}
                >
                  <span class="w-7 shrink-0 text-right text-xs tabular-nums text-zinc-500">{entry.index + 1}</span>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-[15px]">{entry.title}</span>
                    <span class="block truncate text-[13px] text-zinc-400">{entry.artist || t('Unknown artist')}</span>
                  </span>
                  {#if pendingIndex === entry.index}
                    <Equalizer class="shrink-0" />
                  {/if}
                </button>
              </li>
            {/each}
          </ol>
          {#if sync.queueHasMore || sync.queueLoading}
            <div class="flex justify-center py-3">
              <button
                type="button"
                class="rounded-full bg-zinc-800 px-4 py-2 text-sm font-semibold active:bg-zinc-700 disabled:opacity-50"
                disabled={sync.queueLoading}
                onclick={() => void sync.loadQueue()}
              >
                {sync.queueLoading ? t('Loading…') : t('Show more')}
              </button>
            </div>
          {/if}
        {/if}
      </section>
    {/if}
  </div>
</div>

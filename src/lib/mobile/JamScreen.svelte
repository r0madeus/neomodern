<script lang="ts">
  import { untrack } from 'svelte'
  import { fly } from 'svelte/transition'
  import Equalizer from '../Equalizer.svelte'
  import Icon from '../Icon.svelte'
  import { t } from '../i18n.svelte'
  import { jam } from '../jam.svelte'
  import { explainJamError, formatDurationMs, JAM_QUERY_MAX, shortName } from '../jamLogic'
  import { motionDuration, viewportHeight } from '../motion'
  import { sync } from '../sync.svelte'
  import { checkAddress, discoveryView, normalizePairCode, PAIR_CODE_DIGITS, type FoundComputer } from '../syncLogic'

  // A Jam on the phone (docs/JAM.md): joining (scan the host's QR code or
  // type its code), then what the host plays, what comes next and a search
  // of the host's library to add songs. A guest can do nothing else.
  let { onClose }: { onClose: () => void } = $props()

  const guest = $derived(jam.guest)
  const joined = $derived(jam.joined)
  const jamState = $derived(jam.state)
  const hostName = $derived(jamState?.hostName || guest?.hostName || t('Computer'))

  // Join ---------------------------------------------------------------------------
  let code = $state('')
  let address = $state('')
  let addressTouched = $state(false)
  let codeInput = $state<HTMLInputElement | null>(null)
  const addressCheck = $derived(checkAddress(address))
  // The address is optional: the computer is also found on the Wi-Fi.
  const addressBad = $derived(addressTouched && !addressCheck.ok && addressCheck.reason !== 'empty')
  const joining = $derived(jam.busy === 'join' || guest?.connecting === true)
  const canJoin = $derived(code.length === PAIR_CODE_DIGITS && !addressBad && !joining)
  const view = $derived(discoveryView(sync.searching, sync.searched, sync.found))

  // Look for computers once when the join form shows.
  $effect(() => {
    if (jam.guestEnabled && !joined) untrack(() => void sync.discover())
  })

  function pickFound(f: FoundComputer) {
    address = f.address
    addressTouched = false
    codeInput?.focus()
  }

  async function join(e: SubmitEvent) {
    e.preventDefault()
    addressTouched = true
    if (!canJoin) return
    const at = addressCheck.ok ? addressCheck.address : null
    if (await jam.join(at, code)) code = ''
  }

  const joinError = $derived.by(() => {
    if (jam.error?.action === 'join') return explainJamError(jam.error.message, t)
    if (!joined && guest?.error) return explainJamError(guest.error, t)
    return null
  })
  const leaveError = $derived(jam.error?.action === 'leave' ? jam.error.message : null)
  const searchError = $derived(jam.error?.action === 'search' ? explainJamError(jam.error.message, t) : null)

  async function leave() {
    if (await jam.leave()) onClose()
  }

  // Adding: a short line for a few seconds, refused or taken.
  let notice = $state<{ text: string; error: boolean } | null>(null)
  $effect(() => {
    if (!notice) return
    const id = setTimeout(() => (notice = null), 3500)
    return () => clearTimeout(id)
  })
  async function add(trackId: number) {
    const ok = await jam.add(trackId)
    notice = ok
      ? { text: t('Added to the queue'), error: false }
      : { text: explainJamError(jam.addError ?? '', t), error: true }
  }

  const searchingNow = $derived(jam.query.trim() !== '')
  const input =
    'w-full rounded-xl border border-zinc-700 bg-zinc-900 px-3 py-2.5 text-[15px] text-white outline-none transition placeholder:text-zinc-500 focus:border-accent-500 focus:ring-2 focus:ring-accent-500/30'
</script>

<div
  class="fixed inset-0 z-40 isolate overflow-hidden bg-zinc-950 text-white"
  transition:fly={{ y: viewportHeight(), duration: motionDuration(260), opacity: 1 }}
  role="dialog"
  tabindex="-1"
  aria-modal="true"
  aria-label={t('Jam')}
>
  <div class="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[45vh] bg-gradient-to-b from-accent-500/25 to-transparent"></div>
  <div class="h-full overflow-x-hidden overflow-y-auto overscroll-contain" style:padding-top="var(--inset-top)">
    <header class="flex h-14 shrink-0 items-center px-3">
      <button class="rounded-full p-3 active:bg-white/10" aria-label={t('Close')} onclick={onClose}>
        <Icon name="down" class="size-7" />
      </button>
      <div class="min-w-0 flex-1 text-center leading-tight">
        {#if joined}
          <p class="text-[11px] tracking-widest text-white/70 uppercase">{t('Jam on')}</p>
          <p class="truncate text-sm font-bold">{hostName}</p>
        {:else}
          <p class="truncate text-sm font-bold">{t('Join a Jam')}</p>
        {/if}
      </div>
      {#if joined}
        <button
          type="button"
          class="rounded-full px-3 py-2 text-sm font-semibold text-white/80 active:bg-white/10 disabled:opacity-50"
          disabled={jam.busy === 'leave'}
          onclick={() => void leave()}
        >
          {t('Leave')}
        </button>
      {:else}
        <span class="w-12"></span>
      {/if}
    </header>

    {#if !jam.guestEnabled}
      <section class="flex flex-col items-center gap-4 px-8 pt-16 text-center">
        <span class="flex size-20 items-center justify-center rounded-full bg-zinc-900 text-zinc-400">
          <Icon name="jam" class="size-9" />
        </span>
        <p class="text-sm text-zinc-400">{t('Turn on “Join Jams” in Settings › Experimental.')}</p>
      </section>
    {:else if !joined}
      <form class="flex flex-col gap-4 px-5 pt-4" style:padding-bottom="calc(var(--inset-bottom) + 24px)" onsubmit={join} novalidate>
        <div class="flex flex-col items-center gap-3 text-center">
          <span class="flex size-16 items-center justify-center rounded-full bg-accent-500/20 text-accent-300">
            <Icon name="jam" class="size-8" />
          </span>
          <div>
            <h2 class="text-xl font-bold">{t('Add songs to the party')}</h2>
            <p class="mt-1 text-sm text-zinc-400">
              {t('On the computer, choose “Start a Jam” in the queue panel. Both devices must be on the same Wi-Fi.')}
            </p>
          </div>
        </div>

        <button
          type="button"
          class="flex items-center justify-center gap-2 rounded-full bg-white px-6 py-3 text-[15px] font-semibold text-zinc-950 active:scale-[0.98] disabled:opacity-60"
          disabled={joining}
          onclick={() => void jam.scanJoin()}
        >
          <Icon name="qr" class="size-5" />
          {t('Scan the QR code')}
        </button>

        <div class="flex items-center gap-3 text-xs text-zinc-500">
          <span class="h-px flex-1 bg-zinc-800"></span>
          {t('or enter the code')}
          <span class="h-px flex-1 bg-zinc-800"></span>
        </div>

        <label class="flex flex-col gap-1.5">
          <span class="text-xs font-medium text-zinc-400">{t('Jam code')}</span>
          <input
            class="{input} text-center text-2xl font-bold tracking-[0.4em] tabular-nums"
            type="text"
            inputmode="numeric"
            autocomplete="one-time-code"
            pattern="[0-9]*"
            maxlength="7"
            placeholder="000000"
            bind:this={codeInput}
            value={code}
            oninput={(e) => {
              code = normalizePairCode(e.currentTarget.value)
              e.currentTarget.value = code
            }}
          />
        </label>

        <div class="flex flex-col gap-2" aria-live="polite">
          <div class="flex items-center justify-between gap-2">
            <p class="text-xs font-medium text-zinc-400">{t('Computers on this Wi-Fi')}</p>
            <button
              type="button"
              class="rounded-full px-3 py-1.5 text-xs text-zinc-400 active:bg-white/10 disabled:opacity-50"
              disabled={sync.searching}
              onclick={() => void sync.discover()}
            >
              {sync.searching ? t('Searching…') : t('Search again')}
            </button>
          </div>
          {#if view === 'found'}
            <ul class="flex flex-col gap-1.5">
              {#each sync.found as f (f.deviceId)}
                <li>
                  <button
                    type="button"
                    class={[
                      'flex w-full items-center gap-3 rounded-xl border px-3 py-2.5 text-left active:bg-white/5',
                      address === f.address ? 'border-accent-500 bg-accent-500/10' : 'border-zinc-800 bg-zinc-900',
                    ]}
                    aria-pressed={address === f.address}
                    onclick={() => pickFound(f)}
                  >
                    <Icon name="computer" class="size-4 shrink-0 text-zinc-400" />
                    <span class="min-w-0 flex-1 truncate text-sm font-medium">{f.name}</span>
                    <span class="shrink-0 text-xs text-zinc-500">{f.address}</span>
                  </button>
                </li>
              {/each}
            </ul>
          {:else if view === 'none'}
            <p class="text-xs text-zinc-500">{t('No computer found. Scan the QR code or enter the address below.')}</p>
          {/if}
        </div>

        <label class="flex flex-col gap-1.5">
          <span class="text-xs font-medium text-zinc-400">{t('Computer address (optional)')}</span>
          <input
            class={input}
            type="text"
            inputmode="decimal"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            placeholder="192.168.1.20"
            aria-invalid={addressBad}
            bind:value={address}
            onblur={() => (addressTouched = true)}
          />
        </label>
        {#if addressBad}
          <p class="text-xs text-red-300" role="alert">
            {!addressCheck.ok && addressCheck.reason === 'notLan'
              ? t('Use the computer’s local network address (it usually starts with 192.168. or 10.).')
              : t('Enter the address shown on the computer, e.g. 192.168.1.20.')}
          </p>
        {/if}
        {#if joinError}
          <p class="rounded-lg bg-red-950/80 px-3 py-2 text-sm text-red-200" role="alert">{joinError}</p>
        {/if}

        <button
          type="submit"
          class="rounded-full bg-accent-500 px-6 py-3 text-[15px] font-semibold text-zinc-950 active:scale-[0.98] disabled:opacity-50"
          disabled={!canJoin}
        >
          {joining ? t('Joining…') : t('Join')}
        </button>
      </form>
    {:else}
      <!-- Now playing -->
      <section class="px-5 pt-2" aria-label={t('Now playing')}>
        <div class="flex items-center gap-4 rounded-2xl bg-white/[0.07] p-4">
          <span class="flex size-14 shrink-0 items-center justify-center rounded-lg bg-gradient-to-br from-accent-600 to-accent-300 text-zinc-950">
            {#if jamState?.playing && jamState.nowPlaying}
              <Equalizer class="text-zinc-950" />
            {:else}
              <Icon name="music" class="size-7" />
            {/if}
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-[11px] font-semibold tracking-widest text-accent-300 uppercase">
              {jamState?.playing ? t('Now playing') : t('Paused')}
            </p>
            {#if jamState?.nowPlaying}
              <p class="truncate text-[17px] leading-snug font-bold">{jamState.nowPlaying.title}</p>
              <p class="truncate text-sm text-white/70">{jamState.nowPlaying.artist || t('Unknown artist')}</p>
            {:else}
              <p class="text-[17px] leading-snug font-bold text-white/60">
                {jamState ? t('Nothing is playing') : t('Loading…')}
              </p>
            {/if}
          </div>
        </div>
      </section>

      <!-- Search the host's library -->
      <div class="sticky top-0 z-10 bg-zinc-950/95 px-5 pt-4 pb-3 backdrop-blur">
        <label class="relative block">
          <span class="sr-only">{t('Search {device}’s library', { device: hostName })}</span>
          <Icon name="search" class="pointer-events-none absolute top-1/2 left-3.5 size-5 -translate-y-1/2 text-zinc-400" />
          <input
            type="search"
            class="w-full rounded-full bg-white px-11 py-3 text-[15px] font-medium text-zinc-950 outline-none placeholder:text-zinc-500 focus:ring-2 focus:ring-accent-500"
            placeholder={t('Search songs to add')}
            maxlength={JAM_QUERY_MAX}
            autocomplete="off"
            enterkeyhint="search"
            value={jam.query}
            oninput={(e) => jam.setQuery(e.currentTarget.value)}
          />
          {#if jam.query}
            <button
              type="button"
              class="absolute top-1/2 right-2 -translate-y-1/2 rounded-full p-1.5 text-zinc-500 active:bg-zinc-200"
              aria-label={t('Clear search')}
              onclick={() => jam.setQuery('')}
            >
              <Icon name="close" class="size-4" />
            </button>
          {/if}
        </label>
      </div>

      {#if searchingNow}
        <section class="px-2" style:padding-bottom="calc(var(--inset-bottom) + 88px)" aria-label={t('Search results')} aria-busy={jam.searching}>
          {#if searchError}
            <p class="px-4 py-2 text-sm text-red-300" role="alert">{searchError}</p>
          {:else if jam.results.length === 0}
            <p class="px-4 py-6 text-center text-sm text-zinc-500" role="status">
              {jam.searching ? t('Searching…') : t('No songs found.')}
            </p>
          {:else}
            <ul>
              {#each jam.results as r (r.trackId)}
                {@const busy = jam.adding.has(r.trackId)}
                {@const done = jam.added.has(r.trackId)}
                <li class="flex h-16 items-center gap-3 rounded-lg px-3">
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-[15px]">{r.title}</span>
                    <span class="block truncate text-[13px] text-zinc-400">
                      {r.artist || t('Unknown artist')}{#if r.album}<span class="opacity-60">{' · '}</span>{r.album}{/if}
                    </span>
                  </span>
                  <span class="shrink-0 text-xs tabular-nums text-zinc-500">{formatDurationMs(r.durationMs)}</span>
                  <button
                    type="button"
                    class={[
                      'flex h-8 shrink-0 items-center gap-1 rounded-full px-3 text-[13px] font-semibold active:scale-95 disabled:opacity-50',
                      done ? 'bg-accent-500/20 text-accent-300' : 'border border-zinc-600 text-white',
                    ]}
                    disabled={busy}
                    aria-label={t('Add {title} to the queue', { title: r.title })}
                    onclick={() => void add(r.trackId)}
                  >
                    <Icon name={done ? 'check' : 'plus'} class="size-4" />
                    {done ? t('Added') : t('Add')}
                  </button>
                </li>
              {/each}
            </ul>
            {#if jam.hasMore}
              <div class="flex justify-center py-3">
                <button
                  type="button"
                  class="rounded-full bg-zinc-800 px-4 py-2 text-sm font-semibold active:bg-zinc-700 disabled:opacity-50"
                  disabled={jam.searching}
                  onclick={jam.loadMore}
                >
                  {jam.searching ? t('Loading…') : t('Show more')}
                </button>
              </div>
            {/if}
          {/if}
        </section>
      {:else}
        <section class="px-2" style:padding-bottom="calc(var(--inset-bottom) + 88px)" aria-labelledby="jam-next">
          <h3 id="jam-next" class="px-4 pt-1 pb-2 text-base font-bold">{t('Up next')}</h3>
          {#if !jamState || jamState.upNext.length === 0}
            <p class="px-4 py-2 text-sm text-zinc-500">
              {t('Nothing else in the queue. Search above to add a song.')}
            </p>
          {:else}
            <ol>
              {#each jamState.upNext as entry, i (i)}
                <li class="flex h-16 items-center gap-3 rounded-lg px-3">
                  <span class="w-6 shrink-0 text-right text-xs tabular-nums text-zinc-500">{i + 1}</span>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-[15px]">{entry.title}</span>
                    <span class="block truncate text-[13px] text-zinc-400">
                      {entry.artist || t('Unknown artist')}{#if entry.addedBy}<span class="opacity-60">{' · '}</span><span class="text-accent-300">{t('added by {name}', { name: shortName(entry.addedBy) })}</span>{/if}
                    </span>
                  </span>
                  <span class="shrink-0 text-xs tabular-nums text-zinc-500">{formatDurationMs(entry.durationMs)}</span>
                </li>
              {/each}
            </ol>
          {/if}
        </section>
      {/if}

      {#if leaveError}
        <p class="px-5 text-xs text-red-300" role="alert">{leaveError}</p>
      {/if}
    {/if}
  </div>

  {#if notice}
    <div
      class="pointer-events-none absolute inset-x-4 z-20 flex justify-center"
      style:bottom="calc(var(--inset-bottom) + 20px)"
      transition:fly={{ y: 12, duration: motionDuration(180) }}
    >
      <p
        role={notice.error ? 'alert' : 'status'}
        class={[
          'rounded-lg px-3.5 py-2.5 text-sm shadow-lg',
          notice.error ? 'bg-red-950 text-red-100' : 'bg-zinc-100 text-zinc-900',
        ]}
      >
        {notice.text}
      </p>
    </div>
  {/if}
</div>

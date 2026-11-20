<script lang="ts">
  import Icon from './Icon.svelte'
  import ToggleSwitch from './ToggleSwitch.svelte'
  import SyncGuardNotice from './SyncGuardNotice.svelte'
  import PairQr from './PairQr.svelte'
  import { addedAgo } from './dates'
  import { i18n, t } from './i18n.svelte'
  import { sync, type PeerStatus, type SyncAction } from './sync.svelte'
  import {
    addressWithPort,
    checkAddress,
    formatCountdown,
    formatPairCode,
    normalizePairCode,
    pairErrorKind,
    PAIR_CODE_DIGITS,
  } from './syncLogic'

  // Settings › Phone (on the computer) or › Computer (on the phone): the
  // pairing, paired devices and sync state (docs/SYNC.md, "UI").
  let { cardClass, actionBtn }: { cardClass: string; actionBtn: string } = $props()

  const status = $derived(sync.status)
  const desktop = $derived(status?.role === 'desktop')

  // One clock for "x minutes ago" and the code countdown.
  let now = $state(Date.now())
  let nowPerf = $state(performance.now())
  $effect(() => {
    const id = setInterval(() => {
      now = Date.now()
      nowPerf = performance.now()
    }, 1000)
    return () => clearInterval(id)
  })

  function ago(ms: number | null): string {
    if (ms === null) return t('Never synced')
    if (now - ms < 60_000) return t('Synced just now')
    return t('Synced {when}', { when: addedAgo(ms / 1000, i18n.locale, now / 1000) })
  }

  /** The backend's English message, explained where we know the case. */
  function explain(message: string): string {
    switch (pairErrorKind(message)) {
      case 'wrongCode':
        return t('Wrong code. Check the code on the computer and try again.')
      case 'tooManyAttempts':
        return t('Too many wrong codes. Ask the computer for a new code.')
      case 'expired':
        return t('The code has expired. Ask the computer for a new code.')
      case 'notOpen':
        return t('The computer is not showing a code. Choose “Pair a phone” on the computer first.')
      case 'busy':
        return t('Another device is pairing right now. Try again in a moment.')
      case 'unreachable':
        return t('Cannot reach the computer. Check the address and that both devices are on the same Wi-Fi.')
      case 'version':
        return t('The apps do not match. Update NeoModern on both devices.')
      case 'address':
        return t('Enter the computer’s local address, e.g. 192.168.1.20.')
      case 'notPairingQr':
        return t('This is not a NeoModern pairing code. Scan the code shown in Settings › Phone on the computer.')
      case 'qrNoAddress':
        return t('The code has no address. Connect the computer to Wi-Fi or a network cable and show a new code.')
      case 'camera':
        return t('NeoModern needs the camera to scan the code. Allow it in the phone’s settings, or enter the code by hand.')
      default:
        return message
    }
  }

  const errorFor = (action: SyncAction, peerId?: string): string | null =>
    sync.error && sync.error.action === action && (peerId === undefined || sync.error.peerId === peerId)
      ? sync.error.message
      : null

  // Device name ----------------------------------------------------------------
  let nameDraft = $state<string | null>(null)
  const nameShown = $derived(nameDraft ?? status?.deviceName ?? '')
  async function saveName() {
    if (nameDraft === null) return
    const next = nameDraft.trim()
    if (next === '' || next === status?.deviceName) {
      nameDraft = null
      return
    }
    if (await sync.setDeviceName(next)) nameDraft = null
  }

  // Desktop: pairing -------------------------------------------------------------
  const pairState = $derived.by(() => {
    if (!status || !desktop) return 'closed'
    const s = status.pairing.state
    if (s === 'open' && sync.pairDeadline - nowPerf <= 0) return 'expired'
    if (s === 'closed' && sync.pairing) return 'expired'
    return s
  })
  const pairCode = $derived(status?.pairing.code ?? sync.pairing?.code ?? null)
  const pairAddresses = $derived.by(() => {
    const port = sync.pairing?.port ?? status?.listening?.port ?? null
    const ips = sync.pairing?.addresses.length ? sync.pairing.addresses : (status?.listening?.addresses ?? [])
    return port === null ? [] : ips.map((ip) => addressWithPort(ip, port))
  })
  const pairShown = $derived(sync.pairing !== null || pairState === 'open' || pairState === 'tooManyAttempts')

  let confirmRemove = $state<string | null>(null)

  // Phone: connect ------------------------------------------------------------------
  let address = $state('')
  let code = $state('')
  let addressTouched = $state(false)
  const addressCheck = $derived(checkAddress(address))
  const addressHint = $derived.by(() => {
    if (!addressTouched || addressCheck.ok) return null
    if (addressCheck.reason === 'empty') return null
    return addressCheck.reason === 'notLan'
      ? t('Use the computer’s local network address (it usually starts with 192.168. or 10.).')
      : t('Enter the address shown on the computer, e.g. 192.168.1.20.')
  })
  const canConnect = $derived(addressCheck.ok && code.length === PAIR_CODE_DIGITS && sync.busy !== 'connect')

  async function connect(e: SubmitEvent) {
    e.preventDefault()
    addressTouched = true
    if (!addressCheck.ok || code.length !== PAIR_CODE_DIGITS) return
    if (await sync.connectPair(addressCheck.address, code)) {
      code = ''
      address = ''
      addressTouched = false
    }
  }

  let confirmForget = $state(false)

  const computer = $derived(sync.computer)
  const computerState = $derived.by(() => {
    if (!computer) return null
    if (computer.syncing) return { label: t('Syncing…'), tone: 'accent' as const }
    if (computer.connected) return { label: t('Connected'), tone: 'ok' as const }
    return { label: t('Connecting…'), tone: 'wait' as const }
  })

  const label = 'text-sm font-medium'
  const help = 'mt-0.5 text-xs text-zinc-500 dark:text-zinc-400'
  const errorText = 'text-xs text-red-600 dark:text-red-400'
  const input =
    'w-full rounded-xl border border-zinc-200 bg-white px-3 py-2 text-sm outline-none transition placeholder:text-zinc-400 focus:border-accent-500 focus:ring-2 focus:ring-accent-500/30 dark:border-zinc-700 dark:bg-zinc-950/60 dark:placeholder:text-zinc-600'
  const primaryBtn =
    'shrink-0 rounded-full bg-accent-600 px-4 py-1.5 text-xs font-semibold text-white transition hover:bg-accent-500 disabled:opacity-50 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400'
  const quietBtn =
    'rounded-full px-3 py-1.5 text-xs text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-zinc-100'
  const dangerBtn =
    'rounded-full px-3 py-1.5 text-xs font-medium text-red-600 hover:bg-red-50 disabled:opacity-50 dark:text-red-400 dark:hover:bg-red-950/40'

  function lastResultText(p: PeerStatus): string | null {
    const r = p.lastResult
    if (!r || r.error) return null
    return t('{sent} sent · {received} received · {changed} changed here', {
      sent: r.sent.toLocaleString(i18n.locale),
      received: r.received.toLocaleString(i18n.locale),
      changed: r.changed.toLocaleString(i18n.locale),
    })
  }
</script>

{#snippet nameRow(title: string, hint: string)}
  <div class="flex flex-col gap-2 p-4 sm:flex-row sm:items-center sm:justify-between sm:gap-6">
    <div class="min-w-0">
      <label for="sync-name" class={label}>{title}</label>
      <p class={help}>{hint}</p>
    </div>
    <form
      class="flex shrink-0 items-center gap-2 sm:w-64"
      onsubmit={(e) => {
        e.preventDefault()
        void saveName()
      }}
    >
      <input
        id="sync-name"
        class={input}
        maxlength="64"
        autocomplete="off"
        value={nameShown}
        oninput={(e) => (nameDraft = e.currentTarget.value)}
        onblur={() => void saveName()}
      />
    </form>
  </div>
  {#if errorFor('name')}
    <p class="px-4 py-2.5 {errorText}" role="alert">{errorFor('name')}</p>
  {/if}
{/snippet}

{#snippet stateDot(connected: boolean)}
  <span
    class={['size-2 shrink-0 rounded-full', connected ? 'bg-emerald-500' : 'bg-zinc-300 dark:bg-zinc-600']}
    aria-hidden="true"
  ></span>
{/snippet}

{#if !status}
  <div class={cardClass}>
    <p class="p-4 text-xs {errorFor('load') ? 'text-red-600 dark:text-red-400' : 'text-zinc-500'}" role="status">
      {errorFor('load') ?? t('Loading…')}
    </p>
  </div>
{:else if desktop}
  <div class={cardClass}>
    <div class="flex items-start justify-between gap-6 p-4">
      <div class="min-w-0">
        <p id="phones-label" class={label}>{t('Allow phone connections')}</p>
        <p id="phones-help" class={help}>
          {t('Your phone can sync favorites and playlists with this computer and control what it plays. Same Wi-Fi only; off by default. Windows may ask whether NeoModern may use the network.')}
        </p>
        {#if status.allowPhoneConnections && status.listening}
          <p class="mt-1.5 inline-flex items-center gap-1.5 rounded-full bg-emerald-500/15 px-2.5 py-0.5 text-xs text-emerald-700 dark:text-emerald-300" role="status">
            <span class="size-1.5 rounded-full bg-emerald-500"></span>
            {t('Waiting for phones on port {port}', { port: status.listening.port })}
          </p>
        {/if}
        {#if errorFor('allow')}
          <p class="mt-1.5 {errorText}" role="alert">{errorFor('allow')}</p>
        {/if}
      </div>
      <ToggleSwitch
        ariaLabelledby="phones-label"
        ariaDescribedby="phones-help"
        checked={status.allowPhoneConnections}
        disabled={sync.busy === 'allow'}
        onchange={(next) => void sync.setAllowPhones(next)}
      />
    </div>

    {#if status.allowPhoneConnections}
      <div class="flex flex-col gap-3 p-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0 flex-1">
            <p class={label}>{t('Pair a phone')}</p>
            <p class={help}>{t('Shows a code to type into NeoModern on your phone (Settings › Computer).')}</p>
          </div>
          {#if !pairShown}
            <button type="button" class={primaryBtn} disabled={sync.busy === 'pair'} onclick={() => void sync.pairOpen()}>
              {t('Pair a phone')}
            </button>
          {/if}
        </div>

        {#if pairShown}
          <div class="rounded-xl border border-zinc-200/80 bg-zinc-50 p-4 dark:border-zinc-800 dark:bg-zinc-950/50" aria-live="polite">
            {#if pairState === 'open' && pairCode}
              <div class="flex flex-col items-center gap-3 text-center">
                {#if sync.pairing?.qr}
                  <p class="text-xs text-zinc-500 dark:text-zinc-400">{t('On your phone, scan this code')}</p>
                  <PairQr qr={sync.pairing.qr} label={t('Pairing QR code')} />
                  <p class="text-xs text-zinc-500 dark:text-zinc-400">{t('or enter this code')}</p>
                {:else}
                  <p class="text-xs text-zinc-500 dark:text-zinc-400">{t('On your phone, enter this code')}</p>
                {/if}
                <p class="text-4xl font-bold tracking-[0.12em] text-zinc-900 tabular-nums dark:text-zinc-50" aria-label={pairCode.split('').join(' ')}>
                  {formatPairCode(pairCode)}
                </p>
                {#if pairAddresses.length > 0}
                  <div class="flex flex-col items-center gap-1.5">
                    <p class="text-xs text-zinc-500 dark:text-zinc-400">
                      {pairAddresses.length === 1 ? t('and this address') : t('and one of these addresses')}
                    </p>
                    <div class="flex flex-wrap justify-center gap-1.5">
                      {#each pairAddresses as a (a)}
                        <code class="rounded-lg bg-white px-2.5 py-1 font-sans text-sm font-semibold tabular-nums select-all shadow-xs dark:bg-zinc-800">{a}</code>
                      {/each}
                    </div>
                  </div>
                {:else}
                  <p class="text-xs text-amber-700 dark:text-amber-300">
                    {t('No local network found. Connect this computer to Wi-Fi or a network cable.')}
                  </p>
                {/if}
                <div class="flex items-center gap-3">
                  <span class="text-xs tabular-nums text-zinc-500 dark:text-zinc-400" role="timer">
                    {t('Expires in {time}', { time: formatCountdown((sync.pairDeadline - nowPerf) / 1000) })}
                  </span>
                  <button type="button" class={actionBtn} onclick={() => void sync.pairClose()}>{t('Cancel')}</button>
                </div>
              </div>
            {:else}
              <div class="flex flex-wrap items-center justify-between gap-3">
                <p class="text-sm" role="status">
                  {pairState === 'tooManyAttempts'
                    ? t('Too many wrong codes were typed, so this code no longer works.')
                    : t('The code has expired.')}
                </p>
                <div class="flex items-center gap-2">
                  <button type="button" class={quietBtn} onclick={() => void sync.pairClose()}>{t('Close')}</button>
                  <button type="button" class={primaryBtn} disabled={sync.busy === 'pair'} onclick={() => void sync.pairOpen()}>
                    {t('New code')}
                  </button>
                </div>
              </div>
            {/if}
          </div>
        {/if}
        {#if errorFor('pair')}
          <p class={errorText} role="alert">{errorFor('pair')}</p>
        {/if}
      </div>
    {/if}

    <div class="flex flex-col gap-2 p-4">
      <p class={label}>{t('Paired phones')}</p>
      {#if sync.phones.length === 0}
        <p class={help}>{t('No phones paired yet.')}</p>
      {:else}
        <ul class="flex flex-col gap-2">
          {#each sync.phones as phone (phone.id)}
            <li class="flex flex-col gap-2.5 rounded-xl border border-zinc-200/80 p-3 dark:border-zinc-800">
              <div class="flex items-center gap-3">
                <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                  <Icon name="phone" class="size-4.5" />
                </span>
                <div class="min-w-0 flex-1">
                  <p class="flex items-center gap-2 text-sm font-medium">
                    <span class="truncate">{phone.name}</span>
                    {@render stateDot(phone.connected)}
                    <span class="sr-only">{phone.connected ? t('Connected') : t('Not connected')}</span>
                    {#if phone.syncing}
                      <span class="text-xs font-normal text-accent-600 dark:text-accent-400">{t('Syncing…')}</span>
                    {/if}
                  </p>
                  <p class="truncate text-xs text-zinc-500 dark:text-zinc-400">
                    {ago(phone.lastSyncAt)}{lastResultText(phone) ? ` · ${lastResultText(phone)}` : ''}
                  </p>
                </div>
                {#if confirmRemove === phone.id}
                  <div class="flex shrink-0 items-center gap-1">
                    <button
                      type="button"
                      class="rounded-full bg-red-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-red-500 disabled:opacity-50"
                      disabled={sync.busy === 'remove'}
                      onclick={() => void sync.removePeer(phone.id).then(() => (confirmRemove = null))}
                    >
                      {t('Remove')}
                    </button>
                    <button type="button" class={quietBtn} onclick={() => (confirmRemove = null)}>{t('Cancel')}</button>
                  </div>
                {:else}
                  <button type="button" class={dangerBtn} onclick={() => (confirmRemove = phone.id)}>{t('Remove')}</button>
                {/if}
              </div>
              {#if confirmRemove === phone.id}
                <p class="text-xs text-zinc-500 dark:text-zinc-400" role="alert">
                  {t('Remove {device}? It can no longer sync or control this computer until you pair it again.', { device: phone.name })}
                </p>
              {/if}
              {#if phone.lastError}
                <p class={errorText}>{phone.lastError}</p>
              {/if}
              {#if errorFor('remove', phone.id)}
                <p class={errorText} role="alert">{errorFor('remove', phone.id)}</p>
              {/if}
              {#if phone.pendingGuard}
                <SyncGuardNotice peer={phone} guard={phone.pendingGuard} />
              {/if}
              {#if errorFor('guard', phone.id)}
                <p class={errorText} role="alert">{errorFor('guard', phone.id)}</p>
              {/if}
            </li>
          {/each}
        </ul>
      {/if}
    </div>

    {@render nameRow(t('Computer name'), t('Your phone shows this name.'))}
  </div>
{:else}
  <div class={cardClass}>
    {#if !computer}
      <form class="flex flex-col gap-3 p-4" onsubmit={connect} novalidate>
        <div class="min-w-0">
          <p class={label}>{t('Connect to a computer')}</p>
          <p class={help}>
            {t('On the computer, open Settings › Phone, turn on “Allow phone connections” and choose “Pair a phone”. Both devices must be on the same Wi-Fi.')}
          </p>
        </div>
        <button
          type="button"
          class={[primaryBtn, 'flex items-center justify-center gap-2 py-2.5 text-sm']}
          disabled={sync.busy === 'connect'}
          onclick={() => void sync.scanPair()}
        >
          <Icon name="qr" class="size-5" />
          {t('Scan the QR code')}
        </button>
        <p class="text-center text-xs text-zinc-500 dark:text-zinc-400">{t('or enter the address and code')}</p>
        <div class="grid gap-3 sm:grid-cols-[1fr_10rem]">
          <label class="flex flex-col gap-1">
            <span class="text-xs font-medium text-zinc-600 dark:text-zinc-300">{t('Computer address')}</span>
            <input
              class={input}
              type="text"
              inputmode="decimal"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              placeholder="192.168.1.20"
              aria-invalid={addressHint !== null}
              bind:value={address}
              onblur={() => (addressTouched = true)}
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-xs font-medium text-zinc-600 dark:text-zinc-300">{t('Code')}</span>
            <input
              class="{input} tracking-[0.3em] tabular-nums"
              type="text"
              inputmode="numeric"
              autocomplete="one-time-code"
              pattern="[0-9]*"
              maxlength="7"
              placeholder="000000"
              value={code}
              oninput={(e) => {
                code = normalizePairCode(e.currentTarget.value)
                e.currentTarget.value = code
              }}
            />
          </label>
        </div>
        {#if addressHint}
          <p class={errorText} role="alert">{addressHint}</p>
        {/if}
        {#if errorFor('connect')}
          <p class={errorText} role="alert">{explain(errorFor('connect') ?? '')}</p>
        {/if}
        <div class="flex justify-end">
          <button type="submit" class={primaryBtn} disabled={!canConnect}>
            {sync.busy === 'connect' ? t('Connecting…') : t('Connect')}
          </button>
        </div>
      </form>
    {:else}
      <div class="flex flex-col gap-3 p-4">
        <div class="flex items-center gap-3">
          <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
            <Icon name="computer" class="size-5" />
          </span>
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-medium">{computer.name}</p>
            {#if computerState}
              <p
                class={[
                  'flex items-center gap-1.5 text-xs',
                  computerState.tone === 'ok' && 'text-emerald-600 dark:text-emerald-400',
                  computerState.tone === 'accent' && 'text-accent-600 dark:text-accent-400',
                  computerState.tone === 'wait' && 'text-amber-600 dark:text-amber-400',
                ]}
                role="status"
              >
                {@render stateDot(computer.connected)}
                {computerState.label}
                {#if computer.address}<span class="text-zinc-400">{` · ${computer.address}`}</span>{/if}
              </p>
            {/if}
          </div>
        </div>
        <p class="text-xs text-zinc-500 dark:text-zinc-400">
          {ago(computer.lastSyncAt)}{lastResultText(computer) ? ` · ${lastResultText(computer)}` : ''}
        </p>
        {#if computer.lastError}
          <p class={errorText}>{computer.lastError}</p>
        {/if}
        {#if computer.pendingGuard}
          <SyncGuardNotice peer={computer} guard={computer.pendingGuard} />
        {/if}
        {#if errorFor('guard', computer.id)}
          <p class={errorText} role="alert">{errorFor('guard', computer.id)}</p>
        {/if}
        <div class="flex flex-wrap items-center gap-2">
          <button type="button" class={primaryBtn} onclick={() => sync.openRemote()}>
            {t('Remote control')}
          </button>
          <button
            type="button"
            class={actionBtn}
            disabled={sync.busy === 'syncNow' || computer.syncing}
            onclick={() => void sync.syncNow()}
          >
            {computer.syncing ? t('Syncing…') : t('Sync now')}
          </button>
          {#if confirmForget}
            <button
              type="button"
              class="rounded-full bg-red-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-red-500 disabled:opacity-50"
              disabled={sync.busy === 'forget'}
              onclick={() => void sync.forget().then(() => (confirmForget = false))}
            >
              {t('Forget')}
            </button>
            <button type="button" class={quietBtn} onclick={() => (confirmForget = false)}>{t('Cancel')}</button>
          {:else}
            <button type="button" class={dangerBtn} onclick={() => (confirmForget = true)}>
              {t('Forget this computer')}
            </button>
          {/if}
        </div>
        {#if confirmForget}
          <p class="text-xs text-zinc-500 dark:text-zinc-400" role="alert">
            {t('Forget {device}? Your music stays on both devices; to sync again you pair with a new code.', { device: computer.name })}
          </p>
        {/if}
        {#if errorFor('syncNow')}
          <p class={errorText} role="alert">{errorFor('syncNow')}</p>
        {/if}
        {#if errorFor('forget')}
          <p class={errorText} role="alert">{errorFor('forget')}</p>
        {/if}
      </div>
    {/if}

    {@render nameRow(t('Phone name'), t('The computer shows this name.'))}
  </div>
{/if}

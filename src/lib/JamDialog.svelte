<script lang="ts">
  import { fade, scale } from 'svelte/transition'
  import Icon from './Icon.svelte'
  import PairQr from './PairQr.svelte'
  import { count, t } from './i18n.svelte'
  import { jam, type JamAction } from './jam.svelte'
  import { shortName } from './jamLogic'
  import { motionDuration } from './motion'
  import { portal } from './portal'
  import { formatPairCode } from './syncLogic'

  // The host's Jam (docs/JAM.md, "Flow"): the code and QR code guests join
  // with, who joined, what they added, a new code and "End Jam". Everything
  // comes from `jam.status` (Rust); the buttons only send commands.
  const MAX_GUESTS = 8

  const status = $derived(jam.status)
  const running = $derived(status?.running === true)
  const code = $derived(status?.code ?? null)

  let confirmEnd = $state(false)

  const errorFor = (action: JamAction, id?: string): string | null =>
    jam.error && jam.error.action === action && (id === undefined || jam.error.id === id) ? jam.error.message : null
  const startError = $derived(errorFor('start'))

  const close = () => (jam.dialogOpen = false)

  const primaryBtn =
    'rounded-full bg-accent-600 px-4 py-1.5 text-xs font-semibold text-white transition hover:bg-accent-500 disabled:opacity-50 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400'
  const actionBtn =
    'rounded-full border border-zinc-200 bg-white px-3.5 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800/80 dark:text-zinc-200 dark:hover:bg-zinc-700'
  const quietBtn =
    'rounded-full px-3 py-1.5 text-xs text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-zinc-100'
  const sectionTitle = 'text-xs font-semibold uppercase tracking-wider text-zinc-400'
  const errorText = 'text-xs text-red-600 dark:text-red-400'
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (confirmEnd ? (confirmEnd = false) : close())} />

<div
  use:portal
  transition:fade={{ duration: motionDuration(150) }}
  class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 backdrop-blur-xs"
  role="dialog"
  aria-modal="true"
  aria-labelledby="jam-title"
>
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="absolute inset-0" onclick={close}></div>
  <div
    transition:scale={{ start: 0.96, duration: motionDuration(180) }}
    class="relative flex max-h-full w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-zinc-200 bg-white shadow-2xl dark:border-zinc-800 dark:bg-zinc-900"
  >
    <header class="flex items-center gap-3 border-b border-zinc-200/80 px-5 py-3.5 dark:border-zinc-800">
      <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-500/15 text-accent-600 dark:text-accent-400">
        <Icon name="jam" class="size-5" />
      </span>
      <div class="min-w-0 flex-1">
        <h3 id="jam-title" class="flex items-center gap-2 text-base font-semibold">
          {t('Jam')}
          <span class="rounded-full bg-amber-500/15 px-2 py-0.5 text-[11px] font-semibold text-amber-700 dark:text-amber-400">
            {t('Experimental')}
          </span>
        </h3>
        <p class="truncate text-xs text-zinc-500 dark:text-zinc-400">
          {t('Friends on the same Wi-Fi add songs to your queue from their phones.')}
        </p>
      </div>
      <button
        type="button"
        class="rounded-lg p-1.5 text-zinc-400 hover:bg-zinc-100 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200"
        aria-label={t('Close')}
        onclick={close}
      >
        <Icon name="close" class="size-4" />
      </button>
    </header>

    {#if !running}
      <div class="flex flex-col items-center gap-3 px-6 py-12 text-center" aria-live="polite">
        {#if startError}
          <p class={errorText} role="alert">{startError}</p>
          <button type="button" class={primaryBtn} disabled={jam.busy === 'start'} onclick={() => void jam.start()}>
            {t('Try again')}
          </button>
        {:else}
          <p class="text-sm text-zinc-500 dark:text-zinc-400" role="status">{t('Starting the Jam…')}</p>
        {/if}
      </div>
    {:else}
      <div class="grid min-h-0 flex-1 overflow-y-auto sm:grid-cols-[17rem_1fr]">
        <!-- How to join -->
        <section
          class="flex flex-col items-center gap-3 border-zinc-200/80 bg-zinc-50 px-5 py-5 text-center sm:border-r dark:border-zinc-800 dark:bg-zinc-950/40"
          aria-labelledby="jam-join"
          aria-live="polite"
        >
          <h4 id="jam-join" class="text-xs text-zinc-500 dark:text-zinc-400">
            {status?.qr
              ? t('On the phone: Join a Jam, then scan this code')
              : t('On the phone: Join a Jam, then enter this code')}
          </h4>
          {#if status?.qr}
            <PairQr qr={status.qr} label={t('Jam QR code')} />
            <p class="text-xs text-zinc-500 dark:text-zinc-400">{t('or enter this code')}</p>
          {/if}
          {#if code}
            <p
              class="text-4xl font-bold tracking-[0.12em] text-zinc-900 tabular-nums dark:text-zinc-50"
              aria-label={code.split('').join(' ')}
            >
              {formatPairCode(code)}
            </p>
          {/if}
          {#if status && status.addresses.length > 0}
            <div class="flex flex-col items-center gap-1.5">
              <p class="text-xs text-zinc-500 dark:text-zinc-400">
                {status.addresses.length === 1 ? t('and this address') : t('and one of these addresses')}
              </p>
              <div class="flex flex-wrap justify-center gap-1.5">
                {#each status.addresses as a (a)}
                  <code class="rounded-lg bg-white px-2.5 py-1 font-sans text-sm font-semibold tabular-nums select-all shadow-xs dark:bg-zinc-800">{a}</code>
                {/each}
              </div>
            </div>
          {:else}
            <p class="text-xs text-amber-700 dark:text-amber-300">
              {t('No local network found. Connect this computer to Wi-Fi or a network cable.')}
            </p>
          {/if}
          <button type="button" class={actionBtn} disabled={jam.busy === 'newCode'} onclick={() => void jam.newCode()}>
            <span class="flex items-center gap-1.5"><Icon name="refresh" class="size-3.5" />{t('New code')}</span>
          </button>
          <p class="text-[11px] text-zinc-400">{t('A new code keeps the guests who already joined.')}</p>
          {#if errorFor('newCode')}
            <p class={errorText} role="alert">{errorFor('newCode')}</p>
          {/if}
        </section>

        <div class="flex min-w-0 flex-col gap-5 px-5 py-5">
          <!-- Guests -->
          <section class="flex flex-col gap-2" aria-labelledby="jam-guests">
            <h4 id="jam-guests" class="flex items-center justify-between {sectionTitle}">
              {t('Guests')}
              <span class="font-medium tabular-nums normal-case tracking-normal">
                {(status?.guests.length ?? 0)}/{MAX_GUESTS}
              </span>
            </h4>
            {#if !status || status.guests.length === 0}
              <p class="rounded-xl border border-dashed border-zinc-200 px-3 py-4 text-center text-xs text-zinc-500 dark:border-zinc-700 dark:text-zinc-400">
                {t('Nobody has joined yet.')}
              </p>
            {:else}
              <ul class="flex flex-col gap-1">
                {#each status.guests as g (g.id)}
                  <li class="flex items-center gap-3 rounded-xl px-2 py-1.5 hover:bg-zinc-50 dark:hover:bg-zinc-800/50">
                    <span class="relative flex size-8 shrink-0 items-center justify-center rounded-full bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                      <Icon name="phone" class="size-4" />
                      {#if g.connected !== undefined}
                        <span
                          class={[
                            'absolute -right-0.5 -bottom-0.5 size-2.5 rounded-full ring-2 ring-white dark:ring-zinc-900',
                            g.connected ? 'bg-emerald-500' : 'bg-zinc-400 dark:bg-zinc-600',
                          ]}
                          title={g.connected ? t('Connected') : t('Not connected')}
                        ></span>
                      {/if}
                    </span>
                    <div class="min-w-0 flex-1">
                      <p class="truncate text-sm font-medium" title={g.name}>{shortName(g.name)}</p>
                      <p class="text-xs text-zinc-500 dark:text-zinc-400">
                        {count(g.added, '{n} song added', '{n} songs added')}
                      </p>
                      {#if errorFor('remove', g.id)}
                        <p class={errorText} role="alert">{errorFor('remove', g.id)}</p>
                      {/if}
                    </div>
                    <button
                      type="button"
                      class="shrink-0 rounded-full px-3 py-1.5 text-xs font-medium text-red-600 hover:bg-red-50 disabled:opacity-50 dark:text-red-400 dark:hover:bg-red-950/40"
                      disabled={jam.busy === 'remove'}
                      aria-label={t('Remove {device} from the Jam', { device: g.name })}
                      onclick={() => void jam.removeGuest(g.id)}
                    >
                      {t('Remove')}
                    </button>
                  </li>
                {/each}
              </ul>
            {/if}
          </section>

          <!-- Recent adds -->
          <section class="flex flex-col gap-2" aria-labelledby="jam-recent">
            <h4 id="jam-recent" class={sectionTitle}>{t('Recently added')}</h4>
            {#if !status || status.recent.length === 0}
              <p class="text-xs text-zinc-500 dark:text-zinc-400">{t('Songs your guests add show up here and at the end of the queue.')}</p>
            {:else}
              <ol class="flex flex-col">
                {#each status.recent as r, i (i)}
                  <li class="flex items-center gap-3 py-1.5">
                    <Icon name="queueAdd" class="size-4 shrink-0 text-accent-600 dark:text-accent-400" />
                    <div class="min-w-0 flex-1">
                      <p class="truncate text-sm">{r.title}</p>
                      <p class="truncate text-xs text-zinc-500 dark:text-zinc-400">
                        {r.artist || t('Unknown artist')} · {t('added by {name}', { name: shortName(r.addedBy) })}
                      </p>
                    </div>
                  </li>
                {/each}
              </ol>
            {/if}
          </section>
        </div>
      </div>

      <footer class="flex flex-wrap items-center justify-between gap-3 border-t border-zinc-200/80 px-5 py-3 dark:border-zinc-800">
        <p class="min-w-0 flex-1 text-xs text-zinc-500 dark:text-zinc-400">
          {confirmEnd
            ? t('End the Jam? Every guest is disconnected and the code stops working.')
            : t('Music plays only here. Guests can add songs, nothing else.')}
        </p>
        <div class="flex items-center gap-2">
          {#if confirmEnd}
            <button type="button" class={quietBtn} onclick={() => (confirmEnd = false)}>{t('Cancel')}</button>
            <button
              type="button"
              class="rounded-full bg-red-600 px-4 py-1.5 text-xs font-semibold text-white hover:bg-red-500 disabled:opacity-50"
              disabled={jam.busy === 'end'}
              onclick={() => void jam.end().then(() => (confirmEnd = false))}
            >
              {t('End Jam')}
            </button>
          {:else}
            <button type="button" class={quietBtn} onclick={close}>{t('Hide')}</button>
            <button
              type="button"
              class="rounded-full border border-red-200 px-4 py-1.5 text-xs font-semibold text-red-600 hover:bg-red-50 dark:border-red-900/60 dark:text-red-400 dark:hover:bg-red-950/40"
              onclick={() => (confirmEnd = true)}
            >
              {t('End Jam')}
            </button>
          {/if}
        </div>
        {#if errorFor('end')}
          <p class="w-full {errorText}" role="alert">{errorFor('end')}</p>
        {/if}
      </footer>
    {/if}
  </div>
</div>

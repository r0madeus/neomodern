<script lang="ts">
  import { fade, scale } from 'svelte/transition'
  import Icon from './Icon.svelte'
  import { t } from './i18n.svelte'
  import { motionDuration } from './motion'
  import ProfileAvatar from './ProfileAvatar.svelte'
  import { validPin, type Profile } from './profiles.svelte'

  // Asks for a profile PIN (K25). `onSubmit` returns an error message to
  // show, or null when it worked.
  let {
    title,
    profile = null,
    onSubmit,
    onClose,
  }: {
    title: string
    profile?: Profile | null
    onSubmit: (pin: string) => Promise<string | null>
    onClose: () => void
  } = $props()

  let pin = $state('')
  let error = $state<string | null>(null)
  let busy = $state(false)

  function explain(message: string): string {
    if (/wait 30 seconds/.test(message)) return t('Too many wrong PINs. Wait 30 seconds and try again.')
    if (/wrong PIN|needs its PIN/.test(message)) return t('Wrong PIN.')
    if (/4 to 8 digits/.test(message)) return t('The PIN must be 4 to 8 digits.')
    return message
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault()
    if (!validPin(pin) || busy) return
    busy = true
    const err = await onSubmit(pin)
    busy = false
    if (err) {
      error = explain(err)
      pin = ''
    }
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onClose()} />

<div
  transition:fade={{ duration: motionDuration(120) }}
  class="fixed inset-0 z-[120] flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
  role="dialog"
  aria-modal="true"
  aria-label={title}
>
  <form
    transition:scale={{ start: 0.96, duration: motionDuration(160) }}
    class="w-full max-w-xs rounded-2xl border border-zinc-200 bg-white p-5 text-center shadow-2xl dark:border-zinc-800 dark:bg-zinc-900"
    onsubmit={submit}
  >
    <div class="flex justify-end">
      <button
        type="button"
        aria-label={t('Close')}
        class="-mt-2 -mr-2 rounded-lg p-1 text-zinc-400 hover:bg-zinc-100 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200"
        onclick={onClose}
      >
        <Icon name="close" class="size-4" />
      </button>
    </div>
    {#if profile}
      <ProfileAvatar {profile} class="mx-auto size-14 text-xl" />
    {/if}
    <p class="mt-3 text-base font-semibold">{title}</p>
    <!-- svelte-ignore a11y_autofocus -->
    <input
      class="mt-4 w-full rounded-lg border border-zinc-200 bg-white px-3 py-2.5 text-center text-2xl tracking-[0.5em] tabular-nums focus:border-accent-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-950"
      type="password"
      inputmode="numeric"
      autocomplete="off"
      maxlength="8"
      aria-label={t('PIN')}
      autofocus
      bind:value={pin}
      oninput={() => {
        pin = pin.replace(/[^0-9]/g, '')
        error = null
      }}
    />
    {#if error}
      <p class="mt-2 text-xs text-red-600 dark:text-red-400" role="alert">{error}</p>
    {/if}
    <button
      type="submit"
      class="mt-4 w-full rounded-full bg-accent-600 py-2 text-sm font-semibold text-white transition hover:bg-accent-500 disabled:opacity-50 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400"
      disabled={!validPin(pin) || busy}
    >
      {t('OK')}
    </button>
  </form>
</div>

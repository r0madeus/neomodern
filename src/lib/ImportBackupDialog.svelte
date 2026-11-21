<script lang="ts">
  import { fade, scale } from 'svelte/transition'
  import Icon from './Icon.svelte'
  import { count, i18n, t } from './i18n.svelte'
  import { backup, type BackupSummary } from './backup.svelte'
  import { explainBackupError, formatDateTime } from './backupLogic'
  import { motionDuration } from './motion'
  import { portal } from './portal'

  // Import confirmation (docs/BACKUP.md §1): what the file holds, a clear
  // "replace everything" warning, then "Restart now" once it is staged.
  let { summary, path, onClose }: { summary: BackupSummary; path: string; onClose: () => void } = $props()

  let stage = $state<'confirm' | 'importing' | 'ready' | 'restarting'>('confirm')
  let error = $state<string | null>(null)

  const created = $derived(formatDateTime(summary.createdAt, i18n.locale))
  const rows = $derived<[string, string][]>([
    [t('Made on'), created ?? '–'],
    [t('From version'), summary.appVersion ? `NeoModern ${summary.appVersion}` : '–'],
    [t('Profiles'), String(summary.profiles)],
    [t('Songs'), summary.tracks.toLocaleString(i18n.locale)],
    [t('Playlists'), summary.playlists.toLocaleString(i18n.locale)],
    [t('Favorites'), summary.favorites.toLocaleString(i18n.locale)],
  ])

  async function replace(): Promise<void> {
    stage = 'importing'
    error = null
    try {
      await backup.importFile(path)
      stage = 'ready'
    } catch (e) {
      error = explainBackupError(String(e), t)
      stage = 'confirm'
    }
  }

  async function restart(): Promise<void> {
    stage = 'restarting'
    error = null
    try {
      await backup.restart()
    } catch (e) {
      error = String(e)
      stage = 'ready'
    }
  }

  // Once staged, closing would leave the import for the next start: allowed,
  // and said so in the text.
  const close = () => {
    if (stage === 'confirm' || stage === 'ready') onClose()
  }

  const primaryBtn =
    'rounded-full bg-accent-600 px-4 py-1.5 text-xs font-semibold text-white transition hover:bg-accent-500 disabled:opacity-50 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400'
  const dangerBtn =
    'rounded-full bg-red-600 px-4 py-1.5 text-xs font-semibold text-white transition hover:bg-red-500 disabled:opacity-50'
  const actionBtn =
    'rounded-full border border-zinc-200 bg-white px-3.5 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800/80 dark:text-zinc-200 dark:hover:bg-zinc-700'
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && close()} />

<div
  use:portal
  transition:fade={{ duration: motionDuration(150) }}
  class="fixed inset-0 z-[120] flex items-center justify-center bg-black/50 p-4 backdrop-blur-xs"
  role="dialog"
  aria-modal="true"
  aria-labelledby="import-title"
>
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="absolute inset-0" onclick={close}></div>
  <div
    transition:scale={{ start: 0.96, duration: motionDuration(180) }}
    class="relative flex max-h-full w-full max-w-md flex-col gap-4 overflow-y-auto rounded-2xl border border-zinc-200 bg-white p-5 shadow-2xl dark:border-zinc-800 dark:bg-zinc-900"
  >
    <header class="flex items-start gap-3">
      <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-500/15 text-accent-600 dark:text-accent-400">
        <Icon name="backup" class="size-5" />
      </span>
      <div class="min-w-0 flex-1">
        <h3 id="import-title" class="text-base font-semibold">
          {stage === 'ready' || stage === 'restarting' ? t('Backup ready') : t('Import backup')}
        </h3>
        <p class="mt-0.5 truncate text-xs text-zinc-500 dark:text-zinc-400" title={path}>{path}</p>
      </div>
      {#if stage === 'confirm' || stage === 'ready'}
        <button
          type="button"
          aria-label={t('Close')}
          class="-mt-1 -mr-1 rounded-lg p-1 text-zinc-400 hover:bg-zinc-100 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200"
          onclick={close}
        >
          <Icon name="close" class="size-4" />
        </button>
      {/if}
    </header>

    {#if stage === 'ready' || stage === 'restarting'}
      <p class="text-sm text-zinc-700 dark:text-zinc-300">
        {t('NeoModern needs to restart to finish. The backup replaces this device’s data when the app starts again.')}
      </p>
      <p class="text-xs text-zinc-500 dark:text-zinc-400">
        {t('Afterwards the library checks your music folders. If a folder is not found, use “Move…” in Settings › Library.')}
      </p>
    {:else}
      <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 rounded-xl bg-zinc-100/80 px-3.5 py-3 text-sm dark:bg-zinc-950/60">
        {#each rows as [k, v] (k)}
          <dt class="text-zinc-500 dark:text-zinc-400">{k}</dt>
          <dd class="min-w-0 truncate text-right font-medium tabular-nums">{v}</dd>
        {/each}
      </dl>

      <div class="rounded-xl border border-red-500/30 bg-red-500/8 px-3.5 py-3">
        <p class="text-sm font-semibold text-red-700 dark:text-red-300">{t('Replace all data on this device?')}</p>
        <p class="mt-1 text-xs text-zinc-700 dark:text-zinc-300">
          {t('Profiles, favorites, playlists, history, queues and settings on this device are replaced by the backup.')}
        </p>
        <p class="mt-1.5 text-xs text-zinc-500 dark:text-zinc-400">
          {t('Your current data is kept as a copy in the app’s data folder. Music files are not touched.')}
        </p>
      </div>
      {#if summary.tracks > 0}
        <p class="-mt-1 text-xs text-zinc-500 dark:text-zinc-400">
          {count(summary.tracks, 'The {n} song needs its music folder on this device too.', 'The {n} songs need their music folders on this device too.')}
        </p>
      {/if}
    {/if}

    {#if error}
      <p class="text-xs text-red-600 dark:text-red-400" role="alert">{error}</p>
    {/if}

    <footer class="flex flex-wrap items-center justify-end gap-2">
      {#if stage === 'ready' || stage === 'restarting'}
        <button type="button" class={actionBtn} disabled={stage === 'restarting'} onclick={close}>
          {t('Later')}
        </button>
        <button type="button" class={primaryBtn} disabled={stage === 'restarting'} onclick={() => void restart()}>
          {stage === 'restarting' ? t('Restarting…') : t('Restart now')}
        </button>
      {:else}
        <button type="button" class={actionBtn} disabled={stage === 'importing'} onclick={close}>
          {t('Cancel')}
        </button>
        <button type="button" class={dangerBtn} disabled={stage === 'importing'} onclick={() => void replace()}>
          {stage === 'importing' ? t('Preparing…') : t('Replace data')}
        </button>
      {/if}
    </footer>
  </div>
</div>

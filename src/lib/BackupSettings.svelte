<script lang="ts">
  import { onMount } from 'svelte'
  import type { ClassValue } from 'svelte/elements'
  import Icon from './Icon.svelte'
  import ToggleSwitch from './ToggleSwitch.svelte'
  import ImportBackupDialog from './ImportBackupDialog.svelte'
  import { i18n, t } from './i18n.svelte'
  import { backup, type BackupSummary } from './backup.svelte'
  import {
    explainBackupError,
    formatBytes,
    formatDateTime,
    KEEP_CHOICES,
    type BackupInterval,
  } from './backupLogic'

  // Settings › Backup (docs/BACKUP.md): export and import on every device,
  // automatic backups to a folder on the computer only.
  let { cardClass, pillGroup, pillBtn, actionBtn }: {
    cardClass: string
    pillGroup: string
    pillBtn: (active: boolean) => ClassValue
    actionBtn: string
  } = $props()

  let busy = $state<'export' | 'import' | 'folder' | 'now' | null>(null)
  let note = $state<{ text: string; error: boolean } | null>(null)
  let autoError = $state<string | null>(null)
  let importing = $state<{ path: string; summary: BackupSummary } | null>(null)

  const INTERVALS: { value: BackupInterval; label: string }[] = [
    { value: 'daily', label: 'Every day' },
    { value: 'weekly', label: 'Every week' },
  ]

  async function exportBackup(): Promise<void> {
    if (busy) return
    busy = 'export'
    note = null
    try {
      const path = await backup.exportFile()
      if (path) note = { text: t('Backup saved: {path}', { path }), error: false }
    } catch (e) {
      note = { text: explainBackupError(String(e), t), error: true }
    } finally {
      busy = null
    }
  }

  async function importBackup(): Promise<void> {
    if (busy) return
    busy = 'import'
    note = null
    try {
      const path = await backup.pickImportFile()
      if (!path) return
      importing = { path, summary: await backup.inspect(path) }
    } catch (e) {
      note = { text: explainBackupError(String(e), t), error: true }
    } finally {
      busy = null
    }
  }

  /** Runs a change to the automatic backup and shows what went wrong. */
  async function autoAction(kind: 'folder' | 'now' | null, run: () => Promise<unknown>): Promise<void> {
    if (kind) busy = kind
    autoError = null
    try {
      await run()
    } catch (e) {
      autoError = explainBackupError(String(e), t)
    } finally {
      if (kind) busy = null
    }
  }

  function setEnabled(next: boolean): void {
    void autoAction(null, async () => {
      // Turning it on without a folder asks for one first.
      if (next && !backup.settings.folder && !(await backup.pickFolder())) return
      await backup.setSettings({ enabled: next })
    })
  }

  const status = $derived(backup.status)
  const lastAt = $derived(formatDateTime(status.lastAt, i18n.locale))
  const statusLine = $derived.by(() => {
    if (status.running) return { text: t('Backing up…'), tone: 'busy' as const }
    if (status.lastError)
      return {
        text: t('Last backup failed: {error}', { error: explainBackupError(status.lastError, t) }),
        tone: 'error' as const,
      }
    if (lastAt)
      return {
        text:
          status.lastSize !== null
            ? t('Last backup: {time} ({size})', { time: lastAt, size: formatBytes(status.lastSize, i18n.locale) })
            : t('Last backup: {time}', { time: lastAt }),
        tone: 'ok' as const,
      }
    return { text: t('No backup yet.'), tone: 'idle' as const }
  })

  onMount(() => {
    if (backup.automaticAvailable) void autoAction(null, () => backup.load())
  })

  const help = 'mt-0.5 text-xs text-zinc-500 dark:text-zinc-400'
  const row = 'flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between'
</script>

<div class={cardClass}>
  <div class={row}>
    <div class="min-w-0">
      <p class="text-sm font-medium">{t('Export a backup')}</p>
      <p class={help}>
        {t('Saves profiles and PINs, favorites, playlists, history and stats, queues, settings, artist info, lyrics and album covers in one file. Your music files are not included.')}
      </p>
    </div>
    <button type="button" class={[actionBtn, 'w-fit']} disabled={busy !== null} onclick={() => void exportBackup()}>
      {busy === 'export' ? t('Exporting…') : t('Export…')}
    </button>
  </div>

  <div class={row}>
    <div class="min-w-0">
      <p class="text-sm font-medium">{t('Import a backup')}</p>
      <p class={help}>
        {t('Replaces the data on this device with a backup, for example from your old computer. You see what it holds before anything changes.')}
      </p>
    </div>
    <button type="button" class={[actionBtn, 'w-fit']} disabled={busy !== null} onclick={() => void importBackup()}>
      {busy === 'import' ? t('Checking…') : t('Import…')}
    </button>
  </div>

  {#if note}
    <p
      class={['px-4 py-3 text-xs break-all', note.error ? 'text-red-600 dark:text-red-400' : 'text-zinc-600 dark:text-zinc-300']}
      role={note.error ? 'alert' : 'status'}
    >
      {note.text}
    </p>
  {/if}
</div>

{#if backup.automaticAvailable}
  <div class={cardClass}>
    <div class="flex items-start justify-between gap-6 p-4">
      <div class="min-w-0">
        <p id="autobackup-label" class="text-sm font-medium">{t('Automatic backup')}</p>
        <p id="autobackup-help" class={help}>
          {t('Saves a backup to a folder on a schedule. Choose a OneDrive, Google Drive or Dropbox folder to keep it in the cloud too.')}
        </p>
      </div>
      <ToggleSwitch
        ariaLabelledby="autobackup-label"
        ariaDescribedby="autobackup-help"
        disabled={!backup.loaded}
        bind:checked={() => backup.settings.enabled, (next) => setEnabled(next)}
      />
    </div>

    <div class={row}>
      <div class="min-w-0 flex-1">
        <p class="text-sm font-medium">{t('Backup folder')}</p>
        {#if backup.settings.folder}
          <code
            class="mt-1.5 block truncate rounded-xl bg-zinc-100 px-3 py-2 text-xs select-all dark:bg-zinc-950/70"
            title={backup.settings.folder}
          >
            {backup.settings.folder}
          </code>
        {:else}
          <p class={help}>{t('No folder chosen yet.')}</p>
        {/if}
      </div>
      <button
        type="button"
        class={[actionBtn, 'w-fit']}
        disabled={busy !== null || !backup.loaded}
        onclick={() => void autoAction('folder', () => backup.pickFolder())}
      >
        <span class="inline-flex items-center gap-1.5"><Icon name="folder" class="size-3.5" />{t('Choose…')}</span>
      </button>
    </div>

    <div class={row}>
      <p id="autobackup-interval" class="text-sm font-medium">{t('How often')}</p>
      <div role="radiogroup" aria-labelledby="autobackup-interval" class={pillGroup}>
        {#each INTERVALS as opt (opt.value)}
          <button
            type="button"
            role="radio"
            aria-checked={backup.settings.interval === opt.value}
            class={pillBtn(backup.settings.interval === opt.value)}
            disabled={!backup.loaded}
            onclick={() => void autoAction(null, () => backup.setSettings({ interval: opt.value }))}
          >
            {t(opt.label)}
          </button>
        {/each}
      </div>
    </div>

    <div class={row}>
      <div class="min-w-0">
        <p id="autobackup-keep" class="text-sm font-medium">{t('Keep the newest')}</p>
        <p class={help}>{t('Older backups in the folder are deleted. Only files NeoModern made are touched.')}</p>
      </div>
      <div role="radiogroup" aria-labelledby="autobackup-keep" class={pillGroup}>
        {#each KEEP_CHOICES as n (n)}
          <button
            type="button"
            role="radio"
            aria-checked={backup.settings.keep === n}
            class={pillBtn(backup.settings.keep === n)}
            disabled={!backup.loaded}
            onclick={() => void autoAction(null, () => backup.setSettings({ keep: n }))}
          >
            {n}
          </button>
        {/each}
      </div>
    </div>

    <div class={row}>
      <p
        class={[
          'flex min-w-0 items-center gap-2 text-xs',
          statusLine.tone === 'error' ? 'text-red-600 dark:text-red-400' : 'text-zinc-600 dark:text-zinc-300',
        ]}
        role="status"
      >
        {#if statusLine.tone === 'busy'}
          <span class="size-3 shrink-0 animate-spin rounded-full border-2 border-current border-t-transparent"></span>
        {:else if statusLine.tone === 'ok'}
          <Icon name="checkCircle" class="size-4 shrink-0 text-emerald-600 dark:text-emerald-400" />
        {:else if statusLine.tone === 'error'}
          <Icon name="info" class="size-4 shrink-0" />
        {/if}
        <span class="min-w-0">{statusLine.text}</span>
      </p>
      <button
        type="button"
        class={[actionBtn, 'w-fit']}
        disabled={busy !== null || status.running || !backup.settings.folder}
        onclick={() => void autoAction('now', () => backup.backupNow())}
      >
        {t('Back up now')}
      </button>
    </div>
    {#if autoError}
      <p class="px-4 py-3 text-xs text-red-600 dark:text-red-400" role="alert">{autoError}</p>
    {/if}
  </div>
{/if}

{#if importing}
  <ImportBackupDialog path={importing.path} summary={importing.summary} onClose={() => (importing = null)} />
{/if}

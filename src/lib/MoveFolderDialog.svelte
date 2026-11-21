<script lang="ts">
  import { open } from '@tauri-apps/plugin-dialog'
  import { invoke } from '@tauri-apps/api/core'
  import { onMount } from 'svelte'
  import { fade, scale } from 'svelte/transition'
  import Icon from './Icon.svelte'
  import { i18n, t } from './i18n.svelte'
  import { appSettings } from './appSettings.svelte'
  import { library, type FolderInfo, type FolderMoveCheck } from './library.svelte'
  import { playlists } from './playlists.svelte'
  import { explainBackupError, moveMatch, movedCount } from './backupLogic'
  import { motionDuration } from './motion'
  import { portal } from './portal'

  // "Move folder…" (docs/BACKUP.md §2): pick where the folder is now, see how
  // many of its songs are found there, then rewrite the saved paths. Nothing
  // on disk is moved or changed; the check and the move run in Rust.
  let { folder, onClose }: { folder: FolderInfo; onClose: () => void } = $props()

  let newPath = $state<string | null>(null)
  let check = $state<FolderMoveCheck | null>(null)
  let busy = $state<'pick' | 'check' | 'apply' | null>(null)
  let error = $state<string | null>(null)

  const match = $derived(check ? moveMatch(check) : null)
  const counted = $derived(check ? movedCount(check) : null)
  const nf = $derived(new Intl.NumberFormat(i18n.locale))

  async function pick(): Promise<void> {
    if (busy) return
    busy = 'pick'
    error = null
    try {
      const picked =
        appSettings.platform === 'android'
          ? await invoke<string | null>('library_android_pick_folder')
          : await open({ directory: true, multiple: false, title: t('Where is this folder now?') })
      if (typeof picked !== 'string') {
        busy = null
        // Cancelled before anything was chosen: nothing to show.
        if (newPath === null) onClose()
        return
      }
      newPath = picked
      check = null
      busy = 'check'
      check = await library.checkMove(folder.id, picked)
    } catch (e) {
      error = explainBackupError(String(e), t)
    } finally {
      busy = null
    }
  }

  async function apply(): Promise<void> {
    if (!newPath || busy || match === 'none' || match === 'missing') return
    busy = 'apply'
    error = null
    try {
      await library.moveFolder(folder.id, newPath)
      playlists.flash(t('Folder moved. Its songs are being rescanned.'))
      onClose()
    } catch (e) {
      error = explainBackupError(String(e), t)
    } finally {
      busy = null
    }
  }

  // The picker opens straight away; the dialog shows what it found.
  onMount(() => {
    void pick()
  })

  const close = () => {
    if (busy !== 'apply') onClose()
  }

  const primaryBtn =
    'rounded-full bg-accent-600 px-4 py-1.5 text-xs font-semibold text-white transition hover:bg-accent-500 disabled:opacity-50 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400'
  const actionBtn =
    'rounded-full border border-zinc-200 bg-white px-3.5 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800/80 dark:text-zinc-200 dark:hover:bg-zinc-700'
  const quietBtn =
    'mr-auto rounded-full px-3 py-1.5 text-xs text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 disabled:opacity-50 dark:hover:bg-zinc-800 dark:hover:text-zinc-100'
  const label = 'text-[11px] font-semibold uppercase tracking-wider text-zinc-400'
  const pathBox =
    'mt-1 block truncate rounded-lg bg-zinc-100 px-3 py-2 text-xs select-all dark:bg-zinc-950/70'
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && close()} />

{#if newPath !== null}
  <div
    use:portal
    transition:fade={{ duration: motionDuration(150) }}
    class="fixed inset-0 z-[120] flex items-center justify-center bg-black/50 p-4 backdrop-blur-xs"
    role="dialog"
    aria-modal="true"
    aria-labelledby="move-title"
  >
    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
    <div class="absolute inset-0" onclick={close}></div>
    <div
      transition:scale={{ start: 0.96, duration: motionDuration(180) }}
      class="relative flex max-h-full w-full max-w-md flex-col gap-4 overflow-y-auto rounded-2xl border border-zinc-200 bg-white p-5 shadow-2xl dark:border-zinc-800 dark:bg-zinc-900"
    >
      <header class="flex items-start gap-3">
        <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-500/15 text-accent-600 dark:text-accent-400">
          <Icon name="folder" class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <h3 id="move-title" class="text-base font-semibold">{t('Move folder')}</h3>
          <p class="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">
            {t('Only the place NeoModern looks for this folder changes. No files are moved, copied or changed.')}
          </p>
        </div>
        <button
          type="button"
          aria-label={t('Close')}
          class="-mt-1 -mr-1 rounded-lg p-1 text-zinc-400 hover:bg-zinc-100 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200"
          onclick={close}
        >
          <Icon name="close" class="size-4" />
        </button>
      </header>

      <div class="flex flex-col gap-3">
        <div class="min-w-0">
          <p class={label}>{t('Old location')}</p>
          <code class={pathBox} title={folder.path}>{folder.path}</code>
        </div>
        <div class="min-w-0">
          <p class={label}>{t('New location')}</p>
          <code class={pathBox} title={newPath}>{newPath}</code>
        </div>
      </div>

      <div role="status" aria-live="polite">
        {#if busy === 'check' || busy === 'pick'}
          <p class="flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400">
            <span class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent"></span>
            {t('Looking for the folder’s songs there…')}
          </p>
        {:else if check && counted && match}
          <div
            class={[
              'rounded-xl px-3.5 py-3 text-sm',
              match === 'all' && 'bg-emerald-500/10 text-emerald-800 dark:text-emerald-300',
              match === 'some' && 'bg-amber-500/12 text-amber-800 dark:text-amber-300',
              (match === 'none' || match === 'missing') && 'bg-red-500/10 text-red-700 dark:text-red-300',
            ]}
          >
            <p class="font-semibold">
              {#if match === 'missing'}
                {t('That folder was not found.')}
              {:else if counted.total === 0}
                {t('This folder has no songs yet.')}
              {:else}
                {t(counted.estimate ? 'About {found} of {total} songs found' : '{found} of {total} songs found', {
                  found: nf.format(counted.found),
                  total: nf.format(counted.total),
                })}
              {/if}
            </p>
            <p class="mt-1 text-xs opacity-90">
              {#if match === 'all'}
                {t('Favorites, playlists, history and stats stay with the songs.')}
              {:else if match === 'some'}
                {t('Favorites, playlists, history and stats stay with the songs. The songs that are not there are removed from the library when the folder is scanned.')}
              {:else if match === 'none'}
                {t('None of this folder’s songs are there. Check that you picked the right folder.')}
              {:else}
                {t('Choose the folder where the music is now.')}
              {/if}
            </p>
          </div>
        {/if}
        {#if error}
          <p class="mt-2 text-xs text-red-600 dark:text-red-400" role="alert">{error}</p>
        {/if}
      </div>

      <footer class="flex flex-wrap items-center justify-end gap-2">
        <button type="button" class={quietBtn} disabled={busy === 'apply'} onclick={close}>
          {t('Cancel')}
        </button>
        <button type="button" class={actionBtn} disabled={busy !== null} onclick={() => void pick()}>
          {t('Choose another folder…')}
        </button>
        <button
          type="button"
          class={primaryBtn}
          disabled={busy !== null || !check || match === 'none' || match === 'missing'}
          onclick={() => void apply()}
        >
          {busy === 'apply' ? t('Moving…') : t('Move folder')}
        </button>
      </footer>
    </div>
  </div>
{/if}

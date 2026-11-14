<script lang="ts">
  // First-run welcome. Desktop: suggests the OS Music folder and offers the
  // optional one-click setup of the online tools. Android: asks for music
  // access and opens the system folder picker (no online tools there).
  // Rust decides whether it is shown (no folder added and never finished).
  import Logo from './Logo.svelte'
  import { invoke } from '@tauri-apps/api/core'
  import { onMount } from 'svelte'
  import Icon from './Icon.svelte'
  import ToolSetup from './ToolSetup.svelte'
  import { appSettings } from './appSettings.svelte'
  import { count, t } from './i18n.svelte'
  import { library } from './library.svelte'
  import { online } from './online.svelte'

  interface WelcomeInfo {
    show: boolean
    musicDir: string | null
    musicDirFiles: number
  }

  let info = $state<WelcomeInfo | null>(null)
  let step = $state<'folder' | 'online'>('folder')
  let adding = $state(false)
  let pickError = $state<string | null>(null)
  const android = $derived(appSettings.platform === 'android')

  onMount(() => {
    invoke<WelcomeInfo>('app_welcome')
      .then((w) => (info = w))
      .catch(() => (info = null))
  })

  const open = $derived(info?.show === true)
  const hasFolder = $derived(library.folders.length > 0)
  const suggestedAdded = $derived(
    info?.musicDir != null && library.folders.some((f) => f.path === info?.musicDir),
  )
  // The online step only makes sense where the tools can be set up here.
  const offerOnline = $derived(
    appSettings.platform !== 'android' && appSettings.allowOnline && online.status?.canInstallTools === true,
  )
  const toolsReady = $derived(
    online.status?.ytdlpAvailable === true && online.status?.ffmpegAvailable === true,
  )

  async function addSuggested() {
    if (!info?.musicDir || adding) return
    adding = true
    await library.addFolderPath(info.musicDir)
    adding = false
  }

  async function pickFolder() {
    if (adding) return
    adding = true
    pickError = null
    try {
      if (android) {
        // Asks for permission to read music first, then the system picker.
        const path = await invoke<string | null>('library_android_pick_folder')
        if (path) await library.addFolderPath(path)
      } else {
        await library.addFolder()
      }
    } catch (e) {
      pickError = String(e)
    } finally {
      adding = false
    }
  }

  function next() {
    if (step === 'folder' && offerOnline) step = 'online'
    else void finish()
  }

  async function finish() {
    if (online.installingTools) return
    info = info ? { ...info, show: false } : null
    try {
      await invoke('app_finish_welcome')
    } catch {
      // Not saved: the welcome shows again next time, nothing else breaks.
    }
  }

  function onKey(e: KeyboardEvent) {
    if (open && e.key === 'Escape') void finish()
  }
</script>

<svelte:window onkeydown={onKey} />

{#if open && info}
  <div
    class={[
      'fixed inset-0 z-50 flex justify-center bg-zinc-950/60 backdrop-blur-sm',
      android ? 'items-end' : 'items-center p-4',
    ]}
    style:padding-top={android ? 'var(--inset-top)' : undefined}
    role="presentation"
  >
    <div
      class={[
        'animate-view-enter flex max-h-full w-full max-w-lg flex-col overflow-y-auto border border-zinc-200/80 bg-white text-zinc-900 shadow-2xl dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-100',
        android ? 'rounded-t-3xl' : 'rounded-3xl',
      ]}
      role="dialog"
      aria-modal="true"
      aria-labelledby="welcome-title"
    >
      <div class="bg-gradient-to-br from-accent-500 via-accent-700 to-zinc-950 px-7 pt-7 pb-6 text-white">
        <div class="flex size-12 items-center justify-center rounded-2xl bg-white/15 shadow-lg">
          <Logo class="size-6" />
        </div>
        <h2 id="welcome-title" class="mt-4 text-2xl font-bold tracking-tight">
          {t('Welcome to NeoModern')}
        </h2>
        <p class="mt-1 text-sm text-white/80">
          {step === 'online'
            ? t('Optional: search and download music from the internet.')
            : android
              ? t('Pick the folder with your music. NeoModern asks for permission to read it, and only reads it.')
              : t('Let’s find your music. It stays where it is; NeoModern only reads it.')}
        </p>
      </div>

      <div class="flex flex-col gap-4 px-7 py-6">
        {#if step === 'folder'}
          {#if info.musicDir && !android}
            <div class="rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800">
              <div class="flex items-start gap-3">
                <Icon name="folder" class="mt-0.5 size-5 shrink-0 text-accent-600 dark:text-accent-400" />
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-medium">{t('Your Music folder')}</p>
                  <p class="truncate text-xs text-zinc-500" title={info.musicDir}>{info.musicDir}</p>
                  <p class="mt-1 text-xs text-zinc-600 dark:text-zinc-300">
                    {#if info.musicDirFiles === 0}
                      {t('No songs found here yet.')}
                    {:else if info.musicDirFiles >= 5000}
                      {t('More than 5,000 songs found.')}
                    {:else}
                      {count(info.musicDirFiles, '{n} song found', '{n} songs found')}
                    {/if}
                  </p>
                </div>
              </div>
              <div class="mt-3 flex flex-wrap gap-2">
                {#if suggestedAdded}
                  <span class="inline-flex items-center gap-1.5 rounded-full bg-emerald-500/15 px-3 py-1.5 text-xs font-semibold text-emerald-700 dark:text-emerald-400">
                    <Icon name="check" class="size-3.5" />
                    {t('Added')}
                  </span>
                {:else}
                  <button
                    type="button"
                    class="rounded-full bg-accent-500 px-4 py-1.5 text-xs font-semibold text-zinc-950 hover:bg-accent-400 disabled:opacity-50"
                    disabled={adding}
                    onclick={() => void addSuggested()}
                  >
                    {t('Use this folder')}
                  </button>
                {/if}
              </div>
            </div>
          {/if}

          {#if android && !hasFolder}
            <button
              type="button"
              class="flex items-center justify-center gap-2 rounded-2xl bg-accent-500 px-4 py-3 text-sm font-semibold text-zinc-950 active:bg-accent-400 disabled:opacity-50"
              disabled={adding}
              onclick={() => void pickFolder()}
            >
              <Icon name="folder" class="size-5" />
              {t('Choose your music folder…')}
            </button>
            <p class="text-xs text-zinc-500">{t('Usually this is the Music or Download folder on your phone.')}</p>
          {:else}
            <button
              type="button"
              class="flex items-center gap-2 self-start rounded-full border border-zinc-200 px-4 py-1.5 text-xs font-medium hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              disabled={adding}
              onclick={() => void pickFolder()}
            >
              <Icon name="plus" class="size-3.5" />
              {info.musicDir || hasFolder ? t('Add another folder…') : t('Choose your music folder…')}
            </button>
          {/if}
          {#if pickError}
            <p class="text-xs text-red-600 dark:text-red-400" role="alert">{pickError}</p>
          {/if}

          {#if hasFolder}
            <ul class="flex flex-col gap-1 text-xs text-zinc-600 dark:text-zinc-300">
              {#each library.folders.filter((f) => f.path !== info?.musicDir) as f (f.id)}
                <li class="flex items-center gap-2 truncate">
                  <Icon name="check" class="size-3.5 shrink-0 text-emerald-600" />
                  <span class="truncate" title={f.path}>{f.path}</span>
                </li>
              {/each}
            </ul>
            <p class="text-xs text-zinc-500" role="status">
              {library.scanning || library.stats.tracks === 0
                ? t('Scanning in the background, you can start listening right away.')
                : count(library.stats.tracks, '{n} track in your library', '{n} tracks in your library')}
            </p>
          {/if}
        {:else}
          <div class="rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800">
            <div class="flex items-start gap-3">
              <Icon name="globe" class="mt-0.5 size-5 shrink-0 text-accent-600 dark:text-accent-400" />
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium">{t('Online search and download')}</p>
                <p class="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">
                  {t('Needs two free tools, yt-dlp and ffmpeg. NeoModern can fetch the right version for your computer. You can also do this later in Settings.')}
                </p>
                <div class="mt-3">
                  {#if toolsReady}
                    <span class="inline-flex items-center gap-1.5 rounded-full bg-emerald-500/15 px-3 py-1.5 text-xs font-semibold text-emerald-700 dark:text-emerald-400">
                      <Icon name="check" class="size-3.5" />
                      {t('Ready')}
                    </span>
                  {:else}
                    <ToolSetup />
                  {/if}
                </div>
              </div>
            </div>
          </div>
        {/if}
      </div>

      <div
        class="flex items-center justify-between gap-3 border-t border-zinc-200/80 px-7 pt-4 dark:border-zinc-800"
        style:padding-bottom={android ? 'calc(var(--inset-bottom, 0px) + 1rem)' : '1rem'}
      >
        <button
          type="button"
          class="rounded-full px-3 py-1.5 text-xs text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 disabled:opacity-50 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
          disabled={online.installingTools}
          onclick={() => void finish()}
        >
          {t('Skip')}
        </button>
        <button
          type="button"
          class="rounded-full bg-accent-500 px-5 py-2 text-sm font-semibold text-zinc-950 hover:bg-accent-400 disabled:opacity-50"
          disabled={online.installingTools}
          onclick={next}
        >
          {step === 'folder' && offerOnline ? t('Next') : t('Start listening')}
        </button>
      </div>
    </div>
  </div>
{/if}

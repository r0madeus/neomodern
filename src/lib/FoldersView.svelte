<script lang="ts">
  import { count, t } from './i18n.svelte'
  import Icon from './Icon.svelte'
  import { library, type FolderInfo } from './library.svelte'
  import MoveFolderDialog from './MoveFolderDialog.svelte'

  let { embedded = false }: { embedded?: boolean } = $props()

  // "Move folder…" (docs/BACKUP.md §2): for a folder that now lives on
  // another drive or computer.
  let moving = $state<FolderInfo | null>(null)
  const anyMissing = $derived(library.folders.some((f) => f.reachable === false))
</script>

<div class={embedded ? '' : 'mx-auto max-w-2xl px-5 pb-6'}>
  <div class="mb-3 flex items-center justify-between gap-3">
    {#if embedded}
      <p class="text-sm font-medium">{t("Music folders")}</p>
    {:else}
      <h2 class="text-lg font-semibold tracking-tight">{t("Music folders")}</h2>
    {/if}
    <div class="flex gap-2">
      <button
        class="rounded-full border border-zinc-200 px-3.5 py-1.5 text-xs font-medium text-zinc-600 transition hover:bg-zinc-100 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        onclick={() => library.rescan()}
        disabled={library.folders.length === 0 || library.scanning}
      >
        {t("Rescan")}
      </button>
      <button
        class="flex items-center gap-1.5 rounded-full bg-accent-600 px-3.5 py-1.5 text-xs font-semibold text-white transition hover:bg-accent-500"
        onclick={() => library.addFolder()}
      >
        <Icon name="folder" class="size-3.5" /> {t("Add folder")}
      </button>
    </div>
  </div>

  {#if library.scan}
    <p class="mb-3 text-sm text-accent-700 dark:text-accent-400" role="status">
      Scanning {library.scan.folder} – {library.scan.scanned.toLocaleString()} files…
    </p>
  {:else if library.scanning}
    <p class="mb-3 text-sm text-accent-700 dark:text-accent-400" role="status">{t("Scanning…")}</p>
  {/if}

  {#if anyMissing}
    <div class="mb-3 flex gap-2.5 rounded-xl bg-amber-500/12 px-3.5 py-3 text-xs text-amber-800 dark:text-amber-300" role="status">
      <Icon name="info" class="mt-px size-4 shrink-0" />
      <div class="min-w-0">
        <p class="font-semibold">{t('Music folders not found')}</p>
        <p class="mt-0.5 opacity-90">
          {t('If a folder is now on another drive or computer, use “Move…” to show where it is. Its songs stay in the library until then.')}
        </p>
      </div>
    </div>
  {/if}

  {#if library.folders.length === 0}
    <p class="text-sm text-zinc-500">{t("No folders yet. Add a folder to build your library.")}</p>
  {:else}
    <ul class="divide-y divide-zinc-200/70 overflow-hidden rounded-xl border border-zinc-200/80 bg-zinc-50/70 dark:divide-zinc-800/80 dark:border-zinc-800 dark:bg-zinc-950/40">
      {#each library.folders as f (f.id)}
        <li class="group flex items-center gap-3 px-3.5 py-2.5 text-sm">
          <Icon name="folder" class="size-4 shrink-0 text-accent-600 dark:text-accent-400" />
          <div class="flex min-w-0 flex-1 flex-col gap-0.5 sm:flex-row sm:items-center sm:gap-2">
            <span class="min-w-0 truncate text-xs sm:text-sm" title={f.path}>{f.path}</span>
            {#if f.reachable === false}
              <span class="w-fit shrink-0 rounded-full bg-amber-500/15 px-2 py-0.5 text-[11px] font-semibold text-amber-700 dark:text-amber-300">
                {t('Not found')}
              </span>
            {/if}
          </div>
          <button
            type="button"
            class={[
              'shrink-0 rounded-full px-2.5 py-1 text-xs font-medium transition',
              f.reachable === false
                ? 'bg-accent-600 text-white hover:bg-accent-500 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400'
                : 'text-zinc-500 hover:bg-zinc-200 hover:text-zinc-800 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100',
            ]}
            onclick={() => (moving = f)}
            title={t('Move folder…')}
            aria-label={t('Move folder {path}', { path: f.path })}
          >
            {t('Move…')}
          </button>
          <button
            class="rounded-full p-1 text-zinc-400 transition hover:bg-zinc-200 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
            onclick={() => library.removeFolder(f.id)}
            aria-label="Remove folder {f.path}"
          >
            <Icon name="close" class="size-4" />
          </button>
        </li>
      {/each}
    </ul>
  {/if}
  <p class="mt-3 text-xs text-zinc-400">
    {count(library.stats.tracks, '{n} track', '{n} tracks')} · {count(library.stats.albums, '{n} album', '{n} albums')}
  </p>
</div>

{#if moving}
  <MoveFolderDialog folder={moving} onClose={() => (moving = null)} />
{/if}

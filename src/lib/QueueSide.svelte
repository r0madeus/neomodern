<script lang="ts">
  import { t } from './i18n.svelte'
  import ArtistLinks from './ArtistLinks.svelte'
  import Cover from './Cover.svelte'
  import Icon from './Icon.svelte'
  import JamButton from './JamButton.svelte'
  import QueueList from './QueueList.svelte'
  import { trackMenu } from './contextMenu.svelte'
  import { history, type RecentListen } from './history.svelte'
  import { library, type TrackRow } from './library.svelte'
  import { player } from './player.svelte'
  import { playlists } from './playlists.svelte'

  let {
    onClose,
    onOpenFiles,
    onSaved,
  }: {
    onClose: () => void
    onOpenFiles: (append: boolean) => void
    onSaved?: (id: number) => void
  } = $props()

  let tab = $state<'queue' | 'recent'>('queue')
  let saving = $state(false)
  let name = $state('')
  let recent = $state<RecentListen[]>([])
  let loadingRecent = $state(false)

  $effect(() => {
    if (tab !== 'recent') return
    void history.version
    let stale = false
    loadingRecent = true
    history
      .stats(null, null)
      .then((res) => {
        if (!stale) recent = res.recent.slice(0, 30)
      })
      .catch(() => {
        if (!stale) recent = []
      })
      .finally(() => {
        if (!stale) loadingRecent = false
      })
    return () => {
      stale = true
    }
  })

  async function save() {
    const trimmed = name.trim()
    if (trimmed === '') return
    const made = await playlists.saveQueue(trimmed)
    if (!made) return
    saving = false
    name = ''
    onSaved?.(made.id)
  }

  function fallbackRow(item: RecentListen): TrackRow {
    return {
      id: item.trackId ?? -1,
      title: item.title,
      artist: item.artist,
      album: item.album,
      albumId: null,
      trackNo: null,
      discNo: null,
      year: null,
      durationMs: null,
      path: item.path,
      cover: item.cover,
      plays: 0,
    }
  }

  async function openRecentMenu(e: MouseEvent, item: RecentListen) {
    e.preventDefault()
    e.stopPropagation()
    const x = e.clientX
    const y = e.clientY
    const row = (await library.trackByPath(item.path)) ?? fallbackRow(item)
    trackMenu.open({
      track: row,
      x,
      y,
      onPlay: () => void player.openFiles([item.path]),
    })
  }
</script>

<header class="shrink-0 border-b border-zinc-200/80 px-4 pt-3 dark:border-zinc-800/80">
  <div class="flex items-center justify-between gap-2">
    <div class="flex items-center gap-4 text-sm font-medium" role="tablist">
      <button
        type="button"
        role="tab"
        aria-selected={tab === 'queue'}
        class={[
          'border-b-2 pb-2.5 transition-colors outline-none',
          tab === 'queue'
            ? 'border-accent-500 text-zinc-900 dark:text-white'
            : 'border-transparent text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-200',
        ]}
        onclick={() => (tab = 'queue')}
      >
        {t('Queue')}
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={tab === 'recent'}
        class={[
          'border-b-2 pb-2.5 transition-colors outline-none',
          tab === 'recent'
            ? 'border-accent-500 text-zinc-900 dark:text-white'
            : 'border-transparent text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-200',
        ]}
        onclick={() => (tab = 'recent')}
      >
        {t('Recently played')}
      </button>
    </div>
    <div class="mb-2 flex items-center gap-1">
      <JamButton />
      <button
        type="button"
        class="rounded-full p-1.5 text-zinc-500 outline-none transition hover:bg-zinc-200/80 hover:text-zinc-900 focus-visible:ring-2 focus-visible:ring-accent-500 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
        onclick={onClose}
        aria-label={t('Close right panel')}
        title={t('Close right panel')}
      >
        <Icon name="close" class="size-4" />
      </button>
    </div>
  </div>
</header>

{#if tab === 'queue'}
  {#if player.snapshot.queueLength > 0}
    <div class="shrink-0 border-b border-zinc-200/60 px-4 py-2 dark:border-zinc-800/60">
      {#if saving}
        <form
          class="flex items-center gap-1.5"
          onfocusout={(e) => {
            // Clicking elsewhere with no name typed closes it.
            if (name.trim() === '' && !e.currentTarget.contains(e.relatedTarget as Node | null)) saving = false
          }}
          onsubmit={(e) => {
            e.preventDefault()
            void save()
          }}
        >
          <input
            class="min-w-0 flex-1 rounded-md border border-zinc-200 bg-white px-2 py-1 text-xs outline-none focus-visible:ring-2 focus-visible:ring-accent-500 dark:border-zinc-700 dark:bg-zinc-900"
            placeholder={t('Playlist name')}
            aria-label={t('Playlist name')}
            bind:value={name}
            onkeydown={(e) => e.key === 'Escape' && (saving = false)}
            {@attach (el) => el.focus()}
          />
          <button
            type="submit"
            class="rounded-md bg-accent-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-accent-500 disabled:opacity-50"
            disabled={name.trim() === ''}
          >
            {t('Save')}
          </button>
          <button
            type="button"
            class="rounded-md px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-200/70 dark:text-zinc-300 dark:hover:bg-zinc-800"
            onclick={() => (saving = false)}
          >
            {t('Cancel')}
          </button>
        </form>
      {:else}
        <div class="flex flex-wrap items-center gap-1.5">
          {#if player.snapshot.queueLength > 0}
            <button
              type="button"
              class="rounded-md px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-200/70 dark:text-zinc-300 dark:hover:bg-zinc-800"
              onclick={() => (saving = true)}
            >
              {t('Save as playlist')}
            </button>
          {/if}
        </div>
      {/if}
    </div>
  {/if}
  <div class="min-h-0 flex-1 overflow-y-auto pt-2">
    {#if player.snapshot.queueLength === 0}
      <div class="flex h-full items-center justify-center px-6 text-center text-sm text-zinc-500">
        {t('The queue is empty.')}
      </div>
    {:else}
      <QueueList />
    {/if}
  </div>
{:else}
  <div class="min-h-0 flex-1 overflow-y-auto px-2 py-2">
    {#if loadingRecent && recent.length === 0}
      <div class="flex h-full items-center justify-center px-6 text-center text-sm text-zinc-500">
        …
      </div>
    {:else if recent.length === 0}
      <div class="flex h-full items-center justify-center px-6 text-center text-sm text-zinc-500">
        {t('Nothing playing.')}
      </div>
    {:else}
      <ol>
        {#each recent as item (item.id)}
          <li
            class="flex h-14 items-center gap-3 rounded-lg px-2 text-sm text-zinc-800 hover:bg-zinc-200/60 dark:text-zinc-200 dark:hover:bg-zinc-800/60"
            ondblclick={() => void player.openFiles([item.path])}
            oncontextmenu={(e) => void openRecentMenu(e, item)}
          >
            <Cover cover={item.cover} title={item.title} class="size-10 shrink-0 rounded text-xs" />
            <div class="min-w-0 flex-1">
              <button
                type="button"
                class="block w-full truncate text-left text-sm font-medium hover:underline"
                onclick={() => void player.openFiles([item.path])}
                title={item.path}
              >
                {item.title}
              </button>
              <p class="truncate text-xs text-zinc-500 dark:text-zinc-400">
                {#if item.artist}
                  <ArtistLinks artist={item.artist} />
                {:else}
                  {item.path}
                {/if}
              </p>
            </div>
          </li>
        {/each}
      </ol>
    {/if}
  </div>
{/if}

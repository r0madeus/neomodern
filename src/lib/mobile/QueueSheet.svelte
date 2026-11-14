<script lang="ts">
  import { t } from '../i18n.svelte'
  import { fly } from 'svelte/transition'
  import ArtistLinks from '../ArtistLinks.svelte'
  import Icon from '../Icon.svelte'
  import { motionDuration, viewportHeight } from '../motion'
  import { player } from '../player.svelte'
  import { invoke } from '@tauri-apps/api/core'

  let { onClose }: { onClose: () => void } = $props()

  // "Open files": the system picker, after asking for music access. Files
  // without a path on the phone (e.g. from a cloud drive) are skipped.
  let picking = $state(false)
  let note = $state<string | null>(null)
  async function pickFiles(append: boolean) {
    if (picking) return
    picking = true
    note = null
    try {
      const res = await invoke<{ paths: string[]; skipped: number }>('android_pick_audio_files')
      if (res.paths.length > 0) {
        if (append) await player.appendFiles(res.paths)
        else await player.openFiles(res.paths)
      }
      if (res.skipped > 0) {
        note = (
          res.skipped === 1
            ? t('1 file could not be opened: it is not stored on this phone.')
            : t('{n} files could not be opened: they are not stored on this phone.', { n: res.skipped })
        )
      }
    } catch (e) {
      player.error = String(e)
    } finally {
      picking = false
    }
  }

  const current = $derived(player.snapshot.currentIndex)
  const upNext = $derived(
    current === null
      ? player.queue.map((track, i) => ({ track, i }))
      : player.queue.map((track, i) => ({ track, i })).slice(current + 1),
  )
</script>

<div
  class="fixed inset-0 z-50 flex flex-col bg-zinc-950 text-white"
  style:padding-top="var(--inset-top)"
  style:padding-bottom="var(--inset-bottom)"
  transition:fly={{ y: viewportHeight(), duration: motionDuration(220), opacity: 1 }}
  role="dialog"
  aria-modal="true"
  aria-label={t("Queue")}
>
  <header class="flex h-14 shrink-0 items-center px-1">
    <button class="rounded-full p-3 active:bg-white/10" aria-label={t("Close queue")} onclick={onClose}>
      <Icon name="down" class="size-7" />
    </button>
    <h1 class="flex-1 text-base font-semibold">{t("Queue")}</h1>
    {#if player.snapshot.queueLength > 0}
      <button
        type="button"
        class="rounded-full px-3 py-2 text-sm text-zinc-300 active:bg-white/10 disabled:opacity-50"
        disabled={picking}
        onclick={() => void pickFiles(true)}
      >
        {t('Add to queue')}
      </button>
    {/if}
    <button
      type="button"
      class="mr-2 rounded-full px-3 py-2 text-sm font-medium text-accent-400 active:bg-white/10 disabled:opacity-50"
      disabled={picking}
      onclick={() => void pickFiles(false)}
    >
      {t('Open files')}
    </button>
  </header>
  {#if note}
    <p role="status" class="mx-4 mb-2 rounded-lg bg-zinc-800 px-3 py-2 text-sm text-zinc-200">{note}</p>
  {/if}
  <div class="min-h-0 flex-1 overflow-y-auto pb-4">
    {#if current !== null && player.queue[current]}
      <h2 class="px-4 pt-2 pb-1 text-sm font-bold">{t("Now playing")}</h2>
      <div class="flex h-14 items-center px-4">
        <span class="min-w-0">
          <span class="block truncate text-[15px] text-accent-400">{player.queue[current].title}</span>
          <span class="block truncate text-[13px] text-zinc-400">
            {#if player.queue[current].artist}
              <ArtistLinks artist={player.queue[current].artist} linkClass="hover:text-accent-400 active:underline" />
            {/if}
          </span>
        </span>
      </div>
    {/if}
    {#if upNext.length > 0}
      <h2 class="px-4 pt-4 pb-1 text-sm font-bold">{t("Next up")}</h2>
      {#each upNext as { track, i } (track.id)}
        <div class="flex h-14 items-center active:bg-white/5">
          <div
            role="button"
            tabindex="0"
            class="min-w-0 flex-1 px-4 text-left outline-none"
            onclick={() => player.playIndex(i)}
            onkeydown={(e) => e.target === e.currentTarget && e.key === 'Enter' && player.playIndex(i)}
          >
            <span class="block truncate text-[15px]">{track.title}</span>
            <span class="block truncate text-[13px] text-zinc-400">
              {#if track.artist}
                <ArtistLinks artist={track.artist} linkClass="hover:text-accent-400 active:underline" />
              {/if}
            </span>
          </div>
          <button class="p-4 text-zinc-500 active:text-zinc-200" aria-label={t('Remove “{title}” from queue', { title: track.title })} onclick={() => player.removeIndex(i)}>
            <Icon name="close" class="size-5" />
          </button>
        </div>
      {/each}
    {:else}
      <p class="px-4 pt-6 text-sm text-zinc-400">{t("Nothing after this song.")}</p>
    {/if}
  </div>
</div>

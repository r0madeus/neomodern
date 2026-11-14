<script lang="ts">
  // One-click setup of yt-dlp and ffmpeg for online search and download.
  // Rust picks the right build for the OS and CPU, checks it and keeps it
  // in the app's own folder; this only shows the button and the progress.
  import { t } from './i18n.svelte'
  import { online, type ToolName } from './online.svelte'

  let {
    tools,
    label,
    compact = false,
  }: {
    /** What to install; defaults to whatever is missing. */
    tools?: ToolName[]
    label?: string
    compact?: boolean
  } = $props()

  const names: Record<ToolName, string> = { ytdlp: 'yt-dlp', ffmpeg: 'ffmpeg' }

  function mb(bytes: number): string {
    return (bytes / 1_048_576).toFixed(bytes < 10_485_760 ? 1 : 0)
  }

  const p = $derived(online.toolProgress)
  const percent = $derived(p?.total ? Math.min(100, Math.round((p.received / p.total) * 100)) : null)
  const stageText = $derived.by(() => {
    if (!p) return ''
    const name = names[p.tool]
    if (p.stage === 'verify') return t('Checking {name}…', { name })
    if (p.stage === 'extract') return t('Unpacking {name}…', { name })
    if (p.stage === 'done') return t('{name} is ready', { name })
    return p.total
      ? t('Downloading {name}: {got} / {total} MB', { name, got: mb(p.received), total: mb(p.total) })
      : t('Downloading {name}…', { name })
  })
</script>

{#if online.installingTools}
  <div class={['flex min-w-0 flex-col gap-1.5', compact ? 'w-56' : 'w-full max-w-sm']} role="status" aria-live="polite">
    <span class="truncate text-xs text-zinc-600 dark:text-zinc-300">{stageText}</span>
    <div class="h-1.5 overflow-hidden rounded-full bg-zinc-200 dark:bg-zinc-800">
      <div
        class={[
          'h-full rounded-full bg-accent-500 transition-[width] duration-300',
          percent === null && 'w-1/3 animate-pulse',
        ]}
        style:width={percent === null ? undefined : `${percent}%`}
      ></div>
    </div>
  </div>
{:else}
  <div class="flex min-w-0 flex-col gap-1">
    <button
      type="button"
      class="self-start rounded-full bg-accent-500 px-3.5 py-1.5 text-xs font-semibold text-zinc-950 hover:bg-accent-400 disabled:cursor-not-allowed disabled:opacity-50"
      onclick={() => void online.installTools(tools)}
    >
      {label ?? t('Set up automatically')}
    </button>
    {#if online.toolError}
      <span class="text-xs text-red-600 dark:text-red-400">{online.toolError}</span>
    {/if}
  </div>
{/if}

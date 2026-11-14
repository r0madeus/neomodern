<script lang="ts">
  import Icon from './Icon.svelte'
  import { t } from './i18n.svelte'
  import { online, type DownloadJob, type OnlineTrack } from './online.svelte'

  let {
    track,
    job,
    disabled,
  }: {
    track: OnlineTrack
    job: DownloadJob | null
    disabled: boolean
  } = $props()

  const busy = $derived(job?.state === 'queued' || job?.state === 'downloading')

  const statusTitle = $derived.by(() => {
    if (job?.state === 'failed') return job.error || t('Retry')
    if (job?.state === 'done') return t('Downloaded')
    if (job?.state === 'downloading') return t('Downloading…')
    if (job?.state === 'queued') return t('Queued')
    return t('Download track')
  })
</script>

<button
  type="button"
  disabled={disabled || busy}
  title={statusTitle}
  aria-label={t('Download “{title}”', { title: track.title })}
  class={[
    'flex size-8 shrink-0 items-center justify-center rounded-full transition disabled:cursor-not-allowed disabled:opacity-50',
    job?.state === 'done'
      ? 'bg-accent-500/15 text-accent-700 dark:text-accent-300'
      : job?.state === 'failed'
        ? 'bg-red-500/15 text-red-600 hover:bg-red-500/25 dark:text-red-400'
        : 'text-zinc-500 hover:bg-zinc-200/70 hover:text-zinc-900 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100',
  ]}
  onclick={() => void online.downloadTrack(track)}
>
  {#if job?.state === 'done'}
    <Icon name="check" class="size-4" />
  {:else if job?.state === 'downloading'}
    <Icon name="download" class="size-4 animate-pulse" />
  {:else}
    <Icon name="download" class="size-4" />
  {/if}
</button>

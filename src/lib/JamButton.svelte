<script lang="ts">
  import Icon from './Icon.svelte'
  import { count, t } from './i18n.svelte'
  import { jam } from './jam.svelte'

  // "Start a Jam" in the right panel's header (docs/JAM.md, "Flow"). Only
  // while the Jam switch is on; a running Jam shows its guest count and
  // opens the Jam window. Short ("Jam") so the panel's tabs keep one line;
  // `iconOnly`: the Now Playing header.
  let { iconOnly = false, class: className = '' }: { iconOnly?: boolean; class?: string } = $props()

  const running = $derived(jam.status?.running === true)
  const guests = $derived(jam.status?.guests.length ?? 0)
  const label = $derived(running ? count(guests, 'Jam: {n} guest', 'Jam: {n} guests') : t('Start a Jam'))
</script>

{#if jam.hostEnabled}
  {#if iconOnly}
    <button
      type="button"
      class={[
        'relative rounded-full p-1.5 outline-none transition focus-visible:ring-2 focus-visible:ring-accent-500',
        running
          ? 'text-accent-600 hover:bg-accent-500/15 dark:text-accent-400'
          : 'text-zinc-500 hover:bg-zinc-200/80 hover:text-zinc-900 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100',
        className,
      ]}
      aria-label={label}
      title={label}
      onclick={() => void jam.start()}
    >
      <Icon name="jam" class="size-4" />
      {#if running}
        <span class="absolute top-1 right-1 size-1.5 rounded-full bg-emerald-500"></span>
      {/if}
    </button>
  {:else}
    <button
      type="button"
      class={[
        'flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-semibold outline-none transition focus-visible:ring-2 focus-visible:ring-accent-500 disabled:opacity-50',
        running
          ? 'bg-accent-500/15 text-accent-700 hover:bg-accent-500/25 dark:text-accent-300'
          : 'border border-zinc-300 text-zinc-700 hover:bg-zinc-200/80 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800',
        className,
      ]}
      title={label}
      aria-label={label}
      disabled={jam.busy === 'start'}
      onclick={() => void jam.start()}
    >
      {#if running}
        <span class="size-1.5 rounded-full bg-emerald-500" aria-hidden="true"></span>
        {t('Jam')}
        <span class="tabular-nums font-medium opacity-80">· {guests}</span>
      {:else}
        <Icon name="jam" class="size-3.5" />
        {t('Jam')}
      {/if}
    </button>
  {/if}
{/if}

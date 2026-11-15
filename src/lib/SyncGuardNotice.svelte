<script lang="ts">
  import Icon from './Icon.svelte'
  import { t } from './i18n.svelte'
  import { sync, type PeerStatus } from './sync.svelte'
  import { guardLines, type GuardSummary } from './syncLogic'

  // The mass-delete guard stopped a sync from `peer`: say what it would
  // remove here and ask "Apply" or "Keep my data" (docs/SYNC.md).
  let { peer, guard }: { peer: PeerStatus; guard: GuardSummary } = $props()

  const lines = $derived(guardLines(guard, t))
  const busy = $derived(sync.busy === 'guard')
</script>

<div
  class="rounded-xl border border-amber-500/40 bg-amber-500/10 p-3.5 text-amber-900 dark:text-amber-100"
  role="alert"
>
  <p class="flex items-start gap-2 text-sm font-semibold">
    <Icon name="info" class="mt-0.5 size-4 shrink-0 text-amber-600 dark:text-amber-400" />
    <span>{t('{device} wants to make big deletions here:', { device: peer.name })}</span>
  </p>
  <ul class="mt-1.5 list-disc space-y-0.5 pl-11 text-xs leading-relaxed">
    {#each lines as line, i (i)}
      <li>{line}</li>
    {/each}
  </ul>
  <p class="mt-2 pl-6 text-xs text-amber-800/80 dark:text-amber-200/70">
    {t('Nothing was changed yet. Keep your data if this was not on purpose.')}
  </p>
  <div class="mt-3 flex flex-wrap gap-2 pl-6">
    <button
      type="button"
      class="rounded-full bg-accent-600 px-3.5 py-1.5 text-xs font-semibold text-white transition hover:bg-accent-500 disabled:opacity-50 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400"
      disabled={busy}
      onclick={() => void sync.guardDecide(peer.id, false)}
    >
      {t('Keep my data')}
    </button>
    <button
      type="button"
      class="rounded-full border border-red-500/50 px-3.5 py-1.5 text-xs font-semibold text-red-700 transition hover:bg-red-500/10 disabled:opacity-50 dark:text-red-300"
      disabled={busy}
      onclick={() => void sync.guardDecide(peer.id, true)}
    >
      {t('Apply')}
    </button>
  </div>
</div>

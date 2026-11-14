<script lang="ts">
  import PageHeader from './PageHeader.svelte'
  import StatsView from '../StatsView.svelte'
  import { t } from '../i18n.svelte'

  let {
    onBack,
    onOpenAlbum,
  }: {
    onBack: () => void
    onOpenAlbum: (albumId: number) => void
  } = $props()
</script>

<div class="absolute inset-0 flex flex-col overflow-x-hidden bg-zinc-950">
  <PageHeader title={t('Listening stats')} {onBack} />
  <div class="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto pt-2 pb-[var(--mobile-bar-clear,5rem)]">
    <StatsView {onOpenAlbum} />
  </div>
</div>

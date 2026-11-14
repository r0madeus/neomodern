<script lang="ts">
  import { t } from './i18n.svelte'
  import Icon from './Icon.svelte'
  import { player } from './player.svelte'

  let {
    disabled = false,
    onClick,
  }: {
    disabled?: boolean
    onClick: () => void
  } = $props()
</script>

<button
  type="button"
  {disabled}
  aria-label={t('Shuffle play')}
  title={t('Shuffle play')}
  class={[
    'relative flex items-center justify-center rounded-full p-2.5 transition outline-none focus-visible:ring-2 focus-visible:ring-accent-400 disabled:cursor-not-allowed disabled:opacity-40',
    player.snapshot.shuffle
      ? 'text-accent-400 hover:bg-white/15'
      : 'text-white/80 hover:bg-white/15 hover:text-white',
  ]}
  onclick={onClick}
>
  <Icon name="shuffle" class="size-5" />
  {#if player.snapshot.shuffle}
    <span aria-hidden="true" class="absolute bottom-0.5 size-1 rounded-full bg-accent-400"></span>
  {/if}
</button>

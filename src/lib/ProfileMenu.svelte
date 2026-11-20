<script lang="ts">
  import { fade } from 'svelte/transition'
  import Icon from './Icon.svelte'
  import { t } from './i18n.svelte'
  import { motionDuration } from './motion'
  import ProfileAvatar from './ProfileAvatar.svelte'
  import ProfilesModal from './ProfilesModal.svelte'
  import PinPrompt from './PinPrompt.svelte'
  import { profiles, type Profile } from './profiles.svelte'

  // The profile button (K24): who is listening, switch, add, manage.
  // `row` is the desktop sidebar's user row (avatar, name, chevron; only the
  // avatar when the sidebar is collapsed) whose menu opens upwards.
  let {
    size = 'size-7 text-xs',
    align = 'left',
    variant = 'avatar',
    collapsed = false,
  }: { size?: string; align?: 'left' | 'right'; variant?: 'avatar' | 'row'; collapsed?: boolean } = $props()
  const row = $derived(variant === 'row')

  let open = $state(false)
  // A profile with a PIN asks for it first.
  let asking = $state<Profile | null>(null)

  async function choose(p: Profile) {
    open = false
    if (p.hasPin) asking = p
    else {
      const err = await profiles.switchTo(p.id)
      if (err) profiles.error = err
    }
  }
  let managing = $state(false)
  let root = $state<HTMLDivElement | null>(null)

  function onWindowPointer(e: PointerEvent) {
    if (open && root && !root.contains(e.target as Node)) open = false
  }

  function manage() {
    open = false
    managing = true
  }
</script>

<svelte:window onpointerdown={onWindowPointer} onkeydown={(e) => open && e.key === 'Escape' && (open = false)} />

{#if profiles.current}
  <div class="relative" bind:this={root}>
    <button
      type="button"
      class={[
        'outline-none focus-visible:ring-2 focus-visible:ring-accent-500',
        row && 'flex w-full items-center rounded-lg px-2 py-1.5 text-sm text-zinc-600 transition-colors hover:bg-zinc-200/70 dark:text-zinc-300 dark:hover:bg-zinc-800/70',
        row && (collapsed ? 'justify-center' : 'gap-2.5 text-left'),
        !row && 'rounded-full',
      ]}
      aria-haspopup="menu"
      aria-expanded={open}
      aria-label={t('Profile: {name}', { name: profiles.current.name })}
      title={profiles.current.name}
      onclick={() => (open = !open)}
    >
      <ProfileAvatar profile={profiles.current} class={row ? 'size-[22px] text-[11px]' : size} />
      {#if row && !collapsed}
        <span class="min-w-0 flex-1 truncate font-medium">{profiles.current.name}</span>
        <Icon name="chevronRight" class="size-4 shrink-0 opacity-60 transition-transform {open ? 'rotate-90' : '-rotate-90'}" />
      {/if}
    </button>
    {#if open}
      <div
        transition:fade={{ duration: motionDuration(100) }}
        class={[
          'absolute z-50 rounded-xl border border-zinc-200 bg-white p-1.5 shadow-xl dark:border-zinc-800 dark:bg-zinc-900',
          row ? 'bottom-full left-0 mb-2 w-60' : 'top-full mt-2 w-60',
          !row && (align === 'left' ? 'left-0' : 'right-0'),
        ]}
        role="menu"
      >
        <p class="px-2.5 pt-1.5 pb-1 text-[11px] font-semibold tracking-wide text-zinc-400 uppercase">{t('Profiles')}</p>
        {#each profiles.state?.profiles ?? [] as p (p.id)}
          {@const active = p.id === profiles.state?.active}
          <button
            type="button"
            role="menuitemradio"
            aria-checked={active}
            disabled={profiles.switching}
            class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left text-sm hover:bg-zinc-100 disabled:opacity-60 dark:hover:bg-zinc-800"
            onclick={() => (active ? (open = false) : void choose(p))}
          >
            <ProfileAvatar profile={p} class="size-7 text-xs" />
            <span class="min-w-0 flex-1 truncate font-medium">{p.name}</span>
            {#if p.hasPin && !active}
              <span class="text-[11px] text-zinc-400" title={t('Has a PIN')}>🔒</span>
            {/if}
            {#if active}
              <Icon name="check" class="size-4 text-accent-500" />
            {/if}
          </button>
        {/each}
        <div class="my-1 border-t border-zinc-200 dark:border-zinc-800"></div>
        <button
          type="button"
          role="menuitem"
          class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left text-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
          onclick={manage}
        >
          <span class="flex size-7 items-center justify-center rounded-full bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
            <Icon name="settings" class="size-4" />
          </span>
          {t('Manage profiles')}
        </button>
        {#if profiles.error}
          <p class="px-2.5 py-1 text-xs text-red-600 dark:text-red-400" role="alert">{profiles.error}</p>
        {/if}
      </div>
    {/if}
  </div>
  {#if asking}
    <PinPrompt
      title={t('PIN for {name}', { name: asking.name })}
      profile={asking}
      onSubmit={(pin) => profiles.switchTo(asking!.id, pin)}
      onClose={() => (asking = null)}
    />
  {/if}
  {#if managing}
    <ProfilesModal onClose={() => (managing = false)} />
  {/if}
{/if}

<script lang="ts">
  import { t } from './i18n.svelte'
  import Logo from './Logo.svelte'
  import PinPrompt from './PinPrompt.svelte'
  import ProfileAvatar from './ProfileAvatar.svelte'
  import { profiles, type Profile } from './profiles.svelte'

  // The app opened on a profile with a PIN (K25): nothing of it shows until
  // the PIN is entered or another profile is chosen.
  let asking = $state<Profile | null>(null)

  async function choose(p: Profile) {
    if (p.hasPin) asking = p
    else {
      const err = await profiles.switchTo(p.id)
      if (err) profiles.error = err
    }
  }
</script>

<div class="fixed inset-0 z-[110] flex flex-col items-center justify-center gap-8 bg-zinc-50 px-6 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
  <span class="flex size-10 items-center justify-center rounded-xl bg-gradient-to-br from-accent-400 to-accent-700 text-white shadow-xs">
    <Logo class="size-5" />
  </span>
  <h1 class="text-xl font-bold">{t('Who is listening?')}</h1>
  <ul class="flex max-w-xl flex-wrap justify-center gap-6">
    {#each profiles.state?.profiles ?? [] as p (p.id)}
      <li>
        <button type="button" class="group flex w-24 flex-col items-center gap-2 outline-none" onclick={() => void choose(p)}>
          <ProfileAvatar profile={p} class="size-20 text-3xl ring-accent-500 ring-offset-2 ring-offset-zinc-50 transition group-hover:ring-2 group-focus-visible:ring-2 dark:ring-offset-zinc-950" />
          <span class="max-w-full truncate text-sm font-medium">{p.name}</span>
          {#if p.hasPin}<span class="-mt-1.5 text-[11px] text-zinc-400">🔒</span>{/if}
        </button>
      </li>
    {/each}
  </ul>
  {#if profiles.error}
    <p class="text-xs text-red-600 dark:text-red-400" role="alert">{profiles.error}</p>
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

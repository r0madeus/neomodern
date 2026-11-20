<script lang="ts">
  import { fade, scale } from 'svelte/transition'
  import Icon from './Icon.svelte'
  import { t } from './i18n.svelte'
  import { motionDuration } from './motion'
  import ProfileAvatar from './ProfileAvatar.svelte'
  import { profiles, type Profile, type ProfileSummary } from './profiles.svelte'

  // Manage profiles (K24): add, rename, colour, delete.
  let { onClose }: { onClose: () => void } = $props()

  const list = $derived(profiles.state?.profiles ?? [])
  const full = $derived(list.length >= (profiles.state?.maxProfiles ?? 8))

  let newName = $state('')
  let drafts = $state<Record<number, string>>({})
  let confirming = $state<{ profile: Profile; summary: ProfileSummary } | null>(null)
  let busy = $state(false)

  async function add(e: SubmitEvent) {
    e.preventDefault()
    const name = newName.trim()
    if (!name || busy) return
    busy = true
    if (await profiles.create(name)) newName = ''
    busy = false
  }

  async function saveName(p: Profile) {
    const draft = drafts[p.id]
    if (draft === undefined) return
    const name = draft.trim()
    if (name && name !== p.name) await profiles.rename(p.id, name)
    delete drafts[p.id]
  }

  async function askDelete(p: Profile) {
    try {
      confirming = { profile: p, summary: await profiles.summary(p.id) }
    } catch (e) {
      profiles.error = String(e)
    }
  }

  async function confirmDelete() {
    if (!confirming || busy) return
    busy = true
    await profiles.remove(confirming.profile.id)
    confirming = null
    busy = false
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (confirming ? (confirming = null) : onClose())} />

<div
  transition:fade={{ duration: motionDuration(150) }}
  class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 backdrop-blur-xs"
  role="dialog"
  aria-modal="true"
  aria-labelledby="profiles-title"
>
  <div
    transition:scale={{ start: 0.96, duration: motionDuration(180) }}
    class="flex max-h-full w-full max-w-md flex-col rounded-2xl border border-zinc-200 bg-white p-5 shadow-2xl dark:border-zinc-800 dark:bg-zinc-900"
  >
    <div class="mb-1 flex items-center justify-between gap-3">
      <h3 id="profiles-title" class="text-base font-semibold">{t('Profiles')}</h3>
      <button
        type="button"
        aria-label={t('Close')}
        class="rounded-lg p-1 text-zinc-400 hover:bg-zinc-100 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200"
        onclick={onClose}
      >
        <Icon name="close" class="size-4" />
      </button>
    </div>
    <p class="mb-4 text-xs text-zinc-500 dark:text-zinc-400">
      {t('Each profile has its own favourites, playlists, listening history, statistics, pins and queue. The music library and settings are shared. Anyone using this device can switch profiles; there is no password.')}
    </p>

    <ul class="-mx-1 flex min-h-0 flex-col gap-3 overflow-y-auto px-1">
      {#each list as p (p.id)}
        {@const active = p.id === profiles.state?.active}
        <li class="rounded-xl border border-zinc-200 p-3 dark:border-zinc-800">
          <div class="flex items-center gap-3">
            <ProfileAvatar profile={p} class="size-9 text-sm" />
            <input
              class="min-w-0 flex-1 rounded-lg border border-transparent bg-transparent px-2 py-1 text-sm font-medium hover:border-zinc-200 focus:border-accent-500 focus:outline-none dark:hover:border-zinc-700"
              aria-label={t('Profile name')}
              maxlength="40"
              value={drafts[p.id] ?? p.name}
              oninput={(e) => (drafts[p.id] = e.currentTarget.value)}
              onblur={() => void saveName(p)}
              onkeydown={(e) => e.key === 'Enter' && e.currentTarget.blur()}
            />
            {#if active}
              <span class="shrink-0 rounded-full bg-accent-100 px-2 py-0.5 text-[11px] font-semibold text-accent-700 dark:bg-accent-950 dark:text-accent-300">
                {t('In use')}
              </span>
            {:else}
              <button
                type="button"
                class="shrink-0 rounded-lg p-1.5 text-zinc-400 hover:bg-red-50 hover:text-red-600 dark:hover:bg-red-950/40 dark:hover:text-red-400"
                aria-label={t('Delete profile {name}', { name: p.name })}
                onclick={() => void askDelete(p)}
              >
                <Icon name="trash" class="size-4" />
              </button>
            {/if}
          </div>
          <div class="mt-2.5 flex flex-wrap gap-2 pl-12">
            {#each profiles.state?.colors ?? [] as c (c)}
              <button
                type="button"
                class={[
                  'size-6 rounded-full transition',
                  p.color === c ? 'ring-2 ring-accent-500 ring-offset-2 ring-offset-white dark:ring-offset-zinc-900' : 'opacity-80 hover:opacity-100',
                ]}
                style:background={c}
                aria-label={t('Colour')}
                aria-pressed={p.color === c}
                onclick={() => void profiles.setColor(p.id, c)}
              ></button>
            {/each}
          </div>
        </li>
      {/each}
    </ul>

    <form class="mt-4 flex gap-2" onsubmit={add}>
      <input
        class="min-w-0 flex-1 rounded-lg border border-zinc-200 bg-white px-3 py-1.5 text-sm focus:border-accent-500 focus:outline-none disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-950"
        placeholder={full ? t('Up to {n} profiles', { n: profiles.state?.maxProfiles ?? 8 }) : t('New profile name')}
        aria-label={t('New profile name')}
        maxlength="40"
        disabled={full}
        bind:value={newName}
      />
      <button
        type="submit"
        class="shrink-0 rounded-full bg-accent-600 px-4 py-1.5 text-xs font-semibold text-white transition hover:bg-accent-500 disabled:opacity-50 dark:bg-accent-500 dark:text-zinc-950 dark:hover:bg-accent-400"
        disabled={full || busy || newName.trim() === ''}
      >
        {t('Add profile')}
      </button>
    </form>
    {#if profiles.error}
      <p class="mt-2 text-xs text-red-600 dark:text-red-400" role="alert">{profiles.error}</p>
    {/if}

    {#if confirming}
      <div class="mt-4 rounded-xl border border-red-200 bg-red-50 p-3 text-sm dark:border-red-900/60 dark:bg-red-950/30" role="alertdialog" aria-labelledby="profile-delete-title">
        <p id="profile-delete-title" class="font-semibold">{t('Delete “{name}”?', { name: confirming.profile.name })}</p>
        <p class="mt-1 text-xs text-zinc-600 dark:text-zinc-300">
          {t('This removes its {favorites} favourites, {playlists} playlists and {listens} listens from this device. Music files are not touched.', {
            favorites: confirming.summary.favorites,
            playlists: confirming.summary.playlists,
            listens: confirming.summary.listens,
          })}
        </p>
        <div class="mt-3 flex justify-end gap-2">
          <button type="button" class="rounded-full px-3 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800" onclick={() => (confirming = null)}>
            {t('Cancel')}
          </button>
          <button
            type="button"
            class="rounded-full bg-red-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-red-500 disabled:opacity-50"
            disabled={busy}
            onclick={() => void confirmDelete()}
          >
            {t('Delete profile')}
          </button>
        </div>
      </div>
    {/if}
  </div>
</div>

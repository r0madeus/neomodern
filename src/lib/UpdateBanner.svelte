<script lang="ts">
  import { appSettings } from './appSettings.svelte'
  import { t } from './i18n.svelte'
  import Icon from './Icon.svelte'
  import { updates } from './updates.svelte'

  // Android arm64, the Windows installer and the Linux AppImage install from
  // inside the app; anything else opens the release page.
  const inApp = $derived(updates.available?.installable === true)
  // Until the first bytes arrive there is nothing to measure: the bar sweeps
  // (and the text says so) instead of showing an empty or frozen stub.
  const percent = $derived(
    updates.progress === null || updates.progress <= 0 ? null : Math.round(updates.progress * 100),
  )
</script>

{#if updates.available && appSettings.allowUpdates}
  <div
    role="status"
    class="flex flex-col gap-1 rounded-lg bg-accent-600 px-3 py-2 text-sm text-white shadow-sm dark:bg-accent-700"
  >
    <div class="flex items-center gap-3">
      <span class="min-w-0 flex-1">
        {#if updates.installing}
          {percent === null ? t('Preparing the download…') : t('Downloading the update… {p}%', { p: percent })}
        {:else}
          {t('NeoModern {v} is available.', { v: updates.available.version })}
        {/if}
      </span>
      {#if inApp}
        <button
          class="shrink-0 rounded-md bg-white/15 px-2.5 py-1 font-medium hover:bg-white/25 disabled:opacity-60"
          disabled={updates.installing}
          onclick={() => void updates.install()}
        >
          {t('Update')}
        </button>
      {:else}
        <button class="shrink-0 rounded-md bg-white/15 px-2.5 py-1 font-medium hover:bg-white/25" onclick={() => void updates.open()}>
          {t("Download")}
        </button>
      {/if}
      {#if !updates.installing}
        <button class="-mr-1 shrink-0 rounded-md p-1 hover:bg-white/15" aria-label={t("Dismiss")} onclick={() => updates.dismiss()}>
          <Icon name="close" class="size-4" />
        </button>
      {/if}
    </div>
    {#if updates.installing}
      <div class={['relative h-1 overflow-hidden rounded-full bg-white/20 text-white', percent === null && 'bar-indeterminate']}>
        {#if percent !== null}
          <div class="h-full rounded-full bg-white transition-[width] duration-300" style:width="{percent}%"></div>
        {/if}
      </div>
    {/if}
    {#if updates.installError}
      <span class="text-xs text-white/90" role="alert">{t(updates.installError)}</span>
    {/if}
  </div>
{/if}

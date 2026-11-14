<script lang="ts">
  // Ten-band equalizer (decision K16). Rust applies it: mpv on desktop, the
  // system equalizer on Android. Slider moves are sent at most every 120 ms.
  import ToggleSwitch from './ToggleSwitch.svelte'
  import { t } from './i18n.svelte'
  import { EQ_BANDS, EQ_MAX_DB, player, type Equalizer } from './player.svelte'

  interface Preset {
    label: string
    preampDb: number
    gainsDb: number[]
  }

  const PRESETS: Preset[] = [
    { label: 'Flat', preampDb: 0, gainsDb: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
    { label: 'Bass boost', preampDb: -4, gainsDb: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0] },
    { label: 'Treble boost', preampDb: -4, gainsDb: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6] },
    { label: 'Vocal', preampDb: -2, gainsDb: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1] },
    { label: 'Rock', preampDb: -3, gainsDb: [4, 3, 2, 0, -1, -1, 1, 3, 4, 4] },
    { label: 'Pop', preampDb: -2, gainsDb: [-1, 0, 2, 3, 4, 3, 1, 0, -1, -1] },
    { label: 'Jazz', preampDb: -2, gainsDb: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3] },
    { label: 'Classical', preampDb: -3, gainsDb: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4] },
    { label: 'Electronic', preampDb: -4, gainsDb: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5] },
    { label: 'Acoustic', preampDb: -2, gainsDb: [3, 2, 1, 1, 2, 2, 3, 2, 2, 1] },
  ]

  // Local copy while dragging; follows the player otherwise.
  let draft = $state<Equalizer | null>(null)
  const eq = $derived(draft ?? player.snapshot.equalizer)
  const activePreset = $derived(
    PRESETS.find(
      (p) => p.preampDb === eq.preampDb && p.gainsDb.every((g, i) => g === eq.gainsDb[i]),
    )?.label ?? null,
  )

  let timer: ReturnType<typeof setTimeout> | null = null
  let pending: Equalizer | null = null

  function send(next: Equalizer, now = false) {
    draft = next
    pending = next
    if (timer !== null && !now) return
    if (timer !== null) clearTimeout(timer)
    const flush = () => {
      timer = null
      const value = pending
      pending = null
      if (!value) return
      void player.setEqualizer(value).finally(() => {
        if (pending === null && timer === null) draft = null
      })
    }
    if (now) flush()
    else timer = setTimeout(flush, 120)
  }

  function setBand(i: number, db: number) {
    const gainsDb = [...eq.gainsDb]
    gainsDb[i] = db
    send({ ...eq, enabled: true, gainsDb })
  }

  function label(hz: number): string {
    return hz >= 1000 ? `${hz / 1000}k` : String(hz)
  }

  function db(v: number): string {
    return `${v > 0 ? '+' : ''}${v.toFixed(v % 1 === 0 ? 0 : 1)} dB`
  }

  const chip = (on: boolean) =>
    [
      'rounded-full px-3 py-1 text-xs font-medium transition',
      on
        ? 'bg-accent-500 text-zinc-950'
        : 'bg-zinc-100 text-zinc-600 hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-700',
    ]
</script>

<div class="flex flex-col gap-4">
  <div class="flex items-start justify-between gap-6">
    <div class="min-w-0">
      <p id="eq-label" class="text-sm font-medium">{t('Equalizer')}</p>
      <p id="eq-help" class="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">
        {t('Ten bands from 31 Hz to 16 kHz. Lower the preamp when you boost, so loud parts do not distort.')}
      </p>
    </div>
    <ToggleSwitch
      ariaLabelledby="eq-label"
      ariaDescribedby="eq-help"
      bind:checked={() => eq.enabled, (next) => send({ ...eq, enabled: next }, true)}
    />
  </div>

  <div class="flex flex-wrap gap-1.5" role="group" aria-label={t('Presets')}>
    {#each PRESETS as p (p.label)}
      <button
        type="button"
        class={chip(eq.enabled && activePreset === p.label)}
        aria-pressed={eq.enabled && activePreset === p.label}
        onclick={() => send({ enabled: true, preampDb: p.preampDb, gainsDb: [...p.gainsDb] }, true)}
      >
        {t(p.label)}
      </button>
    {/each}
  </div>

  <div class={['grid gap-x-4 gap-y-1.5 sm:grid-cols-2', !eq.enabled && 'opacity-50']}>
    <label class="flex items-center gap-3 text-xs sm:col-span-2">
      <span class="w-14 shrink-0 font-medium">{t('Preamp')}</span>
      <input
        type="range"
        min={-EQ_MAX_DB}
        max={EQ_MAX_DB}
        step="0.5"
        value={eq.preampDb}
        class="min-w-0 flex-1 accent-accent-500"
        oninput={(e) => send({ ...eq, enabled: true, preampDb: Number(e.currentTarget.value) })}
        onchange={(e) => send({ ...eq, enabled: true, preampDb: Number(e.currentTarget.value) }, true)}
      />
      <span class="w-14 shrink-0 text-right tabular-nums text-zinc-500">{db(eq.preampDb)}</span>
    </label>
    {#each EQ_BANDS as hz, i (hz)}
      <label class="flex items-center gap-3 text-xs">
        <span class="w-14 shrink-0 tabular-nums text-zinc-500">{label(hz)} Hz</span>
        <input
          type="range"
          min={-EQ_MAX_DB}
          max={EQ_MAX_DB}
          step="0.5"
          value={eq.gainsDb[i]}
          class="min-w-0 flex-1 accent-accent-500"
          aria-label={t('{hz} Hz band', { hz: label(hz) })}
          oninput={(e) => setBand(i, Number(e.currentTarget.value))}
          onchange={(e) => {
            setBand(i, Number(e.currentTarget.value))
            send(draft ?? eq, true)
          }}
        />
        <span class="w-14 shrink-0 text-right tabular-nums text-zinc-500">{db(eq.gainsDb[i])}</span>
      </label>
    {/each}
  </div>
</div>

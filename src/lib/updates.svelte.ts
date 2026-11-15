// "New version available" notice. Rust asks GitHub for the latest release;
// the UI checks at start-up and every few hours while it stays open (at
// most once per interval) and remembers a dismissed version.
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { appSettings } from './appSettings.svelte'

export interface UpdateInfo {
  version: string
  url: string
  /** Android arm64: can be downloaded and installed from inside the app. */
  installable: boolean
}

interface DownloadProgress {
  received: number
  total: number | null
}

const LAST_CHECK = 'neomodern.update.lastCheck'
const DISMISSED = 'neomodern.update.dismissed'
const INTERVAL_MS = 6 * 60 * 60 * 1000

function read(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

function write(key: string, value: string): void {
  try {
    localStorage.setItem(key, value)
  } catch {
    // ignore
  }
}

class Updates {
  /** Newer release, unless the user dismissed this version. */
  available = $state<UpdateInfo | null>(null)
  checking = $state(false)
  /** Result of the last manual check, for Settings. */
  status = $state<'idle' | 'upToDate' | 'found' | 'failed' | 'disabled'>('idle')
  /** In-app install (Android): downloading, with progress 0..1 if known. */
  installing = $state(false)
  progress = $state<number | null>(null)
  installError = $state<string | null>(null)
  #listening = false

  async check(manual = false): Promise<void> {
    if (this.checking) return
    // Rust refuses the request too; this only avoids a pointless call.
    if (!appSettings.allowUpdates) {
      this.status = 'disabled'
      this.available = null
      return
    }
    this.checking = true
    try {
      const found = await invoke<UpdateInfo | null>('app_check_update')
      if (!found || found.installable) {
        write(LAST_CHECK, String(Date.now()))
      }
      this.status = found ? 'found' : 'upToDate'
      this.available = found && (manual || read(DISMISSED) !== found.version) ? found : null
    } catch {
      this.status = 'failed'
    } finally {
      this.checking = false
    }
  }

  #timer: ReturnType<typeof setInterval> | null = null

  /** Start-up: check now if the last check is older than the interval, and
   *  keep checking while the app stays open (it can run for days). */
  autoCheck(): void {
    const due = () => {
      const last = Number(read(LAST_CHECK) ?? 0)
      if (Date.now() - last > INTERVAL_MS) void this.check()
    }
    due()
    if (this.#timer === null) this.#timer = setInterval(due, 30 * 60 * 1000)
  }

  dismiss(): void {
    if (this.available) write(DISMISSED, this.available.version)
    this.available = null
  }

  /**
   * Android: downloads the APK, checks it in Rust and opens the system
   * installer, which asks the user to confirm.
   */
  async install(): Promise<void> {
    if (!this.available?.installable || this.installing) return
    if (!this.#listening) {
      this.#listening = true
      await listen<DownloadProgress>('update://progress', (e) => {
        const { received, total } = e.payload
        this.progress = total ? Math.min(1, received / total) : null
      })
    }
    this.installing = true
    this.installError = null
    this.progress = null
    try {
      await invoke('app_install_update')
    } catch (e) {
      this.installError = String(e)
    } finally {
      this.installing = false
    }
  }

  async open(): Promise<void> {
    if (!this.available) return
    try {
      await invoke('app_open_release', { url: this.available.url })
    } catch {
      // nothing useful to show; the banner stays
    }
  }
}

export const updates = new Updates()

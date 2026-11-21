// Backup, restore and automatic folder backups (docs/BACKUP.md, K28).
// All file work happens in Rust; this store only sends commands and mirrors
// the small status objects the backend returns.

import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { open, save } from '@tauri-apps/plugin-dialog'
import { appSettings } from './appSettings.svelte'
import { t } from './i18n.svelte'
import { BACKUP_EXT, DEFAULT_KEEP, defaultBackupName, type BackupInterval } from './backupLogic'

/** What a backup file holds, read by `backup_inspect` before importing. */
export interface BackupSummary {
  /** UTC time the backup was made (unix seconds or ISO 8601). */
  createdAt: number | string
  appVersion: string
  platform?: string | null
  profiles: number
  tracks: number
  playlists: number
  favorites: number
}

export interface BackupSettings {
  enabled: boolean
  folder: string | null
  interval: BackupInterval
  keep: number
}

/** The automatic backup's state (`backup_status`, event `backup://status`). */
export interface BackupStatus {
  running: boolean
  /** When the last automatic backup finished (unix seconds or ISO 8601). */
  lastAt: number | string | null
  lastSize: number | null
  lastError: string | null
}

const DEFAULT_SETTINGS: BackupSettings = { enabled: false, folder: null, interval: 'weekly', keep: DEFAULT_KEEP }
const IDLE: BackupStatus = { running: false, lastAt: null, lastSize: null, lastError: null }

class BackupStore {
  settings = $state<BackupSettings>({ ...DEFAULT_SETTINGS })
  status = $state<BackupStatus>({ ...IDLE })
  loaded = $state(false)
  #listening = false

  /** Automatic backups exist on the computer only (docs/BACKUP.md §3). */
  get automaticAvailable(): boolean {
    return appSettings.platform !== 'android'
  }

  async load(): Promise<void> {
    if (!this.automaticAvailable) return
    if (!this.#listening) {
      this.#listening = true
      await listen<BackupStatus>('backup://status', (e) => (this.status = e.payload))
    }
    const [settings, status] = await Promise.all([
      invoke<BackupSettings>('backup_settings'),
      invoke<BackupStatus>('backup_status'),
    ])
    this.settings = settings
    this.status = status
    this.loaded = true
  }

  async setSettings(patch: Partial<BackupSettings>): Promise<void> {
    const next = { ...this.settings, ...patch }
    this.settings = await invoke<BackupSettings>('backup_set_settings', { settings: next })
  }

  /** Picks the folder for automatic backups; false when cancelled. */
  async pickFolder(): Promise<boolean> {
    const picked = await open({ directory: true, multiple: false, title: t('Choose backup folder') })
    if (typeof picked !== 'string') return false
    await this.setSettings({ folder: picked })
    return true
  }

  async backupNow(): Promise<void> {
    this.status = await invoke<BackupStatus>('backup_now')
  }

  /**
   * Writes a backup to a place the user picks. Returns the written path, or
   * null when the user cancelled. Android: the system "create document"
   * picker, opened by the backend when no path is given.
   */
  async exportFile(): Promise<string | null> {
    const name = defaultBackupName()
    if (appSettings.platform === 'android') {
      return invoke<string | null>('backup_export', { path: null, name })
    }
    const path = await save({
      title: t('Export backup'),
      defaultPath: name,
      filters: [{ name: t('NeoModern backup'), extensions: [BACKUP_EXT] }],
    })
    if (!path) return null
    return invoke<string | null>('backup_export', { path, name })
  }

  /** Lets the user pick a backup file; its path, or null when cancelled. */
  async pickImportFile(): Promise<string | null> {
    if (appSettings.platform === 'android') {
      return invoke<string | null>('android_pick_file')
    }
    const picked = await open({
      multiple: false,
      directory: false,
      title: t('Import backup'),
      filters: [{ name: t('NeoModern backup'), extensions: [BACKUP_EXT] }],
    })
    return typeof picked === 'string' ? picked : null
  }

  /** Validates a backup file and says what it holds; nothing is changed. */
  inspect(path: string): Promise<BackupSummary> {
    return invoke<BackupSummary>('backup_inspect', { path })
  }

  /** Stages the backup; it replaces the data when the app restarts. */
  async importFile(path: string): Promise<void> {
    await invoke('backup_import', { path })
  }

  restart(): Promise<void> {
    return invoke('app_restart')
  }
}

export const backup = new BackupStore()

// Pure helpers of the backup UI (docs/BACKUP.md). No Svelte and no Tauri
// here, so `node --test` can check them (tests/backupLogic.test.ts).

/** How often the automatic backup runs. */
export type BackupInterval = 'daily' | 'weekly'
/** How many automatic backups are kept. */
export const KEEP_CHOICES = [3, 5, 10] as const
export const DEFAULT_KEEP = 5

/** Extension of a backup file (a zip). */
export const BACKUP_EXT = 'nmbackup'

const pad = (n: number) => String(n).padStart(2, '0')

/**
 * Default export name, `NeoModern-backup-<yyyy-mm-dd-hhmm>.nmbackup`, in the
 * local time of `date`.
 */
export function defaultBackupName(date: Date = new Date()): string {
  const stamp =
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `-${pad(date.getHours())}${pad(date.getMinutes())}`
  return `NeoModern-backup-${stamp}.${BACKUP_EXT}`
}

/** A file size for people: "812 KB", "4.2 MB", "1.1 GB" (1 KB = 1024 bytes). */
export function formatBytes(bytes: number, locale = 'en-US'): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let value = Math.max(0, bytes)
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  const digits = unit === 0 || value >= 10 ? 0 : 1
  const n = new Intl.NumberFormat(locale, { maximumFractionDigits: digits }).format(value)
  return `${n} ${units[unit]}`
}

/**
 * A point in time as sent by the backend: unix seconds, unix milliseconds or
 * an ISO 8601 string. `null` when it cannot be read.
 */
export function toDate(value: number | string | null | undefined): Date | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || value <= 0) return null
    // Seconds until the year 33658; anything bigger is milliseconds.
    return new Date(value < 1e12 ? value * 1000 : value)
  }
  const d = new Date(value)
  return Number.isNaN(d.getTime()) ? null : d
}

/** A date and time like "21 Nov 2026, 14:05" in the UI language. */
export function formatDateTime(value: number | string | null | undefined, locale = 'en-US'): string | null {
  const d = toDate(value)
  if (!d) return null
  return new Intl.DateTimeFormat(locale, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(d)
}

/** How a move check turned out: none found, some found or all found. */
export type MoveMatch = 'missing' | 'none' | 'some' | 'all'

/** What `library_folder_check_move` says (docs/BACKUP.md §2). */
export interface MoveCheck {
  /** The new path exists and is a folder. */
  exists: boolean
  found: number
  /** Songs looked at: `total`, or an even sample of a large folder. */
  checked: number
  total: number
}

export function moveMatch(c: MoveCheck): MoveMatch {
  if (!c.exists) return 'missing'
  // An empty folder (no songs yet) can always be moved.
  if (c.total === 0 || (c.checked > 0 && c.found >= c.checked)) return 'all'
  return c.found > 0 ? 'some' : 'none'
}

/**
 * Songs found under the new path, out of all the folder's songs. For a
 * sampled check the number is scaled up and marked as an estimate.
 */
export function movedCount(c: MoveCheck): { found: number; total: number; estimate: boolean } {
  if (c.checked >= c.total || c.checked === 0) return { found: c.found, total: c.total, estimate: false }
  const found = c.found >= c.checked ? c.total : Math.round((c.found / c.checked) * c.total)
  return { found, total: c.total, estimate: c.found < c.checked }
}

type Translate = (en: string, params?: Record<string, string | number>) => string

/** Known backend error messages in plain words; anything else unchanged. */
export function explainBackupError(message: string, t: Translate): string {
  const m = message.toLowerCase()
  if (/newer (format|schema|version)|made by a newer/.test(m))
    return t('This backup was made by a newer version of NeoModern. Update the app first.')
  if (/manifest|not a (zip|backup)|invalid zip|unknown entry|checksum|sha-?256|size mismatch|integrity/.test(m))
    return t('This file is not a valid NeoModern backup, or it is damaged.')
  if (/too (big|large)|exceeds|limit/.test(m)) return t('This backup is too large to import.')
  if (/scan/.test(m) && /running|busy|in progress/.test(m))
    return t('A library scan is running. Try again when it has finished.')
  if (/no space|disk full|storage full/.test(m)) return t('There is not enough free space.')
  if (/permission denied|access is denied|read-only/.test(m))
    return t('NeoModern may not write there. Choose another folder.')
  if (/not found|no such file|cannot find|does not exist/.test(m))
    return t('The folder or file was not found.')
  return message
}

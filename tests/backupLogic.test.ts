import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  defaultBackupName,
  explainBackupError,
  formatBytes,
  formatDateTime,
  moveMatch,
  movedCount,
  toDate,
} from '../src/lib/backupLogic.ts'

const fill = (en: string, params?: Record<string, string | number>) =>
  en.replace(/\{(\w+)\}/g, (m, k: string) => (params && k in params ? String(params[k]) : m))

test('the default export name follows the spec, in local time', () => {
  assert.equal(defaultBackupName(new Date(2026, 10, 21, 9, 5)), 'NeoModern-backup-2026-11-21-0905.nmbackup')
  assert.equal(defaultBackupName(new Date(2027, 0, 3, 23, 59)), 'NeoModern-backup-2027-01-03-2359.nmbackup')
})

test('sizes are short and readable', () => {
  assert.equal(formatBytes(0), '0 B')
  assert.equal(formatBytes(812), '812 B')
  assert.equal(formatBytes(1536), '1.5 KB')
  assert.equal(formatBytes(4.2 * 1024 * 1024), '4.2 MB')
  assert.equal(formatBytes(123 * 1024 * 1024), '123 MB')
  assert.equal(formatBytes(1.1 * 1024 ** 3), '1.1 GB')
  assert.equal(formatBytes(1.5 * 1024 * 1024, 'tr-TR'), '1,5 MB')
  assert.equal(formatBytes(-5), '0 B')
})

test('times from the backend may be seconds, milliseconds or ISO strings', () => {
  const iso = '2026-11-21T10:00:00Z'
  const ms = Date.parse(iso)
  assert.equal(toDate(ms / 1000)?.getTime(), ms)
  assert.equal(toDate(ms)?.getTime(), ms)
  assert.equal(toDate(iso)?.getTime(), ms)
  assert.equal(toDate(null), null)
  assert.equal(toDate(0), null)
  assert.equal(toDate('not a date'), null)
  assert.match(formatDateTime(iso) ?? '', /2026/)
  assert.equal(formatDateTime(undefined), null)
})

test('a move check is all, some, none found or a missing folder', () => {
  const c = (found: number, checked: number, total: number, exists = true) => ({ exists, found, checked, total })
  assert.equal(moveMatch(c(120, 120, 120)), 'all')
  assert.equal(moveMatch(c(80, 120, 120)), 'some')
  assert.equal(moveMatch(c(0, 120, 120)), 'none')
  assert.equal(moveMatch(c(0, 0, 0)), 'all')
  assert.equal(moveMatch(c(0, 0, 120, false)), 'missing')
  // A large folder is sampled: all of the sample found means all.
  assert.equal(moveMatch(c(2000, 2000, 9000)), 'all')
})

test('a sampled move check is scaled up and marked as an estimate', () => {
  assert.deepEqual(movedCount({ exists: true, found: 80, checked: 120, total: 120 }), { found: 80, total: 120, estimate: false })
  assert.deepEqual(movedCount({ exists: true, found: 1000, checked: 2000, total: 9000 }), { found: 4500, total: 9000, estimate: true })
  assert.deepEqual(movedCount({ exists: true, found: 2000, checked: 2000, total: 9000 }), { found: 9000, total: 9000, estimate: false })
  assert.deepEqual(movedCount({ exists: false, found: 0, checked: 0, total: 50 }), { found: 0, total: 50, estimate: false })
})

test('backend errors are explained, unknown ones are kept', () => {
  assert.match(explainBackupError('backup was made by a newer schema version (3 > 2)', fill), /newer version/)
  assert.match(explainBackupError('manifest.json missing', fill), /not a valid NeoModern backup/)
  assert.match(explainBackupError('sha256 mismatch for library.sqlite3', fill), /damaged/)
  assert.match(explainBackupError('Permission denied (os error 13)', fill), /may not write there/)
  assert.match(explainBackupError('a library scan is running', fill), /scan is running/)
  assert.equal(explainBackupError('something odd', fill), 'something odd')
})

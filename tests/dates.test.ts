import { test } from 'node:test'
import assert from 'node:assert/strict'
import { addedAgo } from '../src/lib/dates.ts'

const now = Date.UTC(2026, 10, 15, 12, 0, 0) / 1000

test('recent dates read as "… ago", older ones as a short date', () => {
  assert.equal(addedAgo(now - 4 * 86400, 'en', now), '4 days ago')
  assert.equal(addedAgo(now - 3 * 3600, 'en', now), '3 hours ago')
  assert.equal(addedAgo(now - 10, 'en', now), '1 minute ago')
  assert.equal(addedAgo(now - 14 * 86400, 'en', now), '2 weeks ago')
  assert.equal(addedAgo(Date.UTC(2026, 1, 12, 12) / 1000, 'en', now), 'Feb 12, 2026')
  assert.equal(addedAgo(now - 4 * 86400, 'tr', now), '4 gün önce')
})

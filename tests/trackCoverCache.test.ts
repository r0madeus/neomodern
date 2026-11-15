import assert from 'node:assert/strict'
import { test } from 'node:test'
import { pruneCoverCache } from '../src/lib/trackCoverCache.ts'

test('pruneCoverCache drops oldest inactive entries and preserves active queue entries', () => {
  const covers = new Map<string, string | null>([
    ['/old-1.flac', '/covers/1.jpg'],
    ['/active-1.flac', '/covers/a1.jpg'],
    ['/old-2.flac', null],
    ['/active-2.flac', '/covers/a2.jpg'],
    ['/old-3.flac', '/covers/3.jpg'],
  ])
  const active = new Set(['/active-1.flac', '/active-2.flac', '/active-3.flac'])

  pruneCoverCache(covers, active, 3)

  assert.equal(covers.size, 3)
  assert.equal(covers.has('/old-1.flac'), false)
  assert.equal(covers.has('/old-2.flac'), false)
  assert.equal(covers.has('/active-1.flac'), true)
  assert.equal(covers.has('/active-2.flac'), true)
  assert.equal(covers.has('/old-3.flac'), true)
})

test('pruneCoverCache keeps all active entries even when active queue exceeds limit', () => {
  const covers = new Map<string, string | null>()
  const active = new Set<string>()
  for (let i = 0; i < 60; i++) {
    const path = `/track-${i}.mp3`
    covers.set(path, `/cover-${i}.jpg`)
    active.add(path)
  }

  pruneCoverCache(covers, active, 24)

  assert.equal(covers.size, 60)
  for (const path of active) {
    assert.equal(covers.has(path), true)
  }
})

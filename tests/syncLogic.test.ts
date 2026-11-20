import assert from 'node:assert/strict'
import { mock, test } from 'node:test'
import {
  addressWithPort,
  checkAddress,
  cleanFound,
  computerFor,
  discoveryView,
  formatCountdown,
  formatPairCode,
  guardLines,
  interpolatePosition,
  nextRepeat,
  normalizePairCode,
  pairErrorKind,
  remoteErrorKind,
  throttleLatest,
} from '../src/lib/syncLogic.ts'

const fill = (en: string, params?: Record<string, string | number>) =>
  en.replace(/\{(\w+)\}/g, (m, k: string) => (params && k in params ? String(params[k]) : m))

test('pairing code is shown in two groups and typed as six digits', () => {
  assert.equal(formatPairCode('123456'), '123 456')
  assert.equal(formatPairCode('12345'), '12345')
  assert.equal(normalizePairCode(' 12 3-45 67 89'), '123456')
  assert.equal(normalizePairCode('abc'), '')
})

test('addresses: LAN IPv4 with an optional port', () => {
  assert.deepEqual(checkAddress(' 192.168.1.20 '), { ok: true, address: '192.168.1.20' })
  assert.deepEqual(checkAddress('10.0.0.5:47321'), { ok: true, address: '10.0.0.5:47321' })
  assert.deepEqual(checkAddress('192,168,1,20'), { ok: true, address: '192.168.1.20' })
  assert.deepEqual(checkAddress('172.20.3.4'), { ok: true, address: '172.20.3.4' })
  assert.deepEqual(checkAddress(''), { ok: false, reason: 'empty' })
  assert.deepEqual(checkAddress('192.168.1'), { ok: false, reason: 'invalid' })
  assert.deepEqual(checkAddress('192.168.1.300'), { ok: false, reason: 'invalid' })
  assert.deepEqual(checkAddress('192.168.1.2:70000'), { ok: false, reason: 'invalid' })
  assert.deepEqual(checkAddress('example.com'), { ok: false, reason: 'invalid' })
  assert.deepEqual(checkAddress('8.8.8.8'), { ok: false, reason: 'notLan' })
  assert.deepEqual(checkAddress('172.32.0.1'), { ok: false, reason: 'notLan' })
  assert.deepEqual(checkAddress('fe80::1'), { ok: true, address: 'fe80::1' })
  assert.equal(addressWithPort('192.168.1.20', 47321), '192.168.1.20:47321')
  assert.equal(addressWithPort('fe80::1', 47321), '[fe80::1]:47321')
})

test('position moves on while playing and stops at the duration', () => {
  assert.equal(interpolatePosition(10, 1000, 3500, true, 200), 12.5)
  assert.equal(interpolatePosition(10, 1000, 3500, false, 200), 10)
  assert.equal(interpolatePosition(199, 0, 5000, true, 200), 200)
  assert.equal(interpolatePosition(5, 0, 2000, true, null), 7)
  assert.equal(interpolatePosition(5, 2000, 1000, true, null), 5)
})

test('repeat cycles off, all, one', () => {
  assert.equal(nextRepeat('off'), 'all')
  assert.equal(nextRepeat('all'), 'one')
  assert.equal(nextRepeat('one'), 'off')
})

test('countdown reads minutes and seconds', () => {
  assert.equal(formatCountdown(120), '2:00')
  assert.equal(formatCountdown(65.2), '1:06')
  assert.equal(formatCountdown(-3), '0:00')
})

test('guard summary becomes readable lines', () => {
  const lines = guardLines(
    {
      favoritesTurnedOff: 40,
      localFavorites: 52,
      playlistsDeleted: 4,
      playlistNames: ['Road trip', 'Focus'],
      songsRemoved: [{ name: 'Gym', removed: 30, total: 35 }],
    },
    fill,
  )
  assert.deepEqual(lines, [
    'Remove 40 of your 52 favorites',
    'Delete 4 playlists: “Road trip”, “Focus” and 2 more',
    'Remove 30 of 35 songs from “Gym”',
  ])
  assert.deepEqual(
    guardLines(
      { favoritesTurnedOff: 0, localFavorites: 3, playlistsDeleted: 1, playlistNames: ['A'], songsRemoved: [] },
      fill,
    ),
    ['Delete the playlist “A”'],
  )
})

test('pairing and remote errors are sorted by kind', () => {
  assert.equal(pairErrorKind('wrong pairing code'), 'wrongCode')
  assert.equal(pairErrorKind('this is not a NeoModern pairing code'), 'notPairingQr')
  assert.equal(pairErrorKind('the code has no local network address of the computer'), 'qrNoAddress')
  assert.equal(pairErrorKind('camera permission was not given'), 'camera')
  assert.equal(pairErrorKind('this pairing code is from a newer version: update the app'), 'version')
  assert.equal(pairErrorKind('wrong pairing code; too many attempts, a new code is needed'), 'tooManyAttempts')
  assert.equal(pairErrorKind('the pairing code has expired'), 'expired')
  assert.equal(pairErrorKind('pairing is not open on the computer'), 'notOpen')
  assert.equal(pairErrorKind('network error: Connection refused (os error 111)'), 'unreachable')
  assert.equal(pairErrorKind('the connection timed out'), 'unreachable')
  assert.equal(pairErrorKind('only addresses on the local network can be used'), 'address')
  assert.equal(pairErrorKind('protocol version mismatch: update the app on the other device'), 'version')
  assert.equal(pairErrorKind('something else'), 'other')
  assert.equal(remoteErrorKind('the queue changed; reload it'), 'staleQueue')
  assert.equal(remoteErrorKind('too many commands'), 'rateLimited')
  assert.equal(remoteErrorKind('not connected to the computer'), 'notConnected')
  assert.equal(remoteErrorKind('the computer did not answer'), 'noAnswer')
  assert.equal(remoteErrorKind('index out of range'), 'other')
})

test('throttleLatest sends at most once per interval and keeps the last value', () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  try {
    let clock = 0
    const sent: number[] = []
    const th = throttleLatest((v: number) => sent.push(v), 200, () => clock)
    th.push(1) // leading edge goes at once
    assert.deepEqual(sent, [1])
    clock = 50
    th.push(2)
    clock = 120
    th.push(3)
    assert.deepEqual(sent, [1])
    clock = 200
    mock.timers.tick(150)
    assert.deepEqual(sent, [1, 3])
    clock = 260
    th.push(4)
    th.flush()
    assert.deepEqual(sent, [1, 3, 4])
    th.push(5)
    th.cancel()
    mock.timers.tick(1000)
    assert.deepEqual(sent, [1, 3, 4])
  } finally {
    mock.timers.reset()
  }
})

test('the phone shows the pairing of its active profile only', () => {
  const peers = [
    { kind: 'computer', profileId: 1, id: 'a' },
    { kind: 'computer', profileId: 2, id: 'b' },
    { kind: 'phone', profileId: 3, id: 'c' },
  ]
  assert.equal(computerFor(peers, 1)?.id, 'a')
  assert.equal(computerFor(peers, 2)?.id, 'b')
  // No pairing for this profile: the connect form is shown.
  assert.equal(computerFor(peers, 3), null)
  assert.equal(computerFor(peers, null), null)
  assert.equal(computerFor([], 1), null)
})

test('found computers: one per device, valid LAN addresses, sorted by name', () => {
  const list = cleanFound([
    { deviceId: 'b', name: 'Study', address: '192.168.1.5:47321' },
    { deviceId: 'a', name: 'Desk', address: '192.168.1.9:47321' },
    { deviceId: 'a', name: 'Desk again', address: '192.168.1.10:47321' },
    { deviceId: 'c', name: 'Far away', address: '8.8.8.8:47321' },
    { deviceId: 'd', name: 'Broken', address: 'nonsense' },
  ])
  assert.deepEqual(
    list.map((f) => f.name),
    ['Desk', 'Study'],
  )
  assert.equal(list[0].address, '192.168.1.9:47321')
})

test('the discovery list says searching, found, none or nothing yet', () => {
  const one = [{ deviceId: 'a', name: 'Desk', address: '192.168.1.9:47321' }]
  assert.equal(discoveryView(true, false, []), 'searching')
  assert.equal(discoveryView(true, true, one), 'searching')
  assert.equal(discoveryView(false, true, one), 'found')
  assert.equal(discoveryView(false, true, []), 'none')
  assert.equal(discoveryView(false, false, []), 'idle')
})

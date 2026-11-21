import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  cleanQuery,
  explainJamError,
  formatDurationMs,
  jamErrorKind,
  JAM_QUERY_MAX,
  mergeResults,
  scannedLinkKind,
  shortName,
} from '../src/lib/jamLogic.ts'

const fill = (en: string, params?: Record<string, string | number>) =>
  en.replace(/\{(\w+)\}/g, (m, k: string) => (params && k in params ? String(params[k]) : m))

test('a scanned QR code is a Jam link, a pairing link or something else', () => {
  assert.equal(scannedLinkKind('neomodern://jam?v=1&c=012345&a=192.168.1.20:47321'), 'jam')
  assert.equal(scannedLinkKind('  neomodern://jam?v=1&c=123456  '), 'jam')
  assert.equal(scannedLinkKind('neomodern://jam?v=1&c=12345&a=192.168.1.20:47321'), 'other')
  assert.equal(scannedLinkKind('neomodern://jam?v=1&a=192.168.1.20:47321'), 'other')
  assert.equal(scannedLinkKind('neomodern://pair?v=1&c=123456&a=192.168.1.20:47321'), 'pair')
  assert.equal(scannedLinkKind('https://example.com'), 'other')
})

test('search queries are trimmed and capped', () => {
  assert.equal(cleanQuery('  daft punk '), 'daft punk')
  assert.equal(cleanQuery('x'.repeat(150)).length, JAM_QUERY_MAX)
  assert.equal(cleanQuery('   '), '')
})

test('long guest names are cut at 40 characters', () => {
  assert.equal(shortName(' Pixel 7 · Zeynep '), 'Pixel 7 · Zeynep')
  const long = shortName('a'.repeat(60))
  assert.equal(long.length, 40)
  assert.ok(long.endsWith('…'))
})

test('durations read minutes and seconds', () => {
  assert.equal(formatDurationMs(185_000), '3:05')
  assert.equal(formatDurationMs(3_725_000), '1:02:05')
  assert.equal(formatDurationMs(null), '')
  assert.equal(formatDurationMs(-1), '')
})

test('search pages join the loaded rows only when they follow them', () => {
  assert.deepEqual(mergeResults([1, 2], 0, [9]), [9])
  assert.deepEqual(mergeResults([1, 2], 2, [3, 4]), [1, 2, 3, 4])
  assert.deepEqual(mergeResults([1, 2], 5, [6]), [1, 2])
})

test('add and join errors are sorted into kinds', () => {
  assert.equal(jamErrorKind('rateLimited'), 'rateLimited')
  assert.equal(jamErrorKind('rate_limited'), 'rateLimited')
  assert.equal(jamErrorKind('queueFull'), 'queueFull')
  assert.equal(jamErrorKind('the queue is full, try later'), 'queueFull')
  assert.equal(jamErrorKind('notFound'), 'notFound')
  assert.equal(jamErrorKind('jamEnded'), 'jamEnded')
  assert.equal(jamErrorKind('you were removed from the Jam'), 'removed')
  assert.equal(jamErrorKind('wrong Jam code'), 'wrongCode')
  assert.equal(jamErrorKind('no Jam is running'), 'notRunning')
  assert.equal(jamErrorKind('network error: timed out'), 'unreachable')
  assert.equal(jamErrorKind('something odd'), 'other')
})

test('errors are explained, unknown ones shown as they are', () => {
  assert.equal(explainJamError('queueFull', fill), 'The queue is full. Try again later.')
  assert.match(explainJamError('pairing qr', fill), /pairing code/)
  assert.match(explainJamError('camera permission was not given', fill), /camera/)
  assert.equal(explainJamError('something odd', fill), 'something odd')
})

test("the backend's messages are recognised", () => {
  assert.equal(jamErrorKind('Not so fast: try again in a few seconds'), 'rateLimited')
  assert.equal(jamErrorKind('The queue is full, try later'), 'queueFull')
  assert.equal(jamErrorKind('This song is not in the library any more'), 'notFound')
  assert.equal(jamErrorKind('The Jam has ended'), 'jamEnded')
  assert.equal(jamErrorKind('The host removed you from the Jam'), 'removed')
  assert.equal(jamErrorKind('No Jam is running on that computer'), 'notRunning')
  assert.equal(jamErrorKind('Wrong Jam code'), 'wrongCode')
  assert.equal(jamErrorKind('Wrong Jam code; the Jam has a new code now'), 'newCode')
  assert.equal(jamErrorKind('The Jam is full'), 'full')
  assert.equal(jamErrorKind('The Jam code has 6 digits'), 'invalidCode')
  assert.equal(jamErrorKind('no computer found: type its address'), 'noComputer')
  assert.equal(jamErrorKind('turn on Jam in Settings first'), 'disabled')
  assert.equal(jamErrorKind('the connection closed'), 'unreachable')
})

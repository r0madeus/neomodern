// Splits compound artist strings for the clickable artist links. Mirrors
// `split_artists` in src-tauri/src/library/db.rs; both are checked against
// fixtures/artist-split-cases.json (`npm test` and `cargo test`).

const FEATURE_RE = /\(featuring |\[featuring |\(feat\.|\[feat\.|\(ft\.|\[ft\.| featuring | feat\. | feat | ft\. | ft /gi

function stripUnmatchedClose(part: string): string {
  let p = part.trim()
  if (p.endsWith(')') && !p.slice(0, -1).includes('(')) p = p.slice(0, -1).trim()
  if (p.endsWith(']') && !p.slice(0, -1).includes('[')) p = p.slice(0, -1).trim()
  return p
}

// Bands whose name is itself a comma list (compared after normalizeGroup).
// Any other "A, B & C" is three artists.
const COMMA_GROUPS = new Set([
  'earth, wind & fire',
  'crosby, stills, nash & young',
  'crosby, stills & nash',
  'peter, paul & mary',
  'emerson, lake & palmer',
  'blood, sweat & tears',
  'dave dee, dozy, beaky, mick & tich',
])

// Words after "&" that make it part of one band name ("Mumford & Sons",
// "Bob Marley & The Wailers"), not a list.
const GROUP_TAILS = new Set(['sons', 'daughters', 'friends', 'co', 'co.', 'company', 'brothers', 'sisters'])
const GROUP_TAIL_PREFIXES = ['the ', 'his ', 'her ', 'their ']

function normalizeGroup(s: string): string {
  return s
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)
    .map((w) => (w === 'and' ? '&' : w))
    .join(' ')
}

function isGroupTail(tail: string): boolean {
  const t = tail.trim().toLowerCase()
  return GROUP_TAILS.has(t) || GROUP_TAIL_PREFIXES.some((p) => t.startsWith(p))
}

function splitNameList(list: string): string[] {
  const whole = stripUnmatchedClose(list)
  if (COMMA_GROUPS.has(normalizeGroup(whole))) return [whole]
  const parts: string[] = []
  for (const raw of list.split(',')) {
    const part = stripUnmatchedClose(raw)
    if (!part) continue
    if (parts.length > 0 && part.slice(0, 4).toLowerCase() === 'the ') {
      parts[parts.length - 1] += `, ${part}`
    } else {
      parts.push(part)
    }
  }
  // In a list the last "&" joins two more names, unless it is part of a band name.
  if (parts.length > 1) {
    const last = parts.pop()!
    const i = last.lastIndexOf(' & ')
    const a = i < 0 ? '' : last.slice(0, i).trim()
    const b = i < 0 ? '' : last.slice(i + 3).trim()
    if (a && b && !isGroupTail(b)) parts.push(a, b)
    else parts.push(last)
  }
  return parts
}

export function splitArtistNames(raw: string): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  for (const segment of raw.trim().split(FEATURE_RE)) {
    for (const piece of segment.split(';')) {
      for (const name of splitNameList(piece)) {
        const key = name.toLowerCase()
        if (!seen.has(key)) {
          seen.add(key)
          out.push(name)
        }
      }
    }
  }
  return out
}

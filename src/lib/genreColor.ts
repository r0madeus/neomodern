const GENRE_PALETTE = [
  '#0d7a5f',
  '#a1263d',
  '#3e46a3',
  '#a65a18',
  '#146c78',
  '#6d2d80',
  '#1e5c99',
  '#9c2754',
  '#456e28',
  '#32506d',
  '#b0442a',
  '#58339c',
] as const

/** Deterministic Spotify-style card background color for a genre label. */
export function genreColor(name: string): string {
  const key = name.trim().toLowerCase()
  let hash = 2166136261
  for (let i = 0; i < key.length; i++) {
    hash ^= key.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  return GENRE_PALETTE[(hash >>> 0) % GENRE_PALETTE.length]
}

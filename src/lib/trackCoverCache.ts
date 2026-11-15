/**
 * Prunes oldest cached cover paths above `limit` while preserving every path
 * in `activePaths`. Evicting an active queue entry from a reactive map drops
 * its mounted `<Cover>` back to the fallback and causes an endless reload loop.
 */
export function pruneCoverCache(
  covers: Map<string, string | null>,
  activePaths: ReadonlySet<string>,
  limit: number,
): void {
  if (covers.size <= limit) return
  for (const key of covers.keys()) {
    if (covers.size <= limit) break
    if (!activePaths.has(key)) covers.delete(key)
  }
}

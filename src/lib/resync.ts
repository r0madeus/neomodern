export interface ResyncChanges {
  state: boolean
  history: boolean
  library: boolean
}

export const RESYNC_EVENT = 'neomodern:resync'

let pendingVisibilitySync: Promise<void> | null = null

export function isDocumentHidden(): boolean {
  return typeof document !== 'undefined' && document.visibilityState === 'hidden'
}

export function trackVisibilitySync(job: Promise<void>): void {
  const tracked = job.finally(() => {
    if (pendingVisibilitySync === tracked) pendingVisibilitySync = null
  })
  pendingVisibilitySync = tracked
}

export interface ResyncTarget {
  onRefresh: () => void
  matches: (detail: Partial<ResyncChanges>) => boolean
}

export interface ResyncController {
  bind: () => void
  trigger: () => void
  markClean: () => void
}

/**
 * Coordinates event-driven store refreshes with window visibility so events
 * arriving while hidden are coalesced into a single refresh upon return.
 */
export function createResyncHandler({ onRefresh, matches }: ResyncTarget): ResyncController {
  let dirty = false
  let bound = false

  const flushIfDirty = async () => {
    // Let all synchronous visibilitychange listeners (including player's
    // app_set_visible call) register before checking dirty again.
    await Promise.resolve()
    await pendingVisibilitySync
    if (dirty && !isDocumentHidden()) {
      dirty = false
      onRefresh()
    }
  }

  return {
    bind() {
      if (bound) return
      bound = true
      if (typeof window !== 'undefined') {
        window.addEventListener(RESYNC_EVENT, (e) => {
          const detail = (e as CustomEvent<Partial<ResyncChanges> | undefined>).detail
          if (!detail || !matches(detail)) return
          if (isDocumentHidden()) {
            dirty = true
            return
          }
          dirty = false
          onRefresh()
        })
      }
      if (typeof document !== 'undefined') {
        document.addEventListener('visibilitychange', () => {
          if (document.visibilityState === 'visible' && dirty) {
            void flushIfDirty()
          }
        })
      }
    },
    trigger() {
      if (isDocumentHidden()) {
        dirty = true
        return
      }
      dirty = false
      onRefresh()
    },
    markClean() {
      dirty = false
    },
  }
}

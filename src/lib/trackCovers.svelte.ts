// Covers of queue entries by file path, for showing track thumbnails in the
// phone queue sheet and during previous/next swipes. Small and in memory;
// files come from the cover cache on disk (convertFileSrc), never as bytes over IPC.
import { invoke } from '@tauri-apps/api/core'
import { SvelteMap } from 'svelte/reactivity'
import { player } from './player.svelte'
import { pruneCoverCache } from './trackCoverCache'

const MAX = 256
const MAX_IN_FLIGHT = 16

class TrackCovers {
  #covers = new SvelteMap<string, string | null>()
  #pending = new Set<string>()
  #queue: string[] = []
  #inFlight = 0

  /** The cover for `path` once known; starts the lookup on first use. */
  get(path: string | null | undefined): string | null | undefined {
    if (!path) return null
    if (this.#covers.has(path)) return this.#covers.get(path)
    if (!this.#pending.has(path)) {
      this.#pending.add(path)
      this.#queue.push(path)
      this.#pump()
    }
    return undefined
  }

  #pump(): void {
    while (this.#inFlight < MAX_IN_FLIGHT && this.#queue.length > 0) {
      const path = this.#queue.shift()!
      void this.#load(path)
    }
  }

  async #load(path: string): Promise<void> {
    this.#inFlight++
    try {
      const cover = await invoke<string | null>('library_track_cover', { path })
      this.#set(path, cover)
    } catch {
      this.#set(path, null)
    } finally {
      this.#pending.delete(path)
      this.#inFlight--
      this.#pump()
    }
  }

  #set(path: string, cover: string | null): void {
    if (this.#covers.size >= MAX) {
      pruneCoverCache(this.#covers, this.#activePaths(), MAX - 1)
    }
    this.#covers.set(path, cover)
  }

  #activePaths(): Set<string> {
    const active = new Set<string>()
    for (const tr of player.queue) active.add(tr.path)
    const snap = player.snapshot
    if (snap.previousTrack) active.add(snap.previousTrack.path)
    if (snap.current) active.add(snap.current.path)
    if (snap.nextTrack) active.add(snap.nextTrack.path)
    return active
  }
}

export const trackCovers = new TrackCovers()

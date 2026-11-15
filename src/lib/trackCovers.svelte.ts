// Covers of queue entries by file path, for showing the previous and next
// song during a swipe. Small and in memory; files come from the cover cache
// on disk (convertFileSrc), never as bytes over IPC.
import { invoke } from '@tauri-apps/api/core'
import { SvelteMap } from 'svelte/reactivity'

const MAX = 24

class TrackCovers {
  #covers = new SvelteMap<string, string | null>()
  #pending = new Set<string>()

  /** The cover for `path` once known; starts the lookup on first use. */
  get(path: string | null | undefined): string | null | undefined {
    if (!path) return null
    if (this.#covers.has(path)) return this.#covers.get(path)
    if (!this.#pending.has(path)) void this.#load(path)
    return undefined
  }

  async #load(path: string): Promise<void> {
    this.#pending.add(path)
    try {
      const cover = await invoke<string | null>('library_track_cover', { path })
      if (this.#covers.size >= MAX) {
        const oldest = this.#covers.keys().next().value
        if (oldest !== undefined) this.#covers.delete(oldest)
      }
      this.#covers.set(path, cover)
    } catch {
      this.#covers.set(path, null)
    } finally {
      this.#pending.delete(path)
    }
  }
}

export const trackCovers = new TrackCovers()

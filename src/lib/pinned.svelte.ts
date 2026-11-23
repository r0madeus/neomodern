// Pinned albums and playlists mirrored from Rust (`session.json` + SQLite).
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { player } from './player.svelte'
import { createResyncHandler } from './resync'

export type PinnedKind = 'album' | 'playlist'

export interface PinnedEntry {
  kind: PinnedKind
  id: number
  title: string
  subtitle: string
  cover: string | null
  albumCovers: string[]
  trackCount: number
}

class PinnedStore {
  entries = $state<PinnedEntry[]>([])
  #initialized = false
  #resync = createResyncHandler({
    onRefresh: () => void this.refresh(),
    matches: (detail) => Boolean(detail.library),
  })

  async init(): Promise<void> {
    if (!this.#initialized) {
      this.#initialized = true
      this.#resync.bind()
      await listen('pinned://changed', () => this.#resync.trigger())
      await listen('library://changed', () => this.#resync.trigger())
      await listen('playlists://changed', () => this.#resync.trigger())
    }
    await this.refresh()
  }

  async refresh(): Promise<void> {
    this.#resync.markClean()
    try {
      this.entries = await invoke<PinnedEntry[]>('pinned_list')
    } catch (e) {
      player.error = String(e)
    }
  }

  async toggle(kind: PinnedKind, id: number): Promise<void> {
    try {
      this.entries = await invoke<PinnedEntry[]>('pinned_toggle', { kind, id })
    } catch (e) {
      player.error = String(e)
    }
  }

  isPinned(kind: PinnedKind, id: number): boolean {
    return this.entries.some((e) => e.kind === kind && e.id === id)
  }
}

export const pinned = new PinnedStore()

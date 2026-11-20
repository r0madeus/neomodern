import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'

// Profiles (K24, docs/PROFILES.md): who is listening. Each profile has its
// own favourites, playlists, history, pins and queue; Rust holds all of it,
// this store only lists the profiles and asks Rust to switch.

export interface Profile {
  id: number
  name: string
  color: string
  createdAt: number
}

export interface ProfilesState {
  active: number
  profiles: Profile[]
  colors: string[]
  maxProfiles: number
}

export interface ProfileSummary {
  favorites: number
  playlists: number
  listens: number
}

/** The first letter of a name, for the avatar. */
export function profileInitial(name: string): string {
  return (Array.from(name.trim())[0] ?? '?').toLocaleUpperCase()
}

class ProfilesStore {
  state = $state<ProfilesState | null>(null)
  error = $state<string | null>(null)
  switching = $state(false)
  #bound = false

  current = $derived(this.state?.profiles.find((p) => p.id === this.state?.active) ?? null)

  async init(): Promise<void> {
    if (!this.#bound) {
      this.#bound = true
      await listen<ProfilesState>('profiles://changed', (e) => (this.state = e.payload))
    }
    await this.#run(() => invoke<ProfilesState>('profiles_list'))
  }

  /** Switches profile. Every list, the stats and the queue belong to the
   *  profile, so the page reloads to start clean from Rust's state. */
  async switchTo(id: number): Promise<void> {
    if (this.switching || id === this.state?.active) return
    this.switching = true
    try {
      await invoke('profile_switch', { id })
      location.reload()
    } catch (e) {
      this.error = String(e)
      this.switching = false
    }
  }

  create = (name: string) => this.#run(() => invoke<ProfilesState>('profile_create', { name }))
  rename = (id: number, name: string) => this.#run(() => invoke<ProfilesState>('profile_rename', { id, name }))
  setColor = (id: number, color: string) =>
    this.#run(() => invoke<ProfilesState>('profile_set_color', { id, color }))
  remove = (id: number) => this.#run(() => invoke<ProfilesState>('profile_delete', { id }))
  summary = (id: number) => invoke<ProfileSummary>('profile_summary', { id })

  async #run(call: () => Promise<ProfilesState>): Promise<boolean> {
    try {
      this.state = await call()
      this.error = null
      return true
    } catch (e) {
      this.error = String(e)
      return false
    }
  }
}

export const profiles = new ProfilesStore()

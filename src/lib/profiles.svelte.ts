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
  /** Switching to it asks for a PIN (K25). */
  hasPin: boolean
}

export interface ProfilesState {
  active: number
  profiles: Profile[]
  colors: string[]
  maxProfiles: number
  /** The app opened on a profile with a PIN that was not entered yet. */
  locked: boolean
}

/** PINs are 4 to 8 digits. */
export function validPin(pin: string): boolean {
  return /^[0-9]{4,8}$/.test(pin)
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

  /** Switches profile (`pin` for a profile that has one). Every list, the
   *  stats and the queue belong to the profile, so the page reloads to start
   *  clean from Rust's state. Returns the error message, or null. */
  async switchTo(id: number, pin: string | null = null): Promise<string | null> {
    if (this.switching) return null
    if (id === this.state?.active && !this.state?.locked) return null
    this.switching = true
    try {
      if (id === this.state?.active) await invoke('profile_unlock', { pin: pin ?? '' })
      else await invoke('profile_switch', { id, pin })
      location.reload()
      return null
    } catch (e) {
      this.switching = false
      return String(e)
    }
  }

  /** Sets, changes or (`pin` null) removes the PIN of the profile in use. */
  setPin = (pin: string | null, current: string | null) =>
    this.#run(() => invoke<ProfilesState>('profile_set_pin', { pin, current }))

  create = (name: string) => this.#run(() => invoke<ProfilesState>('profile_create', { name }))
  rename = (id: number, name: string) => this.#run(() => invoke<ProfilesState>('profile_rename', { id, name }))
  setColor = (id: number, color: string) =>
    this.#run(() => invoke<ProfilesState>('profile_set_color', { id, color }))
  remove = (id: number, pin: string | null = null) =>
    this.#run(() => invoke<ProfilesState>('profile_delete', { id, pin }))
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

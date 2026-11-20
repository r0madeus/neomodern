# Profiles (decision K24)

Several people use one NeoModern on one computer (or phone) with one music
library, but each has their own listening experience, as in Spotify:
favourites, playlists, history and statistics, the home feed, what is
pinned, and the queue never mix between profiles.

Profiles are **separation, not security**: anyone at the computer can switch
profile (no password, like Spotify's account switcher on a shared device).
A profile can have an optional PIN (K25, see "PIN" below).

## What belongs to a profile, what is shared

| Per profile | Shared by the device |
|---|---|
| Favourites | Music folders, tracks, tags, tag history (undo) |
| Playlists (with covers, order, dates) | Album covers, lyrics, artist info |
| Listening history, so: stats, home feed, mixes, autoplay picks, play counts in lists | Downloads, yt-dlp / ffmpeg |
| Sidebar pins | Audio: volume, EQ, ReplayGain, crossfade, gapless, exclusive mode |
| Queue, current song and position, shuffle, repeat | Internet switches, tray, lyrics options, download folder |
| Autoplay on/off | "Allow phone connections", paired devices list |
| The sync pairing it belongs to | Window layout, sort order, theme (per device, in the UI) |

Rule of thumb: what says something about a person's taste or habits is per
profile; what says something about the device or the files is shared.

## Model

- Table `profiles(id INTEGER PRIMARY KEY, name TEXT NOT NULL, color TEXT
  NOT NULL, created_at INTEGER NOT NULL)`; at most 8 profiles, names 1–40
  characters, unique ignoring case.
- `favorites`, `playlists` (and through them `playlist_tracks`) and
  `listen_events` get `profile_id INTEGER NOT NULL REFERENCES profiles(id)
  ON DELETE CASCADE`. `favorites` becomes keyed by `(profile_id, track_id)`.
  Indexes used by profile-scoped queries lead with `profile_id`.
- The device remembers the active profile (`session.json`:
  `active_profile`). Each profile's player state (queue, current index,
  position, shuffle, repeat, pins, autoplay) is kept under
  `profiles.<id>` in `session.json`; the device settings stay where they are.
- In Rust, every database function that reads or writes per-profile data
  takes the profile explicitly (`ProfileId` newtype). Nothing in `db.rs`
  reads a global "current profile": `Library` passes its active profile,
  sync passes the profile a pairing is bound to. Forgetting the argument is
  a compile error, not a leak.

## Migration (schema v14)

- A copy of the database is written first (`VACUUM INTO`
  `library-before-profiles.sqlite3`, next to it), because the migration
  rebuilds tables.
- One transaction: create `profiles` with profile 1 (named after the OS
  user when known, else "Profile 1"), add `profile_id = 1` to all existing
  rows, rebuild `favorites` and the sync tables that need the new key.
- `session.json`: the existing queue, pins, shuffle/repeat and autoplay move
  under profile 1.
- Nothing is lost and a user with one profile sees no difference.

## Switching

- Desktop: the profile button at the top of the sidebar opens the profile
  menu (switch, add, manage). Phone: the avatar in the Home header.
- Switching: the current profile's queue and position are saved and its
  running listen is recorded (playback stops), then the other profile's
  queue is loaded paused at its saved position. All lists, stats and the
  home feed reload.
- The app opens in the profile used last.
- Delete: asks for confirmation showing what goes (favourites, playlists,
  listens); removes that profile's data, pins, queue and sync pairing. The
  last profile cannot be deleted.

## Sync (K21) with profiles

- A pairing binds **one profile on the phone to one profile on the
  computer**: the profiles active on each side while pairing (both screens
  show which). Only that profile's favourites, playlists and listens travel.
  Pairing again re-binds.
- `sync_*` tables get `profile_id`; the sequence number stays global, and a
  peer only receives rows of its bound profile. Capture and apply run per
  bound profile; the library-level bookkeeping (present songs, track keys)
  stays shared.
- Remote control drives the computer's player as it is: songs played that
  way count for the computer's active profile, and the phone's remote screen
  shows which profile that is.
- A phone keeps one pairing per phone profile (K25, `SYNC.md`): each profile
  pairs with the same computer or another, under its own link id, and only
  the active profile's pairing is connected.

## Tests

- Isolation: with two profiles, every user-data function returns only its
  own profile's rows, and writes in one never change the other (favourites,
  playlists and entries, listens, stats, home feed, artist and track play
  counts, autoplay picks, pins, queue).
- Migration: a v13 database with data comes out with everything in
  profile 1 and the pre-migration copy present.
- Sync: the convergence tests run with two profiles per device and a pairing
  bound to one of them; the other profile's rows never travel.

## PIN (decision K25, schema v16)

- Optional, 4 to 8 digits, per profile. Only the profile in use sets,
  changes or removes its own PIN; changing or removing asks for the current
  one.
- Asked when switching to that profile, when deleting it from another
  profile, and at start-up when the app opens on it (a "Who is listening?"
  lock screen; choosing a profile without a PIN also opens the app).
- Stored as `v1$<salt>$<hash>` in `profiles.pin`: a random 16-byte salt and
  20 000 rounds of HMAC-SHA256, compared in constant time; never in clear.
- After 5 wrong PINs for a profile, tries are refused for 30 s.
- Still separation, not security: anyone who can read the database file can
  read the data, and the lock screen only hides the UI.


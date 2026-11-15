# PC ↔ phone sync and remote control (decision K21)

Status: being built (experimental, **off by default**). This document is the
design every change to `src-tauri/src/sync/` must follow.

## Goals

1. **Data sync** between the owner's own devices on the same Wi-Fi:
   favourites, playlists (name, cover preset, songs, order, "date added")
   and listening history. Audio files, tags, covers and settings are **not**
   synced.
2. **Remote control**: the phone shows what the PC is playing and controls
   it (play/pause, next/previous, seek, volume, shuffle/repeat, jump to a
   queue entry).
3. **Never lose or corrupt user data.** When in doubt, keep both copies.

Non-goals (later list): sync over the internet, PC controlling the phone,
streaming PC files to the phone, mDNS discovery, more than ~5 paired devices.

## Architecture fit

- Rust stays the single source of truth. Remote commands call the same
  `Player` methods as the Tauri commands; the PC UI updates through the
  existing `player://state` events. One queue only: the remote never edits
  mpv directly and never creates a second queue.
- Everything lives in `src-tauri/src/sync/`:
  - `sync/store/` – the replicated data model, capture, merge, materialise
    (pure SQLite, no networking, fully unit-tested).
  - `sync/link/` – pairing, encryption, framing (no SQLite).
  - `sync/mod.rs` – the service: server on desktop, client on the phone,
    remote-control dispatch, Tauri events.
- Sockets are opened only from `sync/link/`; `net.rs`'s guard test lists
  them. Nothing listens unless the user switched "Allow phone connections"
  on (desktop). Offline mode does **not** block LAN sync (no internet).
- No big payloads over IPC: the UI gets small status objects; remote
  now-playing uses the phone's own cover for the same song when it has it.
- Position updates to the remote: at most 4 per second.

## Device identity and time

- Each install has a random 128-bit `device_id` (hex) and a display name.
- Hybrid logical clock (HLC): `(wall_ms: u64, counter: u32, device_id)`,
  serialised as a fixed-width string `"{wall_ms:013}-{counter:06}-{device}"`
  so string order = clock order. Every local stamp is
  `max(now, last_seen) ` + counter; receiving a stamp advances `last_seen`.
  Incoming stamps more than 24 h ahead of local wall time are clamped for
  `last_seen` (a phone with a wrong clock must not poison the PC) but kept
  on the record for ordering.

## Track identity across devices

Paths differ between devices, so a song is identified by a **track key**:
`norm(artist) + "\u{1f}" + norm(album) + "\u{1f}" + norm(title)`, where
`norm` = Unicode lower-case, trim, collapse inner whitespace. Every synced
record also carries `title`, `artist`, `album`, `duration_ms` for display
and fallback.

Resolution of a key to a local track: (1) exact key; (2) if none, a unique
local track with the same `norm(artist)` + `norm(title)`; duration, when
both known, must be within 3 s. If several local tracks match, the one with
the smallest `id` wins (deterministic). A record whose key does not resolve
is **kept as unresolved** in the sync tables and becomes visible as soon as
the song appears in the library. Nothing is ever dropped because a song is
missing on one device.

## Replicated state (schema v13, `sync_*` tables)

The existing tables (`favorites`, `playlists`, `playlist_tracks`,
`listen_events`) stay exactly as they are and keep being what the app reads
and writes. The `sync_*` tables are the replicated record, kept in step by
**capture** (local tables → sync tables) and **materialise** (sync tables →
local tables). No existing code path has to change.

| Table | Key | Merge rule |
|---|---|---|
| `sync_favorites` | track key | LWW register `{on, hlc}` |
| `sync_playlists` | uuid | LWW per field: `name`, `cover_preset`, `deleted` (each with its own hlc) |
| `sync_playlist_entries` | uuid | LWW per field: `pos` (fractional index string), `deleted`; `playlist_uuid`, key, display fields and `added_at` are immutable |
| `sync_listens` | uuid | append-only union (immutable rows) |
| `sync_playlist_map` | local playlist id ↔ uuid | local only |
| `sync_peers` | device_id | local only: name, secret, last seq sent/received, last sync |
| `sync_meta` | key/value | local only: device_id, hlc state, `applying` flag |

Every replicated row has `seq INTEGER` – a local, strictly increasing
sequence set whenever the row is inserted or changed locally *or by a
merge*. A peer is sent all rows with `seq > last_seq_sent[peer]`; the
watermark moves only after the peer acknowledges. `listen_events` gets a
`uid TEXT` column (backfilled with random uuids) so history rows have a
stable identity.

LWW comparison is by HLC string; ties are impossible (device id is part of
it). Merging is commutative, associative and idempotent: applying the same
batch twice, or batches in any order, gives the same state. Tests must
prove this (randomised two- and three-device convergence tests).

### Capture (local → sync)

Runs inside one transaction, before every sync and after local changes
(debounced, on the library's `bump`).

- Favourites: for each local track that is **present** in the library:
  favourite but sync says off/absent → stamp `on` (hlc wall = the row's
  `added_at` when newer than the stored stamp, else now); not favourite
  but sync says on → stamp `off`. Keys whose track is not present locally
  are never touched – a missing file is not an "unfavourite". This is the
  rule that stops a removed music folder or an unplugged drive from
  deleting favourites on the other device.
- Playlists: new local playlist → new uuid; rename / cover preset → stamp;
  deleted local playlist (map row without local playlist) → `deleted`.
  Entries: align the local entry list with the live, *resolved* sync
  entries by key using LCS; matched entries keep their uuid (re-stamp `pos`
  only if their relative order changed); local-only entries get a new uuid
  and a `pos` between their neighbours; sync entries whose track is
  present locally but not in the local list → `deleted`; unresolved entries
  are left alone.
- Listening history: local events without `uid` get one; events not yet in
  `sync_listens` are copied (append-only).

### Materialise (sync → local)

After a merge changed something, inside the same transaction:

- `favorites` = resolved keys with `on`; `added_at` kept when already
  favourite.
- Each live playlist: create / rename / cover preset; entries rewritten in
  `pos` order (resolved only), keeping each entry's `added_at`. Deleted
  playlists are removed locally.
- New `sync_listens` rows → `listen_events` (track resolved by key, `path` =
  local path when resolved, else the sender's path; `source = 'sync'`).
- Bumps the library version so the UI refreshes.

Materialise never writes a row capture would then see as a new local
change (capture after materialise is a no-op; tested).

### First sync between two devices

Both sides have independent playlists. A remote playlist and a local one
with the same name (case-insensitive) **and the same resolved song list**
are unified (one uuid, the smaller wins). Same name but different songs →
both kept; the incoming one is shown as "Name (Device name)". Favourites and
history are unions. Nothing is deleted on a first sync.

## Data health

- **Validation before apply**: the whole incoming batch is checked first
  (types via serde with `deny_unknown_fields`, string lengths ≤ 1 KiB, names
  ≤ 200 chars, uuids/hlcs well-formed, ≤ 200 000 records per sync, ≤ 5 000
  playlists, positions well-formed). One bad record rejects the batch;
  nothing is applied.
- **One transaction**: capture → merge → materialise → watermark commit
  together or not at all. A dropped connection mid-sync leaves the
  database exactly as before (the watermark did not move; the batch is
  resent next time and merging is idempotent).
- **Backup**: before the first apply that changes data, at most once per
  6 h, `VACUUM INTO <data>/sync-backups/library-<utc>.sqlite3`; the 5 newest
  are kept. `PRAGMA quick_check` after apply; a failure restores nothing
  automatically but stops syncing and tells the user (the backup is there).
- **Mass-delete guard**: if one incoming batch would turn off more than 25 %
  of the local favourites (and at least 10), or delete more than 2
  playlists, or remove more than 50 % of a playlist's songs (≥ 10), the sync
  stops before applying and the UI asks "Apply / Skip". Skipping keeps the
  local data and does not move the watermark.
- **Version handshake**: protocol version and sync schema version are
  exchanged first; any mismatch stops with a clear "update the app on the
  other device" message.
- **The sync code never deletes tracks, files, tags or folders**, and never
  touches `tracks`/`albums` rows.

## Security

Threat model: a shared or hostile Wi-Fi (cafe, dorm), a curious device on
the home network, a stolen phone.

- **Off by default.** The desktop listens only while "Allow phone
  connections" is on; turning it off closes the listener and every session.
- **Pairing** (once per phone): the PC shows a 6-digit code (valid 2 min,
  one pairing at a time, 3 wrong attempts → new code) and its LAN address.
  The phone enters address + code. Both run **SPAKE2** with the code;
  key confirmation (HMAC both ways) proves both sides know it. An attacker
  gets one online guess per attempt and cannot brute-force offline. From
  the SPAKE2 key, HKDF derives a 32-byte per-device secret; both sides
  store it (PC: `sync_peers`, phone: its own `sync_peers` row for the PC).
- **Sessions**: Noise `NNpsk0_25519_ChaChaPoly_BLAKE2s` with the per-device
  secret as PSK. Mutual authentication (only the paired pair knows the
  PSK), encryption, forward secrecy (ephemeral keys). The client sends its
  `device_id` in clear first and it is bound as the Noise prologue; unknown
  ids are dropped without a reply.
- **Revocation**: the PC lists paired phones with "Remove"; removing deletes
  the secret and closes its session. The phone can "Forget this PC".
- **Exposure limits**: accept only private/link-local/loopback source
  addresses (RFC 1918, 100.64/10 excluded, fc00::/7, fe80::/10); at most 4
  sessions; handshake must finish in 5 s; frames ≤ 1 MiB (big batches are
  paged); idle timeout 60 s with keep-alive; 20 commands/s per session.
- **Whitelist**: the remote protocol is a closed `enum` of messages
  (`deny_unknown_fields`). No message carries a file path that the PC
  opens; queue entries are addressed by index plus the queue version (a
  stale version is refused).
- Secrets never go to logs or the problem report.

## Wire protocol (inside Noise)

Frame = `u32` big-endian length + Noise ciphertext (≤ 65 535 bytes per
Noise message; a logical message larger than that is split into numbered
chunks and reassembled, total ≤ 1 MiB). The plaintext is JSON of
`enum Msg { Hello, Welcome, SyncOffer, SyncBatch, SyncAck, SyncDone,
Remote(RemoteCmd), State(RemoteState), Position, Ping, Pong, Error }`.

## UI

- Desktop Settings › "Phone": switch "Allow phone connections", address,
  "Pair a phone" (shows the code), paired phones with last sync and Remove,
  "Sync now" per phone not needed (the phone starts syncs).
- Phone Settings › "Computer": "Connect to a computer" (address + code),
  connected state, "Sync now", "Forget", last sync result. A "Remote" screen
  (from the mini-player area / Settings) with the PC's now playing and
  controls. Sync runs on connect and every 10 min while connected.

## Testing

- Store: unit tests for capture, merge, materialise, unresolved keys,
  first-sync rules, idempotence, randomised convergence (2 and 3 devices),
  mass-delete guard, validation, backup rotation.
- Link: pairing (right code, wrong code, expired code), sessions (wrong
  PSK, unknown device, oversized frame, chunking), all over loopback.
- Service: an end-to-end loopback test: two libraries on temp dirs pair,
  sync, edit on both sides, sync again, converge; a remote `toggle_pause`
  reaches a `Player` with a silent engine.
- Real devices (owner): Windows PC + Android phone on home Wi-Fi; Windows
  firewall prompt on first enable; Android local-network permission on
  newer Android versions.

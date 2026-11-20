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
streaming PC files to the phone, mDNS / Bonjour discovery (the plain UDP
probe below is used instead), more than ~5 paired devices.

## Architecture fit

- Rust stays the single source of truth. Remote commands call the same
  `Player` methods as the Tauri commands; the PC UI updates through the
  existing `player://state` events. One queue only: the remote never edits
  mpv directly and never creates a second queue.
- Everything lives in `src-tauri/src/sync/`:
  - `sync/store/` – the replicated data model, capture, merge, materialise
    (pure SQLite, no networking, fully unit-tested).
  - `sync/link/` – pairing, encryption, framing (no SQLite).
  - `sync/protocol.rs` – the session messages; `sync/conn.rs` – one
    session's event loop (handshake, sync rounds both ways, remote,
    keep-alive); `sync/remote.rs` – remote commands and the state the phone
    sees; `sync/service.rs` – the service (server on desktop, client on the
    phone, pairing, status, Tauri events through an `EventSink`);
    `sync/commands.rs` – the Tauri commands.
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
| `sync_meta` | key/value | local only: device_id, device name, hlc state, seq; `peer_address:<device_id>` = the paired computer's `ip:port` (phone side); `device_id:profile:<id>` = the link id of a non-first phone profile (K25); `peer_wire:<key>` = the computer's own id when the pairing row key differs (K25) |
| `sync_present` | track id | local only: tracks present at the last capture (a song that re-appears gets its synced state back instead of being read as "unfavourited") |

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
history are unions. Nothing is deleted on a first sync. A playlist with a
song the receiving device cannot resolve is never unified. Playlists with a
new uuid wait (local-only `reconciled = 0`, not shown) until the last page
of a sync, so the comparison sees all their entries.

## Profiles (schema v15, decision K24)

A pairing is bound to **one local profile** (`sync_peers.profile_id`).
Only that profile's favourites, playlists and listens travel to the peer,
and incoming changes are merged into and materialised for that profile
only; other profiles are never read, sent or changed. See `PROFILES.md`.

- `sync_favorites` (key `(profile_id, key)`), `sync_playlists`,
  `sync_playlist_entries` and `sync_listens` carry `profile_id` with an
  index `(profile_id, seq)`; the foreign key cascades, so deleting a profile
  removes its pairings and sync rows. `sync_playlist_map` (playlist ids are
  global) and `sync_present` (about the library) stay shared. Old rows
  become profile 1.
- The sequence number and the clock stay global; `changes_since(profile,
  after, limit)` returns that profile's rows (gaps are fine for the
  watermark). A playlist/entry uuid that already belongs to another profile
  is never overwritten.
- **Capture runs for all bound profiles together** (`SELECT DISTINCT
  profile_id FROM sync_peers`): the presence snapshot ("reappeared songs")
  is library-wide, so it is read once, favourites/playlists/listens are
  captured per bound profile, and the snapshot is saved once. `apply`
  captures the same set inside its transaction, so a profile that is not the
  peer's still sees a song that reappeared.
- The desktop binds a phone to the profile that was **active when the
  pairing code was opened**; the phone binds its active profile. Pairing
  again re-binds and resets both watermarks (the peer's profile is not
  announced on the wire, so a full re-send is the safe way to fill a new
  profile; merging is idempotent).
- `PeerStatus.profileName` and `PairingInfo/PairingOpen.profileName` tell
  the UI which local profile is synced. The peer's own profile name is not
  transmitted.
- Deleting a profile calls `SyncService::profile_deleted`, which forgets the
  runtime state (secrets, sessions, the phone's client) of the removed
  peers.
- Remote control is unchanged: it drives the computer's player, and listens
  go to the computer's active profile.
- Tests: `a_pairing_syncs_only_its_bound_profile`,
  `every_bound_profile_is_captured_when_a_song_reappears`,
  `deleting_a_bound_profile_removes_its_pairing_and_sync_rows`,
  `migration_v14_to_v15_keeps_sync_rows_in_profile_one` (store) and
  `two_phones_sync_two_different_computer_profiles` (service).

## One pairing per phone profile (decision K25)

A phone keeps **one pairing per phone profile**: each profile can pair with
the same computer or another one (and with whatever computer profile was
active there). Only the active profile's pairing is connected.

- **Link identity.** The computer keys `sync_peers` by the phone's device id
  and checks `batch.from_device`, so each phone profile pairs under its own
  id. Profile 1 keeps the install's `device_id` (pairings made before K25
  keep working); every other profile gets a random 128-bit id, created on
  first use and kept in `sync_meta` (`device_id:profile:<id>`, removed with
  the profile). It is used in the pairing (`pair_connect`), the Noise
  session opening (`link::connect`) and `Batch.from_device` of the phone's
  pages. The computer always uses its own device id.
- **Phone-side rows.** The phone's `sync_peers` row for a computer is keyed
  by the computer's id, which is the same for every profile paired with it.
  The first pairing uses that id as key (so old rows keep working); a
  further pairing of another profile with the same computer gets a random
  row key and `sync_meta` `peer_wire:<key>` = the computer's real id (that
  is what `Batch.from_device` of its pages must equal). `store::pairing_key`
  picks the key; the session loop (`conn::run`) is told the key because the
  Noise handshake only reveals the computer's id.
- **Own-batch check.** A batch whose `from_device` is any of this install's
  ids (device id or any profile's link id) is refused.
- **Clock.** The HLC node id stays the install's device id: there is one
  clock and one sequence per install, stamps stay strictly increasing, and
  two profiles never share a record, so ties cannot happen. It is not wire
  identity.
- **Connection.** `SyncService::start` connects the phone to the computer of
  the active profile; `profile_switch` calls `SyncService::profile_switched`
  after the switch, which closes the old session and connects the new
  profile's pairing (none: just disconnected). Watermarks and pairings of the
  other profiles are untouched. `SyncStatus.activeProfile` and
  `PeerStatus.profileId` let the UI show the active profile's pairing.
- **Pairing and forgetting.** `connect_pair*` replaces only an older pairing
  of the same profile; "Forget this computer" forgets the active profile's.
  The computer needs no change: a second phone profile is simply another
  phone with its own id (the computer lists it under its name; both rows
  show which computer profile they sync).
- Tests: `a_phone_with_two_profiles_pairs_with_two_computers_and_follows_the_profile`,
  `two_phone_profiles_pair_with_the_same_computer_as_two_phones`,
  `each_phone_profile_has_its_own_link_id_and_a_batch_from_it_is_not_foreign`
  (service tests), `computerFor` (UI logic).

## Finding the computer (LAN discovery, decision K25)

So the phone does not need the IP typed: it broadcasts a small UDP probe and
lists the computers that answer; tapping one fills in the address (the code
is still typed or scanned). Sockets live in `sync/link/server.rs`, the wire
format and limits in `sync/link/discovery.rs`.

```text
probe  (phone -> 255.255.255.255:47321 and a.b.c.255:47321 per LAN address):
  "NMDISCOVER" | link protocol version u16 BE | zero padding  (400 bytes)
reply  (computer -> the probing address, unicast, < 400 bytes):
  "NMFOUND" | version u16 BE | TCP port u16 BE | id length u8
          | device id (ASCII) | device name (UTF-8, rest of the datagram)
```

- **Responder** (desktop): a UDP socket on the sync port, open exactly while
  "Allow phone connections" is on (same lifetime as the TCP listener; if the
  bind fails the app just works without discovery). It answers only a
  datagram that is **exactly** the probe, from a LAN source address
  (`is_lan_address`); anything else gets no answer at all. At most 20
  replies per second overall and 2 per second per source address (one-second
  windows, at most 256 sources tracked). Replies are at most 400 bytes (the
  device name is cut to fit) and the probe is padded to 400 bytes, so a
  reply is never larger than the probe: a spoofed probe cannot be used to
  amplify traffic, and only LAN sources are answered anyway.
- **Phone**: `sync_discover` (phone only) sends the probe to the limited
  broadcast address and to the /24 directed broadcast of each LAN IPv4
  address, listens for about 1.5 s, accepts only well-formed replies from LAN
  addresses (magic, version, valid id and name, port ≠ 0), keeps one entry
  per device id (at most 32) and returns `[{deviceId, name, address}]`.
  It runs when the Computer card shows the connect form (and on "Search
  again"); nothing is sent otherwise. Windows or the router may block
  broadcasts: the list is then empty and the QR code / typed address work as
  before.
- **Exposure.** A reply tells any device on the same local network that
  this computer runs NeoModern with phone connections on, its random device
  id, the name the user gave it and the sync port. That is what the pairing
  screen shows and what a port scan of the open port would reveal anyway.
  It contains no secret, no pairing, profile or library information, and it
  is never sent to or accepted from addresses outside the local network.
  Pairing still needs the code shown on the computer. With the switch off
  the UDP port is closed.
- Tests (`sync/link/tests.rs`): `discovery_answers_a_valid_probe_from_a_lan_address`,
  `discovery_ignores_garbage_and_inexact_probes`,
  `discovery_never_answers_non_lan_sources`,
  `discovery_replies_are_rate_limited_per_source`,
  `the_reply_limiter_caps_total_and_per_source_and_recovers`,
  `replies_are_small_and_strictly_parsed`,
  `discover_finds_a_responder_end_to_end_on_loopback`,
  `discover_validates_and_dedups_replies`; service test
  `the_phone_finds_the_computer_by_itself_and_only_while_it_listens`.

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
  sessions, at most 2 from one address; handshake must finish in 5 s; frames ≤ 1 MiB (big batches are
  paged); idle timeout 60 s with keep-alive; 20 commands/s per session.
- **Whitelist**: the remote protocol is a closed `enum` of messages
  (`deny_unknown_fields`). No message carries a file path that the PC
  opens; queue entries are addressed by index plus the queue version (a
  stale version is refused).
- Secrets never go to logs or the problem report.

## Wire protocol (inside Noise)

Frame = `u32` big-endian length + Noise ciphertext (≤ 65 535 bytes per
Noise message; a logical message larger than that is split into numbered
chunks and reassembled, total ≤ 1 MiB). The plaintext is one JSON object
per message, tagged by `type` (camelCase), unknown types and fields
refused (`sync/protocol.rs`):

| `type` | Direction | Fields / meaning |
|---|---|---|
| `hello` | phone → PC, first | `syncVersion`, `appVersion`, `deviceName` |
| `welcome` | PC → phone | same; a different `syncVersion` → `error{code:"version"}` and close |
| `syncOffer` | phone → PC: a round starts. PC → phone: please start one (after "Apply") | – |
| `syncBatch` | both | `batch` (a store `Batch` page, validated before apply) |
| `syncAck` | both | `uptoSeq`: page applied, the sender moves its watermark |
| `syncDone` | both | the sender has no more pages this round |
| `remote` | phone → PC | `id`, `cmd` (`RemoteCmd`, tagged by `kind`) |
| `remoteDone` | PC → phone | `id`, `error: {code, message} \| null` |
| `queue` | PC → phone | `id`, `page` (answer to `queuePage`) |
| `state` | PC → phone | `state` (`RemoteState`), on connect and every player change |
| `position` | PC → phone | `seconds`, `duration`; at most 4/s |
| `ping` / `pong` | both | keep-alive every 20 s; a peer silent for 60 s is dropped |
| `error` | both | `code` (`version`, `mass_delete`, `invalid`, `integrity`, `failed`), `message`, `summary` (mass delete only) |

A sync round, always started by the phone (on connect, every 10 min while
connected, "Sync now", or when the PC sends `syncOffer`):

1. Phone: `syncOffer`, then capture and its pages: `syncBatch` from
   `changes_since(last_seq_sent[PC])`, 2 000 records per page, halved until
   the serialised message is ≤ 960 KiB. Stop-and-wait: the next page goes
   after the `syncAck`.
2. The PC applies each page (`allow_mass_delete` only after "Apply") and
   answers `syncAck`, or `error`: `mass_delete` (the PC records a pending
   decision for that phone and asks "Apply / Skip"; nothing applied, the
   phone's watermark stays), `invalid`, `integrity` (quick_check failed:
   the PC stops syncing with that phone until the app restarts), `failed`.
   An error ends that direction.
3. Phone: `syncDone`. The PC captures and sends its pages the same way;
   then `syncDone` ends the round on both sides.

"Apply" sets an allow-once flag (used up when that peer's direction has
been applied) and asks the phone for a new round; "Skip" clears the
question without touching the watermark, so the next sync asks again.

Remote commands (`RemoteCmd`, closed enum, `kind` tag): `togglePause`,
`play`, `pause`, `next`, `previous`, `seek{seconds}`, `setVolume{percent}`
(0–100), `setShuffle{on}`, `setRepeat{mode}`, `playIndex{index,
queueVersion}` (refused with `stale_queue` when the version is old),
`queuePage{offset, limit ≤ 100}`. Each calls the same `Player` method as the
PC's own Tauri command. 20 commands/s per session; more are answered with
`rate_limited`. `RemoteState` = status, current {title, artist, album,
duration, key}, currentIndex, queueLength, queueVersion, volume, shuffle,
repeat, position. Queue entries carry title, artist and key; the phone
shows its own cover for a key (`sync_cover_for_key`).

## Service

- Desktop: "Allow phone connections" is persisted in `session.json`
  (`allowPhoneConnections`, off by default). On: listen on port 47321 (all
  interfaces, LAN sources only). Off: the listener, the pairing window and
  every phone session close.
- Phone: one paired computer per phone profile (K25). Pairing stores it in
  `sync_peers` plus its address in `sync_meta`; pairing the same profile
  with another computer forgets that profile's old one. While the app runs
  the phone keeps a session to the active profile's computer, reconnecting
  with backoff 2 s → 60 s.
- Local changes are also captured 5 s after the library last changed (not
  during a scan, only with paired devices), so stamps are timely.
- Status (`sync://status`) is a small object: role, device, listening port
  and LAN addresses, pairing code and remaining seconds, peers (kind,
  connected, syncing, last sync, last error, pending guard, last result).

## UI

- Desktop Settings › "Phone": switch "Allow phone connections", address,
  "Pair a phone" (shows the code), paired phones with last sync and Remove,
  "Sync now" per phone not needed (the phone starts syncs).
- Phone Settings › "Computer" shows the active profile's pairing, or the
  connect form when this profile has none: "Computers on this Wi-Fi" (found
  by discovery; tap one to fill in the address), "Scan the QR code",
  "Connect to a computer" (address + code),
  connected state, "Sync now", "Forget", last sync result. A "Remote" screen
  (from the mini-player area / Settings) with the PC's now playing and
  controls. Sync runs on connect and every 10 min while connected.

## Testing

- Store: unit tests for capture, merge, materialise, unresolved keys,
  first-sync rules, idempotence, randomised convergence (2 and 3 devices),
  mass-delete guard, validation, backup rotation.
- Link: pairing (right code, wrong code, expired code), sessions (wrong
  PSK, unknown device, oversized frame, chunking), all over loopback.
- Service (`sync/service_tests.rs`): end-to-end over loopback with port 0:
  two libraries on temp dirs pair (wrong code refused), sync, edit on both
  sides, sync again, converge; the mass-delete guard waits for "Skip" /
  "Apply"; remote commands reach a `Player` with a silent engine, a stale
  `playIndex` is refused, the rate limit holds; turning phone connections
  off closes sessions and the port; removing a phone locks it out; a
  different sync version is refused; pages shrink to fit the size limit;
  the message set is closed.
- Real devices (owner): Windows PC + Android phone on home Wi-Fi; Windows
  firewall prompt on first enable; Android local-network permission on
  newer Android versions.

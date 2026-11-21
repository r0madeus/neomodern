# Local Jam (decision K27) – experimental, off by default

Friends in the same place (same Wi-Fi) add songs to what the computer plays,
from their phones. The music only plays on the host computer, from the
host's own library: nothing is streamed, no file leaves the computer, there
is no server and nothing goes over the internet.

## Rules

- **Off by default, behind one switch on each device.** Settings ›
  Experimental › "Jam" (desktop: host; phone: guest). While the switch is
  off there is no Jam UI and every Jam connection or pairing request is
  refused. Turning it off ends a running Jam at once.
- **Host = desktop only.** A phone joins as a guest; it never hosts.
- **Guests only add songs.** A guest can: see what is playing, see the next
  songs, search the host's library and add a song to the end of the queue.
  Nothing else: no play/pause/skip/seek/volume, no removing or reordering,
  no playlists, favourites, history, settings, files, paths or covers, no
  sync. The guest command set is a closed enum, separate from `RemoteCmd`.
- **Ephemeral.** A Jam lives in memory only. Guests are never written to the
  database and never become paired devices. Ending the Jam, turning the
  switch off or quitting the app drops every guest key and closes their
  connections. A guest cannot rejoin without the current code.
- **Same security as pairing (K21/K23).** Joining uses the same SPAKE2 code
  exchange as pairing, then the same Noise NNpsk0 session, LAN addresses
  only, over the existing listener (`sync/link/server.rs`; no new sockets).

## Flow

1. Host turns the switch on and presses **Start Jam** (desktop, queue
   panel). The listener starts if it is not running (same as "Allow phone
   connections", but only for the Jam's lifetime if that setting is off).
   A 6-digit **Jam code** is shown with a QR code
   `neomodern://jam?v=1&c=<code>&a=<ip:port,...>` (same address rules as
   the pairing link, `sync/pair_link.rs`). The code is valid while the Jam
   runs (no 2-minute expiry); after 10 wrong codes in total it is replaced
   by a new one.
2. Guest (phone, switch on) opens **Join a Jam**: scans the QR or types the
   code (addresses from discovery or typed, like pairing). The phone sends a
   pairing request of a new *jam* kind with a display name ("Device ·
   Profile" style is fine, max 40 chars shown). Both sides derive a fresh
   32-byte key; the host stores `{guest_id (random), name, key}` in memory.
3. The guest opens a session with that id and key. The host recognises a
   Jam guest id and runs the session in **guest mode**: only the Jam
   messages below are accepted; anything else closes the connection.
4. The host sees the guests (name, songs added) and can remove one or end
   the Jam. A removed guest's key is dropped and its session closed.

## Limits

- At most 8 guests per Jam (the listener's session limit grows to fit:
  paired phones + guests; the per-address limit stays).
- A guest adds at most 1 song per 5 s and 20 per 10 minutes; at most 50 of
  the songs after the current one may come from guests (then "the queue is
  full, try later").
- Search: query ≤ 100 characters, ≤ 30 results per page, ≥ 300 ms between
  searches per guest. Results carry `trackId`, title, artist, album,
  duration only (no path, no cover).
- Up next: ≤ 30 entries, title/artist/duration and who added it.
- Every guest message is size-limited and validated like `RemoteCmd`.

## Messages (guest ↔ host, inside the session)

Closed enum `JamCmd`, `deny_unknown_fields`, answered with the same id:

- `jamState {}` → `{ hostName, nowPlaying: {title, artist, durationMs}?,
  playing: bool, upNext: [{title, artist, durationMs, addedBy?}] }`
  (the host also pushes this on every change, at most 2 per second).
- `jamSearch { query, offset, limit }` → `{ total, items: [{trackId, title,
  artist, album, durationMs}] }`
- `jamAdd { trackId }` → ok, or `{ code: rateLimited | queueFull | notFound
  | jamEnded }`. Appends to the end of the host queue through the same
  `Player` method the desktop uses (one queue only).

## Tauri commands and events (contract between backend and UI)

Desktop (host):
- `jam_status()` → `JamStatus { enabled, running, code?, link?, addresses,
  guests: [{id, name, added}], recent: [{title, artist, addedBy}] }`
- `jam_set_enabled(enabled: bool)` → `JamStatus` (off ends a running Jam)
- `jam_start()` / `jam_end()` / `jam_new_code()` → `JamStatus`
- `jam_remove_guest(id: String)` → `JamStatus`
- event `jam://status` with `JamStatus` on every change.

Phone (guest):
- `jam_guest_status()` → `JamGuestStatus { enabled, joined, hostName?,
  connecting, error? }`
- `jam_guest_set_enabled(enabled: bool)`
- `jam_join(address?: String, code: String)` and `jam_join_link(link:
  String)` → `JamGuestStatus`; `jam_leave()`
- `jam_search(query, offset, limit)` → `{ total, items }`
- `jam_add(trackId: i64)` → `()` or an error string the UI shows
- event `jam://guest` (`JamGuestStatus`), `jam://state` (the `jamState`
  answer above, pushed by the host).

The switches are stored with the other app settings (default `false`).

## Tests

- A guest can search and add; the song lands at the end of the host queue
  exactly once; it cannot send any `RemoteCmd`, sync message or unknown
  message (connection closed).
- Jam off: jam pairing and guest sessions refused. Ending the Jam or
  removing a guest closes the session and the key no longer works.
- Rate limits, queue cap, wrong-code replacement after 10 tries, 8-guest
  limit, LAN-only.
- Guests never appear in the database (no peer row after join/leave).
- The socket guard test in `net.rs` still passes (no new sockets).

## Implementation notes

- Joins use connection kind 3 and SPAKE2/HKDF labels of their own, so a Jam
  code never completes a pairing and a pairing code never admits a guest.
  Guest ids are `jam-` + 32 hex; pairing refuses such ids, so the id alone
  routes a session to guest mode (`sync/jam/host.rs`), never to `conn::run`.
- Adds use `Player::append` (the end of the queue, like `queue_append`).
- `JamStatus` also carries `qr` (same shape as pairing) and
  `guests[].connected`; a guest that left stays listed as not connected
  until removed or the Jam ends.
- The host says goodbye (`jamEnded { removed }`) before closing, so the
  phone can tell "the Jam ended" from "you were removed".
- Guests send `jamState` every 20 s as keep-alive; a guest silent for 60 s
  is dropped. Besides the add/search limits, 20 messages/s per guest.
- While the listener runs only for a Jam, paired phones are refused and
  pairing is closed.

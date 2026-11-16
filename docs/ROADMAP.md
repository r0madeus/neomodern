# NeoModern – status and roadmap

Last updated: 2026-11-14 (evening). The owner's decision notes live in the 2ncibeyn
vault (`projects/muzik-calar/`); this file is the in-repo summary for
contributors and agents.

## Done

### v0 scope (decisions document, section 6)
- [x] Folder selection and scanning: tags and covers (SQLite, incremental, cover cache)
- [x] Song list with virtual scrolling
- [x] Album grid with covers and album detail
- [x] Play / pause / seek / next / previous
- [x] Queue (single queue owned by Rust; mpv holds only current + next)
- [x] Gapless playback and ReplayGain
- [x] Synced lyrics panel: local `.lrc` first, then LRCLIB
- [x] Media keys, Windows SMTC, Linux MPRIS

### Beyond v0
- Shuffle and repeat (off / all / one)
- Library search (songs and albums)
- Session persistence: volume, shuffle/repeat, ReplayGain, queue, current track and position
- Settings view: ReplayGain mode, file extension badge, keep playing in the tray, version
- Playlists (schema v2): create, rename, delete, add tracks/albums, reorder, play, save queue as playlist
- Tag editing: single and multiple tracks, only changed fields are written, the loaded file is refused
- System tray: Show, Play/Pause, Next, Previous, Quit; close-to-tray
- Attach a local `.lrc` file manually
- Windows release workflow (`v*` tags) building the NSIS installer
- Turkish UI (`t()` dictionary; follows the system or Settings)
- Single instance: a second launch shows the existing window

### v0.5 (desktop unless noted)
- **Online search and download** (`src-tauri/src/online`): one Search
  view for the library and online results. Albums come from the iTunes
  Search API, tracks and streams from `yt-dlp` (YouTube). Album tracks
  are matched to a recording by ranking the top five hits (length,
  official "Artist - Topic" uploads, no live/cover/remix variants).
  Playing a track queues the rest of its list; stream URLs are resolved
  just in time and never saved with the session. Downloads are tagged,
  get the album cover, land in the library and can be cancelled; every
  `yt-dlp` run has a time limit. Needs `yt-dlp` (one-click setup, PATH
  or a path set in Settings); `ffmpeg` is optional (converts to m4a).
- **Favourites** (schema v4): star tracks, a Favourites list.
- **Playlist covers** (schema v5): automatic 2×2 collage, gradient+icon
  presets or a custom image.
- **Listening history and stats** (schema v6): one row per finished,
  skipped or interrupted listen (≥ 3 s); a stats view with periods, top
  tracks/artists/albums/genres and listening rhythm.
- **Artists** (schema v7): compound tags are split into artists
  (`feat.`/`ft.`, `,` and `;`; `&`/`+`, "Tyler, The Creator" and
  "Earth, Wind & Fire" stay whole; rules shared by Rust and the UI via
  `fixtures/artist-split-cases.json`), an artist directory and profiles
  with portrait (Deezer), bio (Wikipedia) and missing albums (iTunes),
  cached locally.
- **Albums** (schema v8): an album is one (folder, album, album artist)
  group; its year is the most common track year (latest on a tie).
  Same-titled albums in different folders with different years stay
  separate; disc folders of one album merge.
- Sidebar pins for albums and playlists; queue toggle in the player bar.

### Metadata matching (decision K10)
- "Find info" on an album (desktop album view, phone album page) and on a
  single track (tag editor): searches MusicBrainz, ranks releases by track
  count, durations (±3 s), titles and album/artist (0–100; ≥ 85
  recommended, < 50 hidden), shows old → new per field and writes only
  after "Apply". A single track gets the recording's first official studio
  album, else single.
- Writes through the tag editor path (temp file + replace, playing file
  refused) and adds MusicBrainz release / release-group / recording /
  track ids. Old values go to `tag_history` (schema v9); "Undo" restores
  them. Albums without a cover get the Cover Art Archive front cover.
- MusicBrainz: ≤ 1 request per 1.1 s, one retry on HTTP 503, descriptive
  User-Agent. No AcoustID fingerprinting yet (untagged files).
- Phone UI parity: favourites, artists, stats; swipe-back sheets;
  `prefers-reduced-motion` aware animations.

### Android (same app, decision K7)
- Audio through Media3/ExoPlayer behind `AudioEngine`, in a local Tauri
  plugin (`src-tauri/plugins/android-audio`). ExoPlayer holds only
  current + next, like mpv; the queue stays in Rust.
- Background playback via a `MediaSessionService` with a media
  notification; its next/previous go to the Rust queue.
- Engine commands go through a worker thread: mobile plugin calls run on
  the Android main thread and block.
- Desktop-only parts are gated (libmpv, souvlaki, tray menu); lyrics use
  rustls (ring + webpki roots) on Android.
- Library: asks for `READ_MEDIA_AUDIO` and adds the shared `Music` folder.
- CI builds an aarch64 debug APK (artifact `neomodern-android-debug-apk`).

### Look and feel (phone and desktop)
- Phone UI (`src/lib/mobile`, below 640 px): Home / Search / Library tabs
  over a floating frosted gradient bar (with an Albums tile inside Library),
  a mini player, a full-screen player tinted with the cover's colour, the
  line being sung under the cover, a lyrics card and full-screen lyrics
  (follow playback, tap a line to seek), album and playlist pages, cover
  thumbnails, Android back button closes screens, always dark, edge-to-edge
  insets.
- Desktop: light / dark / system-default appearance theme (`theme.svelte.ts`),
  collapsible sidebar with `Ctrl+K` quick-search hint, a now-playing view
  (large cover + synced lyrics) opened from the player bar (with cover-tinted
  ambient sheen), the lyrics panel in the same tinted style, covers in
  song/playlist rows and in the player bar, sidebar icons, album headers
  on the cover's colour.
- Categorised grouped Settings (`All` / `General` / `Playback` / `Library` /
  `Internet` / `About`) with shared `ToggleSwitch` and segmented pill
  controls.

### Home & playback controls (decisions K12, K13)
- **Home & local dynamic mixes (decision K13)**: Home view on both desktop
  and phone powered by local SQLite listening history (`library_home`,
  `library_home_mix`, `library_play_mix`, `library_save_mix_playlist`): up to
  four dynamic mixes (`Weekly Favorites`, `On Repeat`, `Rediscover`, top
  artist/genre mix) plus `Recently played` and `Quick access`, with cold-start
  handling and one-click saving of any mix as a playlist.
- **Playback settings (decision K12)**: persisted `Gapless playback` toggle
  (`weak` / `no` in mpv on desktop; clears engine next-track preloading and
  advances via `Idle` on both platforms when turned off) and Windows-only
  `WASAPI exclusive mode` toggle (`audio-exclusive` with `ao-reload` while
  actively playing).
- The cover's dominant colour is computed in Rust (`library::cover_color`).

### Colours (decision K14)
- The experience stays close to Spotify on purpose. Only the identity layer
  changes: soft blue `accent` (#7CAAFF) instead of teal, and a neutral
  grey with a slight cool tint (`zinc` overridden in `src/app.css`).

### Library navigation and desktop controls (v0.8)
- Sortable columns: Songs sorts in the backend (`SortSpec`, ascending or
  descending, including duration); playlists sort the loaded list.
- Track menu (right-click or the row's "more" button): play, play next
  (`Queue::insert_next`, also under shuffle), add to queue, favourite, add to
  playlist, go to artist or album, edit tags, show in folder.
- Artist and album names are links in every list, the player bar and the
  now-playing screens.
- Settings > Internet: scan all artists for photos and biographies, with
  progress and cancel; respects offline mode and the artist-info switch.
- Sidebar: collapsible, with download progress above Settings; desktop theme
  switch (system / dark / light).
- Desktop keyboard: Space (play/pause), Left/Right (seek 5 s), Ctrl+Left/Right
  (previous/next), Ctrl+Up/Down (volume), M (mute), S (shuffle), R (repeat), Ctrl+K (search). Media keys stay with the
  OS integration in Rust.

### Sharing readiness (2026-11-14)
- **First-run welcome**: on desktop it suggests the OS Music folder with
  a song count, then offers the online tool setup; on Android it asks for
  music access and opens the folder picker. Shown once.
- **One-click yt-dlp / ffmpeg** (`src-tauri/src/online/tools.rs`):
  official builds for Windows and Linux (x86-64, ARM64), checked against
  the published SHA-256 lists, kept in the local app data `tools`
  folder. Lookup: path from Settings, then the downloaded copy, then PATH.
- **Problem report** (Settings → About): version, system, settings and
  the last 400 log lines with the home folder hidden; copy, save, or
  open a GitHub issue.
- **In-app update on Android** (arm64): the update banner's Update
  downloads the release APK, checks it against `SHA256SUMS-android.txt`
  and opens the system installer (one-time "install unknown apps"
  permission). Desktop still opens the release page; the Windows updater
  needs an updater signing key first.
- **Content Security Policy** instead of `csp: null`.
- Genre pages load tracks in pages; Linux MPRIS updates without delay
  (souvlaki's zbus backend).

### v0.9 distribution
- **Linux AppImage** next to the Windows installer and the APK.
- **In-app updates everywhere**: Windows and the AppImage through the
  Tauri updater (signed `latest.json`, key in `TAURI_SIGNING_PRIVATE_KEY`),
  Android through the system installer.

### Listening features (K16, 2026-11-14; desktop and Android)
- **Sleep timer**: 15 min to 2 h or "end of this song" from the moon
  button; the volume fades over the last 10 s, then playback pauses.
- **Equalizer**: ten octave bands and a preamp (±12 dB) with presets, in
  Settings > Playback. mpv uses peaking filters; Android maps the curve
  onto the system equalizer's bands.
- **Crossfade**: 0–12 s. The old track's tail plays on a second player
  (mpv instance / ExoPlayer) while the next one fades in. Not with
  WASAPI exclusive, streams or repeat-one.
- **Multi-select**: Ctrl/Cmd-click and Shift-click (Ctrl+A, Esc) in the
  song, favourite, album, genre and artist lists; long press on phones.
  Bulk play, play next, add to queue, favourite and add to playlist.

### v0.9.1 (2026-11-15, Spotify-style polish)
- **Phones**: song swipes follow the finger (previous / current / next);
  repeated taps no longer stack screens; pushed pages cover the screen
  below; Library tab without the bottom list (import under "+", music
  folders in Settings); pin on album and playlist pages; lyrics card is a
  preview that follows the song (tap for full screen).
- **Desktop**: Spotify-like sidebar (bigger rows, playing list marked, "+"
  menu), album and playlist headers (big title, details line, round play,
  pin, "…" for the rest), simpler playlist rows, "Next in queue" card in the
  now-playing panel, sleep timer in the song menu (bar icon only while it
  runs), no duplicate recent tracks on Home.
- **Everywhere**: plays column in albums and playlists; save button (+ /
  check) with an "Add to playlist" menu; sleep menu no longer hidden.
- **Data**: downloaded album covers, artist pictures and lyrics are kept
  in the data folder (docs/DATA-LAYOUT.md), not lost with the cache.

### PC ↔ phone sync and remote control (K21, experimental, in review)

- Same Wi-Fi only, off by default (desktop Settings › Phone). Pair once
  with a 6-digit code (SPAKE2), then Noise-encrypted sessions per device.
- Syncs favourites, playlists (order, date added) and listening history;
  songs are matched by artist/album/title, missing songs are kept until
  they appear. Per-field last-writer-wins on hybrid logical clocks,
  validation, one transaction per page, backups, mass-delete question.
- The phone controls the PC: play/pause, seek, volume, shuffle/repeat,
  "Up next". Design and limits: `docs/SYNC.md`.
- Not yet tried on real devices (Windows firewall prompt, Android
  local-network access).

## Next

1. **Try metadata matching on real albums** (desktop and phone): the
   MusicBrainz responses so far are recorded fixtures. A live check:
   `cd src-tauri && cargo test live_musicbrainz -- --ignored --nocapture`.
2. **First signed NeoModern release** (Android keystore secrets are set)
   and an app/tray icon.
3. **Later, not decided**: AcoustID fingerprinting for untagged files;
   matching a whole library in the background.

## Known limitations
- Online search/download is desktop only and depends on `yt-dlp`
  (and YouTube); a wrong recording is still possible when no hit is
  close to the album track.
- Metadata matching has only been tested against recorded MusicBrainz
  responses, not the live service.
- Artist splitting is heuristic: a lone "A & B" stays one name (it may be
  a duo or a band); in a comma list the last `&` splits, except for a short
  list of known comma bands and tails such as "& Sons" or "& The …".
- Android: online search and download are desktop only. "Open files"
  (queue screen) plays files stored on the phone; files from a cloud
  drive have no path and are skipped with a note.

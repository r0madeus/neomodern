# External Source Providers (K29)

NeoModern's core (`crates/neomodern-core`) ships with **no built-in online music services**. External catalogs and audio streams are added strictly by the user through the neutral `SourceProvider` interface (`crates/neomodern-core/src/source_provider/`).

All network-backed providers honor `NetPolicy` (Offline Mode blocks all external requests).

## Supported Transports

Users can add any provider from **Settings › External Sources** using its endpoint format:

### 1. HTTP/JSON (`http://` or `https://`)
- Example: `https://catalog.example.com`
- Contract:
  - `GET {base_url}/search?q={query}&limit={limit}` → `ExternalTrack[]` or `{ "tracks": ExternalTrack[] }`
  - `GET {base_url}/stream/{external_id}` → `ResolvedStream` (`{ "url", "mimeType?", "expiresAtMs?" }`)
  - `GET {base_url}/track/{external_id}` → `ExternalTrack`

### 2. OpenSubsonic / Navidrome (`subsonic://` or `subsonics://`)
- Example: `subsonics://username:password@music.example.com:4533`
  - `subsonic://` maps to `http://`; `subsonics://` maps to `https://`.
  - Passwords are redacted in UI listings (`subsonic://username@host`).
- Uses standard OpenSubsonic REST API v1.16.1 (`search3.view`, `getSong.view`, `stream.view`, `getCoverArt.view`).

### 3. Local CLI/JSON Adapter (`cli:<command> [args...]`, desktop only)
- Example: `cli:/usr/local/bin/my-music-adapter --profile lossless`
- Contract:
  - NeoModern spawns the configured executable directly (no shell) with a 15-second timeout and 4 MB stdout cap.
  - Writes one JSON request line to `stdin`:
    - `{"op":"search","query":"...","limit":20}`
    - `{"op":"resolveStream","externalId":"..."}`
    - `{"op":"fetchMetadata","externalId":"..."}`
  - Reads JSON from `stdout` matching `ExternalTrack[]` / `{"tracks":[...]}` (`search`), `ResolvedStream` (`resolveStream`), or `ExternalTrack` (`fetchMetadata`).

## Core Modules vs. External Providers

NeoModern follows a two-layer modular model (exposed together under **Settings › Modules & Extensions**):
- **Core Modules (built-in, zero-config, toggleable):** Synced Lyrics (LRCLIB + optional NetEase fallback), Metadata & Artist Matching (MusicBrainz), LAN Sync & Phone Remote, Party Queue, and Release Update Checks. Every network-capable core module respects `NetPolicy` and offline mode.
- **External Providers (`SourceProvider`):** User-configured `HttpJson`, `Subsonic`, and desktop `Cli` adapters. Each provider advertises `ProviderCapabilities` (`search`, `stream`, `metadata`, `lyrics`) and may optionally implement `fetch_lyrics(...)` so future external lyrics/metadata adapters plug into the same neutral contract without a separate plugin runtime.

## Core Purity (`legacy-online` feature flag)

`neomodern-core` excludes the legacy `online` module by default (`default = []`). Builds that still need legacy bridge compatibility must explicitly opt in with `--features legacy-online`.

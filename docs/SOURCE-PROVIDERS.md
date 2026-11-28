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

## Core Purity (`legacy-online` feature flag)

`neomodern-core` excludes the legacy `online` module by default (`default = []`). Builds that still need legacy bridge compatibility must explicitly opt in with `--features legacy-online`.

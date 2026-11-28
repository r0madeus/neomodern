# NeoModern – rules for AI agents

A free, cross-platform music player: foobar2000-level audio features with a
modern UI. Decisions and their reasons live in the owner's notes
(`projects/muzik-calar/Kararlar.md` in the 2ncibeyn vault); the rules below
are the ones every coding session must follow.

## Stack (versions are pinned – do not bump casually)

- Core: `crates/neomodern-core` (Rust edition 2024), bridged via `flutter_rust_bridge` (`flutter_app/rust`)
- Audio: libmpv through `libmpv2` **7.0.x** on desktop; ExoPlayer bridge on Android
- UI: **Flutter** (`flutter_app/`, Editorial Catalog visual language K30, bundled SIL OFL `Lora` / `Plus Jakarta Sans` / `JetBrains Mono`, `lucide_icons_flutter`)
- Before writing code against a crate or pub package, check the docs for the exact pinned version (docs.rs / pub.dev).

## Architecture rules

1. **Rust is the single source of truth.** Queue, playback state and library
   live in `crates/neomodern-core`. Flutter only renders and sends commands.
2. **One queue only.** The queue is owned by `crates/neomodern-core/src/queue`. mpv is
   given exactly two entries: the current track and the next one
   (`AudioEngine::load` / `AudioEngine::set_next`). Never use mpv's playlist
   as a queue, never add more than one "next" entry.
3. **libmpv is only called inside `crates/neomodern-core/src/audio/`.** Everything else
   uses the `AudioEngine` trait.
4. **No big payloads over FFI.** Lists are paged. Cover art is written to the
   cache folder and loaded from file paths – never base64 over FFI.
5. **Throttle chatty data.** Playback position is sent at most ~4×/s; the UI
   interpolates between updates.
6. Audio plays in native Rust/Android engines, never through web audio elements.

## Scope

Current feature set is listed in `docs/ROADMAP.md` and `docs/SOURCE-PROVIDERS.md`. New
features need the owner's decision first (recorded in `Kararlar.md`); ideas without one
go to a "later" list, not into the code.
External audio catalogs/streams plug into `crates/neomodern-core/src/source_provider`
(`HttpJson`, `Subsonic`, desktop `Cli`); the legacy `online` module is isolated behind
the opt-in `legacy-online` Cargo feature (`default = []`).
PC ↔ phone sync and remote control (K21, `docs/SYNC.md`) live in
`crates/neomodern-core/src/sync`; LAN sockets are only opened in `sync/link/server.rs`
(the guard test in `net.rs` counts them). Sync never changes tracks, files
or tags, and every change to its merge rules needs the convergence tests.

## Conventions

- Code, comments, identifiers, logs, commits and PRs are in English.
- Rust: `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings` clean.
- Flutter: `flutter analyze` and `flutter test` clean.
- Tests must not need a sound card: mpv tests use `ao=null`.

## Commands

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd flutter_app && flutter pub get && flutter analyze && flutter test
```

Linux: `libmpv-dev`, `libssl-dev`, `libasound2-dev`, `libdbus-1-dev`. Windows: run
`scripts/fetch-libmpv.ps1` once; it downloads the LGPL libmpv build into
`vendor/libmpv/`.

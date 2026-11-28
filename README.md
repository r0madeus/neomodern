# NeoModern

A free, cross-platform music player: foobar2000-level audio (gapless,
ReplayGain, every format FFmpeg plays) with a modern interface.

Status: beta (v0.12). Windows, Linux and Android.
Progress and plans: [docs/ROADMAP.md](docs/ROADMAP.md) · External providers: [docs/SOURCE-PROVIDERS.md](docs/SOURCE-PROVIDERS.md).

## Download

From the [latest release](https://github.com/r0madeus/neomodern/releases/latest):

- **Windows**: `NeoModern-x.y.z-windows-x64-setup.exe` or portable `.zip`
  (installs for the current user; Windows SmartScreen may warn because the
  installer is not code-signed).
- **Linux**: `NeoModern-x.y.z-linux-x86_64.AppImage`. Make it executable and run
  it: `chmod +x NeoModern-*.AppImage && ./NeoModern-*.AppImage`.
- **Android**: `NeoModern-x.y.z-android-arm64.apk`.

## Stack

Flutter · Rust (`neomodern-core` + `flutter_rust_bridge`) · libmpv (LGPL build, desktop) · ExoPlayer (Android).
Rules for contributors and AI agents: [AGENTS.md](AGENTS.md).

## Development

### Windows

Prerequisites: Rust (MSVC toolchain), Flutter SDK, Visual Studio C++ build tools.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-libmpv.ps1   # once
cd flutter_app
flutter pub get
flutter run -d windows
```

`fetch-libmpv.ps1` downloads the LGPL libmpv build
([zhongfly/mpv-winbuild](https://github.com/zhongfly/mpv-winbuild)) into
`vendor/libmpv/` and creates the import library. The release bundle ships
`libmpv-2.dll` next to the executable.

### Linux

```bash
sudo apt install libssl-dev libmpv-dev libasound2-dev libdbus-1-dev
cd flutter_app
flutter pub get
flutter run -d linux
```

### Checks

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd flutter_app && flutter analyze && flutter test
```

The release workflow (`v*` tags) builds the Windows NSIS installer + portable zip,
Linux AppImage, and signed Android arm64 APK with `SHA256SUMS.txt`.

## Licensing note

libmpv is used in its LGPL configuration and linked dynamically
(`libmpv-2.dll`, `libmpv.so.2` inside the AppImage), so it can be
replaced by the user.

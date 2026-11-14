# NeoModern

A free, cross-platform music player: foobar2000-level audio (gapless,
ReplayGain, every format FFmpeg plays) with a modern interface.

Status: beta (v0.9). Windows, Linux and Android.
Progress and plans: [docs/ROADMAP.md](docs/ROADMAP.md).

## Download

From the [latest release](https://github.com/r0madeus/neomodern/releases/latest):

- **Windows**: `NeoModern_x.y.z_x64-setup.exe` (installs for the current
  user; Windows SmartScreen may warn because the installer is not
  code-signed).
- **Linux**: `NeoModern_x.y.z_amd64.AppImage`. Make it executable and run
  it: `chmod +x NeoModern_*.AppImage && ./NeoModern_*.AppImage`. Needs a
  distribution with glibc 2.39 or newer (e.g. Ubuntu 24.04, Fedora 40).
- **Android**: `NeoModern-vx.y.z-android-arm64.apk`.

All three update themselves from inside the app (the update banner's
Update). Windows and the AppImage check the release's signed
`latest.json`; Android checks the APK against `SHA256SUMS-android.txt`.

## Stack

Tauri 2 · Rust · libmpv (LGPL build) · Svelte 5 · Vite · Tailwind 4.
Rules for contributors and AI agents: [AGENTS.md](AGENTS.md).

## Development

### Windows

Prerequisites: Rust (MSVC toolchain), Node.js 22, Visual Studio C++ build
tools, WebView2 (preinstalled on Windows 10/11).

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-libmpv.ps1   # once
npm ci
npm run tauri dev
```

`fetch-libmpv.ps1` downloads the LGPL libmpv build
([zhongfly/mpv-winbuild](https://github.com/zhongfly/mpv-winbuild)) into
`src-tauri/lib/` and creates the import library. The installer
(`npm run tauri build`) ships `libmpv-2.dll` next to the executable.

### Linux

```bash
sudo apt install libwebkit2gtk-4.1-dev libxdo-dev libssl-dev \
  libayatana-appindicator3-dev librsvg2-dev libmpv-dev
npm ci
npm run tauri dev
```

Optional for online search and download (desktop): `yt-dlp` on PATH (or
its path set in Settings) and `ffmpeg` for m4a conversion.

### Checks

```bash
npm run check
npm test
cd src-tauri && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
```

CI runs the same checks on Linux and Windows and uploads a Windows installer
as a build artifact. The release workflow (`v*` tags) builds the Windows
installer, the Linux AppImage and the Android APK and publishes
`latest.json` for in-app updates; it needs the `TAURI_SIGNING_PRIVATE_KEY`
(+ password) and `ANDROID_KEYSTORE_*` secrets.

## Licensing note

libmpv is used in its LGPL configuration and linked dynamically
(`libmpv-2.dll`, `libmpv.so.2` inside the AppImage), so it can be
replaced by the user.

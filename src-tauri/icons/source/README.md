# App icon sources

`app-icon.svg` is the NeoModern icon (blue tile, white mark). The Android
adaptive icon uses `android-bg.svg` (background), `android-fg.svg`
(foreground) and `android-mono.svg` (themed icons). Regenerate every icon
after changing them:

```bash
npx tauri icon src-tauri/icons/source/manifest.json
rm -rf src-tauri/icons/ios
```

CI copies `src-tauri/icons/android` into the generated Android project.
The same mark is drawn in the UI by `src/lib/Logo.svelte`.

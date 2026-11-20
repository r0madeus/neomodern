import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import tailwindcss from '@tailwindcss/vite'

// https://v2.tauri.app/start/frontend/vite/
export default defineConfig({
  plugins: [svelte(), tailwindcss()],
  clearScreen: false,
  build: {
    // The oldest web view the UI supports: Chrome/Edge 111 (WebView2 and the
    // Android System WebView, which updates itself through the Play Store)
    // and WebKitGTK as in Safari 16.4. Tailwind 4 needs the same floor, so
    // lowering it would only add code the CSS could not use. Pinned here, not
    // left to Vite's default, so a Vite upgrade cannot raise it unnoticed.
    target: ['chrome111', 'edge111', 'firefox114', 'safari16.4'],
  },
  server: {
    port: 5173,
    strictPort: true,
    watch: { ignored: ['**/src-tauri/**'] },
  },
})

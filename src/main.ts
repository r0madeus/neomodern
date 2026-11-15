import { mount } from 'svelte'
import './app.css'
import App from './App.svelte'

// The webview's own right-click menu (Back, Refresh, Save as, Print…) never
// opens: it is a browser's, not the app's. The app's menus (a song's
// right-click menu) open from their own handlers.
window.addEventListener('contextmenu', (e) => e.preventDefault())

const app = mount(App, {
  target: document.getElementById('app')!,
})

export default app

// Screens that open on top of a tab (album, playlist, now playing, queue…)
// push a history entry, so the Android back button closes the top one
// instead of leaving the app. Closing from the UI goes through history too.

const stack: (() => void)[] = []
let ignorePops = 0
/** A `history.back()` from the UI is on its way; a second tap waits for it. */
let popPending = false
/** Run once the pending `history.back()` has landed (see `popLayer`). */
let afterPop: (() => void)[] = []

window.addEventListener('popstate', () => {
  popPending = false
  if (ignorePops > 0) {
    ignorePops--
  } else {
    stack.pop()?.()
  }
  const run = afterPop
  afterPop = []
  for (const fn of run) fn()
})

/** Registers an open layer; `close` runs when it is dismissed. */
export function pushLayer(close: () => void): void {
  stack.push(close)
  history.pushState({ layer: stack.length }, '')
}

/**
 * Closes the top layer (as if the back button was pressed). A double tap on
 * a back arrow closes one layer, not two: the history move is asynchronous.
 */
export function popLayer(then?: () => void): void {
  if (stack.length === 0) {
    then?.()
    return
  }
  // `then` (e.g. open another screen) waits for the history move, or the
  // late popstate would close the screen it just opened.
  if (then) afterPop.push(then)
  if (popPending) return
  popPending = true
  history.back()
}

/** Closes every layer at once (switching tabs). */
export function clearLayers(): void {
  const n = stack.length
  if (n === 0) return
  const closers = stack.splice(0).reverse()
  ignorePops++
  history.go(-n)
  for (const close of closers) close()
}

/**
 * Replaces the top `count` layers with `replacement` in one atomic history
 * adjustment so closing an overlay and pushing a new screen cannot race.
 */
export function replaceTopLayers(count: number, replacement: () => void): void {
  if (count <= 0 || stack.length === 0) {
    pushLayer(replacement)
    return
  }
  const n = Math.min(count, stack.length)
  const closers = stack.splice(stack.length - n, n, replacement).reverse()
  if (n > 1) {
    ignorePops++
    history.go(-(n - 1))
  }
  for (const close of closers) close()
}

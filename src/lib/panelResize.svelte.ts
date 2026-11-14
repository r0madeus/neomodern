export interface PanelResizeOptions {
  storageKey: string
  defaultWidth: number
  minWidth: number
  maxWidth: number
  /** Side of the window the panel sits on: 'left' grows right, 'right' grows left. */
  side: 'left' | 'right'
  /** Optional pointer width below which a collapsible panel snaps shut. */
  collapseBelow?: number
  collapsedWidth?: number
  isCollapsed?: () => boolean
  onCollapsedChange?: (collapsed: boolean) => void
  getMaxAllowed?: () => number
}

function readStoredWidth(key: string, fallback: number, min: number, max: number): number {
  try {
    const raw = localStorage.getItem(key)
    if (!raw) return fallback
    const n = Number(raw)
    if (Number.isFinite(n)) return Math.max(min, Math.min(max, Math.round(n)))
  } catch {
    // storage unavailable
  }
  return fallback
}

function writeStoredWidth(key: string, width: number): void {
  try {
    localStorage.setItem(key, String(Math.round(width)))
  } catch {
    // storage unavailable
  }
}

/** Pointer and keyboard resize controller for dockable side panels. */
export function createPanelResize(opts: PanelResizeOptions) {
  let width = $state(readStoredWidth(opts.storageKey, opts.defaultWidth, opts.minWidth, opts.maxWidth))
  let dragging = $state(false)

  let startX = 0
  let startWidth = 0
  let prevCursor = ''
  let prevUserSelect = ''

  function effectiveMax(): number {
    const cap = opts.getMaxAllowed ? opts.getMaxAllowed() : opts.maxWidth
    return Math.max(opts.minWidth, Math.min(opts.maxWidth, Math.round(cap)))
  }

  function clamp(value: number): number {
    return Math.max(opts.minWidth, Math.min(effectiveMax(), Math.round(value)))
  }

  const currentWidth = $derived(clamp(width))

  function onPointerMove(e: PointerEvent) {
    if (!dragging) return
    const delta = opts.side === 'left' ? e.clientX - startX : startX - e.clientX
    const raw = startWidth + delta

    if (opts.collapseBelow !== undefined && opts.onCollapsedChange) {
      const collapsed = opts.isCollapsed?.() ?? false
      if (!collapsed && raw < opts.collapseBelow) {
        opts.onCollapsedChange(true)
        return
      }
      if (collapsed && raw >= opts.collapseBelow) {
        opts.onCollapsedChange(false)
        width = clamp(Math.max(opts.minWidth, raw))
        return
      }
      if (collapsed) return
    }

    width = clamp(raw)
  }

  function stopDrag() {
    if (!dragging) return
    dragging = false
    window.removeEventListener('pointermove', onPointerMove)
    window.removeEventListener('pointerup', stopDrag)
    window.removeEventListener('pointercancel', stopDrag)
    window.removeEventListener('blur', stopDrag)
    document.body.style.cursor = prevCursor
    document.body.style.userSelect = prevUserSelect
    if (!(opts.isCollapsed?.() ?? false)) {
      writeStoredWidth(opts.storageKey, currentWidth)
    }
  }

  function onPointerDown(e: PointerEvent) {
    if (e.button !== 0 || e.pointerType === 'touch') return
    e.preventDefault()
    dragging = true
    startX = e.clientX
    const collapsed = opts.isCollapsed?.() ?? false
    startWidth = collapsed ? (opts.collapsedWidth ?? 68) : currentWidth
    prevCursor = document.body.style.cursor
    prevUserSelect = document.body.style.userSelect
    document.body.style.cursor = 'col-resize'
    document.body.style.userSelect = 'none'
    window.addEventListener('pointermove', onPointerMove)
    window.addEventListener('pointerup', stopDrag)
    window.addEventListener('pointercancel', stopDrag)
    window.addEventListener('blur', stopDrag)
  }

  function reset() {
    opts.onCollapsedChange?.(false)
    width = clamp(opts.defaultWidth)
    writeStoredWidth(opts.storageKey, width)
  }

  function onKeyDown(e: KeyboardEvent) {
    const step = e.shiftKey ? 32 : 16
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      e.preventDefault()
      const grow = (opts.side === 'left' && e.key === 'ArrowRight') || (opts.side === 'right' && e.key === 'ArrowLeft')
      if (opts.isCollapsed?.() && grow) {
        opts.onCollapsedChange?.(false)
        width = clamp(opts.minWidth)
      } else if (!(opts.isCollapsed?.() ?? false)) {
        width = clamp(currentWidth + (grow ? step : -step))
      }
      writeStoredWidth(opts.storageKey, width)
    } else if (e.key === 'Home') {
      e.preventDefault()
      reset()
    }
  }

  return {
    get width() {
      return currentWidth
    },
    get dragging() {
      return dragging
    },
    get min() {
      return opts.minWidth
    },
    get max() {
      return effectiveMax()
    },
    onPointerDown,
    onKeyDown,
    reset,
    destroy: stopDrag,
  }
}

export interface DragReorderOptions {
  rowHeight: number
  getCount: () => number
  getEnabled?: () => boolean
  getListEl: () => HTMLElement | null
  getScrollEl: () => HTMLElement | null
  onMove: (from: number, to: number) => void | Promise<void>
}

const DRAG_THRESHOLD_PX = 6
const EDGE_ZONE_PX = 36
const MAX_SCROLL_STEP_PX = 12

/** Pointer-based vertical drag-to-reorder controller for fixed-height lists. */
export function createDragReorder(opts: DragReorderOptions) {
  let from = $state<number | null>(null)
  let gap = $state<number | null>(null)
  let pointer = $state({ x: 0, y: 0 })
  let label = $state('')

  const to = $derived(from !== null && gap !== null ? (gap > from ? gap - 1 : gap) : null)

  let pending: {
    index: number
    label: string
    startX: number
    startY: number
    lastX: number
    lastY: number
  } | null = null
  let rafId: number | null = null
  let prevUserSelect = ''
  let prevCursor = ''
  let dragging = false

  function updateGap(clientY: number) {
    const listEl = opts.getListEl()
    const count = opts.getCount()
    if (!listEl || count <= 0) return
    const top = listEl.getBoundingClientRect().top
    gap = Math.max(0, Math.min(count, Math.round((clientY - top) / opts.rowHeight)))
  }

  function stepAutoScroll() {
    if (!dragging || !pending) {
      rafId = null
      return
    }
    const scrollEl = opts.getScrollEl()
    if (scrollEl) {
      const rect = scrollEl.getBoundingClientRect()
      const y = pending.lastY
      let dy = 0
      if (y < rect.top + EDGE_ZONE_PX && scrollEl.scrollTop > 0) {
        const ratio = Math.min(1, (rect.top + EDGE_ZONE_PX - y) / EDGE_ZONE_PX)
        dy = -Math.ceil(ratio * MAX_SCROLL_STEP_PX)
      } else if (
        y > rect.bottom - EDGE_ZONE_PX &&
        scrollEl.scrollTop + scrollEl.clientHeight < scrollEl.scrollHeight
      ) {
        const ratio = Math.min(1, (y - (rect.bottom - EDGE_ZONE_PX)) / EDGE_ZONE_PX)
        dy = Math.ceil(ratio * MAX_SCROLL_STEP_PX)
      }
      if (dy !== 0) {
        scrollEl.scrollTop += dy
        updateGap(y)
      }
    }
    rafId = requestAnimationFrame(stepAutoScroll)
  }

  function suppressNextClick() {
    const block = (ev: MouseEvent) => {
      ev.preventDefault()
      ev.stopPropagation()
    }
    window.addEventListener('click', block, { capture: true, once: true })
    setTimeout(() => window.removeEventListener('click', block, true), 0)
  }

  function teardownListeners() {
    window.removeEventListener('pointermove', onPointerMove)
    window.removeEventListener('pointerup', onPointerUp)
    window.removeEventListener('pointercancel', onPointerCancel)
    window.removeEventListener('keydown', onKeyDown)
    if (rafId !== null) {
      cancelAnimationFrame(rafId)
      rafId = null
    }
    if (dragging) {
      document.body.style.userSelect = prevUserSelect
      document.body.style.cursor = prevCursor
    }
  }

  function finish(commit: boolean) {
    const wasDragging = dragging
    const moveFrom = from
    const moveTo = to
    teardownListeners()
    pending = null
    dragging = false
    from = null
    gap = null
    label = ''
    if (wasDragging) {
      suppressNextClick()
      if (commit && moveFrom !== null && moveTo !== null && moveTo !== moveFrom) {
        void opts.onMove(moveFrom, moveTo)
      }
    }
  }

  function onPointerMove(e: PointerEvent) {
    if (!pending) return
    pending.lastX = e.clientX
    pending.lastY = e.clientY

    if (!dragging) {
      if (Math.hypot(e.clientX - pending.startX, e.clientY - pending.startY) < DRAG_THRESHOLD_PX) {
        return
      }
      if (opts.getEnabled && !opts.getEnabled()) {
        finish(false)
        return
      }
      dragging = true
      from = pending.index
      label = pending.label
      prevUserSelect = document.body.style.userSelect
      prevCursor = document.body.style.cursor
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'grabbing'
      window.getSelection()?.removeAllRanges()
      pointer = { x: e.clientX, y: e.clientY }
      updateGap(e.clientY)
      rafId = requestAnimationFrame(stepAutoScroll)
    }

    pointer = { x: e.clientX, y: e.clientY }
    updateGap(e.clientY)
  }

  function onPointerUp() {
    finish(true)
  }

  function onPointerCancel() {
    finish(false)
  }

  function onKeyDown(e: KeyboardEvent) {
    if (e.key === 'Escape' && dragging) {
      e.preventDefault()
      e.stopPropagation()
      finish(false)
    }
  }

  function onPointerDown(e: PointerEvent, index: number, itemLabel = '') {
    if (e.button !== 0 || e.pointerType === 'touch') return
    if (e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return
    if (opts.getEnabled && !opts.getEnabled()) return

    const target = e.target as HTMLElement | null
    const interactive = target?.closest(
      'button, a, input, textarea, select, label, [role="checkbox"], [data-no-drag]',
    )
    if (interactive && interactive !== e.currentTarget && !interactive.hasAttribute('data-drag-allow')) {
      return
    }

    finish(false)
    pending = {
      index,
      label: itemLabel,
      startX: e.clientX,
      startY: e.clientY,
      lastX: e.clientX,
      lastY: e.clientY,
    }
    window.addEventListener('pointermove', onPointerMove)
    window.addEventListener('pointerup', onPointerUp)
    window.addEventListener('pointercancel', onPointerCancel)
    window.addEventListener('keydown', onKeyDown)
  }

  function destroy() {
    finish(false)
  }

  return {
    get from() {
      return from
    },
    get gap() {
      return gap
    },
    get to() {
      return to
    },
    get active() {
      return from !== null
    },
    get pointer() {
      return pointer
    },
    get label() {
      return label
    },
    onPointerDown,
    destroy,
  }
}

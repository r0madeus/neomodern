// Moves an element to the end of <body>, so a fixed popup is not clipped or
// repositioned by an ancestor with overflow, transform or backdrop-filter.
export function portal(node: HTMLElement) {
  document.body.appendChild(node)
  return {
    destroy() {
      node.remove()
    },
  }
}

// Spotify-style top bar: the page's title shows in the bar only once the
// big title has scrolled under it. Attach to the big title:
//   <h2 {@attach underTopBar((hidden) => (titleHidden = hidden))}>
const BAR_HEIGHT = 56

export function underTopBar(onChange: (hidden: boolean) => void) {
  return (el: Element) => {
    const io = new IntersectionObserver(
      ([entry]) => onChange(!entry.isIntersecting && entry.boundingClientRect.top < BAR_HEIGHT * 2),
      { rootMargin: `-${BAR_HEIGHT}px 0px 0px 0px` },
    )
    io.observe(el)
    return () => io.disconnect()
  }
}

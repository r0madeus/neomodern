// Scans one QR code with the phone's camera (barcode-scanner plugin). The
// camera is only used while the scanner is open. Used by phone pairing
// (sync.svelte.ts) and joining a Jam (jam.svelte.ts).

export type ScanResult = { ok: true; content: string } | { ok: false; error: string | null }

/** The code's text, or why there is none (`error: null`: the user closed it). */
export async function scanQrCode(): Promise<ScanResult> {
  try {
    const scanner = await import('@tauri-apps/plugin-barcode-scanner')
    let permission = await scanner.checkPermissions()
    if (permission !== 'granted') permission = await scanner.requestPermissions()
    if (permission !== 'granted') return { ok: false, error: 'camera permission was not given' }
    const content = (await scanner.scan({ windowed: false, formats: [scanner.Format.QRCode] })).content
    return { ok: true, content }
  } catch (e) {
    // Closing the scanner is not an error.
    return { ok: false, error: /cancel/i.test(String(e)) ? null : String(e) }
  }
}

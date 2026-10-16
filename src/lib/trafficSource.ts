/**
 * Resolves the traffic source / referrer for visit tracking and orders.
 *
 * Checks query parameters first (utm_source, source, ref), with persistence
 * in sessionStorage so internal page navigation or refreshing preserves the
 * original campaign attribution.
 *
 * If no parameter is present, inspects document.referrer, mapping known
 * Telegram hostnames to 'telegram', and external sites to their hostname.
 */

const STORAGE_KEY = 'cofibuy:traffic_source'

export function resolveTrafficSource(): string {
  // 1. Check if URL currently has explicit attribution params
  if (typeof window !== 'undefined' && window.location?.search) {
    const params = new URLSearchParams(window.location.search)
    const utmSource = params.get('utm_source') || params.get('source') || params.get('ref')
    if (utmSource && utmSource.trim()) {
      const clean = utmSource.trim().toLowerCase()
      try {
        sessionStorage.setItem(STORAGE_KEY, clean)
      } catch {
        // Storage unavailable (e.g. private mode)
      }
      return clean
    }
  }

  // 2. Check if a source was saved in this session earlier
  try {
    const saved = sessionStorage.getItem(STORAGE_KEY)
    if (saved && saved.trim()) {
      return saved.trim()
    }
  } catch {
    // Storage unavailable
  }

  // 3. Fall back to document.referrer
  if (typeof document !== 'undefined' && document.referrer) {
    try {
      const url = new URL(document.referrer)
      if (url.origin !== window.location.origin) {
        const host = url.hostname.toLowerCase()
        if (
          host === 't.me' ||
          host.endsWith('.t.me') ||
          host === 'telegram.org' ||
          host.endsWith('.telegram.org') ||
          host === 'web.telegram.org'
        ) {
          try {
            sessionStorage.setItem(STORAGE_KEY, 'telegram')
          } catch {
            // Storage unavailable
          }
          return 'telegram'
        }
        try {
          sessionStorage.setItem(STORAGE_KEY, host)
        } catch {
          // Storage unavailable
        }
        return host
      }
    } catch {
      // Malformed referrer
    }
  }

  return ''
}

/**
 * Anonymous visit tracking.
 *
 * One beacon per page, once per browser session: the flag lives in
 * sessionStorage, so a refresh or a return within the same tab is not counted
 * twice, while a new session is. The payload carries no identifier of any
 * kind - the country the storefront Worker resolved from Cloudflare's edge
 * geo (itself IP-derived, no IP stored), the device shape parsed from the
 * user agent, and the referring hostname.
 *
 * Failures are silent by design: analytics must never break the page that is
 * being measured.
 */
import { getSupabase } from '@/lib/supabase'
import { parseUserAgent } from '@/lib/userAgent'
import { resolveTrafficSource } from '@/lib/trafficSource'

const sessionKey = (slug: string): string => `pv:${slug}`

/** The same country chain the checkout uses, minus the edge-function hop. */
const resolveGeo = async (): Promise<{ country: string; city: string }> => {
  const fromParam = new URLSearchParams(window.location.search).get('country')
  if (fromParam && /^[A-Za-z]{2}$/.test(fromParam)) {
    return { country: fromParam.toUpperCase(), city: '' }
  }

  try {
    const response = await fetch('/api/geo', { cache: 'no-store' })
    if (response.ok) {
      const data = (await response.json()) as { country?: unknown; city?: unknown }
      const country =
        typeof data.country === 'string' && /^[A-Z]{2}$/.test(data.country) ? data.country : ''
      const city = typeof data.city === 'string' ? data.city : ''
      if (country) return { country, city }
    }
  } catch {
    // Same-origin endpoint missing (plain static host) - fall through.
  }

  const w = window as unknown as { __COFIBUY_GEO__?: unknown; __COFIBUY_GEO_CITY__?: unknown }
  const country =
    typeof w.__COFIBUY_GEO__ === 'string' && /^[A-Z]{2}$/.test(w.__COFIBUY_GEO__)
      ? w.__COFIBUY_GEO__
      : ''
  const city = typeof w.__COFIBUY_GEO_CITY__ === 'string' ? w.__COFIBUY_GEO_CITY__ : ''
  return { country, city }
}

export function trackPageView(slug: string): void {
  if (!slug) return

  // Resolve and cache traffic source on every landing/visit
  const source = resolveTrafficSource()

  try {
    if (sessionStorage.getItem(sessionKey(slug))) return
    sessionStorage.setItem(sessionKey(slug), '1')
  } catch {
    // Storage unavailable (private mode quirks) - track anyway.
  }

  void (async () => {
    try {
      const [{ country, city }] = await Promise.all([resolveGeo()])
      const device = parseUserAgent(navigator.userAgent)
      await getSupabase().rpc('track_page_view', {
        p_slug: slug,
        p_country: country,
        p_city: city,
        p_device_type: device.deviceType,
        p_os: device.os,
        p_browser: device.browser,
        p_referrer: source,
      })
    } catch (err) {
      console.warn('[tracking] page view not recorded:', err)
    }
  })()
}

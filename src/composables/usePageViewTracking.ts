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

const sessionKey = (slug: string): string => `pv:${slug}`

/** The same country chain the checkout uses, minus the edge-function hop. */
const resolveCountry = async (): Promise<string> => {
  const fromParam = new URLSearchParams(window.location.search).get('country')
  if (fromParam && /^[A-Za-z]{2}$/.test(fromParam)) {
    return fromParam.toUpperCase()
  }

  try {
    const response = await fetch('/api/geo', { cache: 'no-store' })
    if (response.ok) {
      const data = (await response.json()) as { country?: unknown }
      if (typeof data.country === 'string' && /^[A-Z]{2}$/.test(data.country)) {
        return data.country
      }
    }
  } catch {
    // Same-origin endpoint missing (plain static host) - fall through.
  }

  const injected = (window as unknown as { __COFIBUY_GEO__?: unknown }).__COFIBUY_GEO__
  return typeof injected === 'string' && /^[A-Z]{2}$/.test(injected) ? injected : ''
}

const referrerHostname = (): string => {
  if (!document.referrer) return ''
  try {
    const url = new URL(document.referrer)
    // Internal navigation says nothing about where the customer came from.
    return url.origin === window.location.origin ? '' : url.hostname
  } catch {
    return ''
  }
}

export function trackPageView(slug: string): void {
  if (!slug) return

  try {
    if (sessionStorage.getItem(sessionKey(slug))) return
    sessionStorage.setItem(sessionKey(slug), '1')
  } catch {
    // Storage unavailable (private mode quirks) - track anyway.
  }

  void (async () => {
    try {
      const [country] = await Promise.all([resolveCountry()])
      const device = parseUserAgent(navigator.userAgent)
      await getSupabase().rpc('track_page_view', {
        p_slug: slug,
        p_country: country,
        p_device_type: device.deviceType,
        p_os: device.os,
        p_browser: device.browser,
        p_referrer: referrerHostname(),
      })
    } catch (err) {
      console.warn('[tracking] page view not recorded:', err)
    }
  })()
}

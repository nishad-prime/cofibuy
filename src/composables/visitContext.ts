/**
 * The visit context a customer's order carries.
 *
 * Snapshot at order creation: the country and city the edge geo resolved
 * (IP-derived; no IP stored anywhere), the device shape parsed from the user
 * agent, and the referring hostname. Every field degrades to empty - the
 * database clamps and nulls whatever looks wrong.
 */
import { parseUserAgent } from '@/lib/userAgent'
import { resolveTrafficSource } from '@/lib/trafficSource'

export interface VisitContext {
  country: string
  city: string
  device_type: string
  os: string
  browser: string
  referrer: string
}

const readCity = (): string => {
  const injected = (window as unknown as { __COFIBUY_GEO_CITY__?: unknown }).__COFIBUY_GEO_CITY__
  return typeof injected === 'string' ? injected : ''
}

/** Resolves the city once; the country usually arrives with the checkout. */
export async function resolveCity(): Promise<string> {
  const injected = readCity()
  if (injected) return injected
  try {
    const response = await fetch('/api/geo', { cache: 'no-store' })
    if (response.ok) {
      const data = (await response.json()) as { city?: unknown }
      return typeof data.city === 'string' ? data.city : ''
    }
  } catch {
    // Same-origin endpoint missing (plain static host) - fine, empty.
  }
  return ''
}

/** Builds the context from whatever the page already knows. */
export function buildVisitContext(country: string | null, city: string): VisitContext {
  const device = parseUserAgent(navigator.userAgent)
  const referrer = resolveTrafficSource()
  return {
    country: country ?? '',
    city,
    device_type: device.deviceType,
    os: device.os,
    browser: device.browser,
    referrer,
  }
}

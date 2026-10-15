/**
 * The visitor's device, from the user agent string alone.
 *
 * Deliberately small: three device buckets, one OS word, one browser word.
 * Exact versions change daily and mean nothing to an operator deciding where
 * to spend attention; the split between mobile and desktop does.
 */

export interface VisitorDevice {
  deviceType: 'mobile' | 'tablet' | 'desktop'
  os: string
  browser: string
}

const OS_TESTS: Array<[RegExp, string]> = [
  [/windows phone/i, 'Windows Phone'],
  [/windows nt|windows/i, 'Windows'],
  [/iphone|ipod/i, 'iOS'],
  [/ipad/i, 'iPadOS'],
  [/android/i, 'Android'],
  [/mac os x|macintosh/i, 'macOS'],
  [/cros/i, 'ChromeOS'],
  [/ubuntu/i, 'Ubuntu'],
  [/linux/i, 'Linux'],
]

const BROWSER_TESTS: Array<[RegExp, string]> = [
  [/edg(?:e|a|ios)?\//i, 'Edge'],
  [/samsungbrowser\//i, 'Samsung Internet'],
  [/opr\/|opera/i, 'Opera'],
  [/firefox|fxios/i, 'Firefox'],
  [/crios\//i, 'Chrome'],
  [/chrome\//i, 'Chrome'],
  [/safari\//i, 'Safari'],
]

const isTablet = (ua: string): boolean =>
  /ipad|tablet|playbook|silk/i.test(ua) || (/android/i.test(ua) && !/mobile/i.test(ua))

const isMobile = (ua: string): boolean =>
  /mobi|iphone|ipod|android|windows phone|blackberry|opera mini|iemobile/i.test(ua)

export function parseUserAgent(ua: string): VisitorDevice {
  const agent = ua || ''

  const deviceType = isTablet(agent) ? 'tablet' : isMobile(agent) ? 'mobile' : 'desktop'

  const os = OS_TESTS.find(([test]) => test.test(agent))?.[1] ?? 'Other'
  const browser = BROWSER_TESTS.find(([test]) => test.test(agent))?.[1] ?? 'Other'

  return { deviceType, os, browser }
}

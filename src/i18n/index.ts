import { DEFAULT_LOCALE, type Locale } from '@/lib/content'
import { createI18n } from 'vue-i18n'
import bnCustomer from './locales/bn/customer.json'
import enCustomer from './locales/en/customer.json'

export const LANG_STORAGE_KEY = 'cofibuy.lang'

/**
 * Locale resolution, in priority order:
 *
 *   1. `?lang=` query override (also the explicit user toggle)
 *   2. an explicit stored preference
 *   3. a geo country/language injected by the optional platform function
 *   4. the browser's language
 *   5. Bangla
 *
 * The inline script in index.html runs the same resolution before first paint
 * and records the result on `window.__COFIBUY_LOCALE__`; that value is
 * preferred here so the two can never disagree and cause a flash.
 */
export function detectLocale(): Locale {
  const precomputed = window.__COFIBUY_LOCALE__
  if (precomputed === 'bn' || precomputed === 'en') return precomputed

  const candidates: (string | null | undefined)[] = [
    new URLSearchParams(window.location.search).get('lang'),
    readStoredLocale(),
    document.documentElement.dataset.geoLang,
    navigator.language,
  ]

  for (const candidate of candidates) {
    const value = candidate?.toLowerCase()
    if (value === 'en') return 'en'
    if (value?.startsWith('bn')) return 'bn'
  }

  return DEFAULT_LOCALE
}

function readStoredLocale(): string | null {
  try {
    return window.localStorage.getItem(LANG_STORAGE_KEY)
  } catch {
    return null
  }
}

export function storeLocale(locale: Locale): void {
  try {
    window.localStorage.setItem(LANG_STORAGE_KEY, locale)
  } catch {
    // Private browsing with storage disabled is not a reason to fail.
  }
}

export const i18n = createI18n({
  legacy: false,
  locale: detectLocale(),
  // R2: opposite-language fallback. The database stores a (_bn, _en) pair and
  // refuses to publish content when both are blank, so a missing translation
  // degrades to the other language rather than rendering nothing.
  fallbackLocale: 'en',
  messages: {
    bn: { customer: bnCustomer },
    en: { customer: enCustomer },
  },
  missingWarn: true,
  fallbackWarn: true,
})

export function setI18nLocale(locale: Locale): void {
  i18n.global.locale.value = locale
  document.documentElement.lang = locale
}

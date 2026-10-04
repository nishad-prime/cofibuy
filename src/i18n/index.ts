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

/**
 * Applies the owner's `default_lang` setting, but only when the visitor has not
 * expressed a preference of their own.
 *
 * The owner default sits below every signal `detectLocale()` already honours, so it
 * only ever replaces the final hardcoded fallback. A `?lang=` link is a deliberate
 * request, a stored value is a previous choice, and a browser or geo language of `en`
 * or `bn` is a real signal -- the owner default must not override any of them.
 *
 * Called after `get_public_settings()` returns, which is later than first paint, so
 * this can change the language under the visitor. It only fires for someone whose
 * browser language is neither Bangla nor English and who has never chosen, which is
 * the one case where the pre-paint script had nothing better than the hardcoded
 * default anyway.
 */
export function applySiteDefaultLocale(locale: Locale): void {
  if (new URLSearchParams(window.location.search).get('lang')) return
  if (readStoredLocale()) return

  const geo = document.documentElement.dataset.geoLang?.toLowerCase()
  if (geo === 'en' || geo?.startsWith('bn')) return

  const nav = navigator.language?.toLowerCase() ?? ''
  if (nav === 'en' || nav.startsWith('bn')) return

  if (i18n.global.locale.value !== locale) setI18nLocale(locale)
}

import { createI18n } from 'vue-i18n'
import { readonly, ref } from 'vue'

/**
 * The admin panel is English-only.
 *
 * A separate i18n instance rather than a second namespace, because the two
 * halves have opposite requirements: customer content is bilingual and falls
 * back between languages, while admin content must fail loudly when a key is
 * missing. `fallbackLocale: false` gives that behaviour — a typo surfaces
 * instead of silently rendering Bangla in an English panel.
 *
 * Messages are behind a dynamic import, so this chunk is only fetched after an
 * admin session check and never reaches a customer. The router awaits
 * `ensureAdminMessages()` before the first admin navigation. This instance is
 * never installed on the app; see `useAdminI18n`.
 */
export const adminI18n = createI18n({
  legacy: false,
  locale: 'en',
  fallbackLocale: false,
  messages: { en: {} },
  missingWarn: true,
  fallbackWarn: true,
  missingRelease: false,
})

const ready = ref(false)
let pending: Promise<void> | null = null

export function ensureAdminMessages(): Promise<void> {
  pending ??= import('./locales/en/admin.json').then((module) => {
    adminI18n.global.setLocaleMessage('en', { admin: module.default })
    ready.value = true
  })
  return pending
}

/**
 * Resolves `admin.*` keys against the admin instance.
 *
 * Note this deliberately does not call `useI18n({ instance: adminI18n })`.
 * vue-i18n ignores that option in the global scope: `useI18n` always returns the
 * composer injected into the app, so the call silently resolved `admin.*` keys
 * against the *customer* instance and rendered raw keys. It also cannot be fixed
 * by installing `adminI18n` on the app, because a second installed instance
 * becomes the injected default for every customer component.
 *
 * `adminI18n.global` is a standalone composer, so it is used directly and the
 * app installs only the customer instance.
 */
export function useAdminI18n() {
  const composer = adminI18n.global
  return {
    t: (key: string): string => composer.t(key),
    ready: readonly(ready),
  }
}

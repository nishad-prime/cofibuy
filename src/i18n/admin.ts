import { createI18n, useI18n } from 'vue-i18n'
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
 * `ensureAdminMessages()` before the first admin navigation.
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

export function useAdminI18n() {
  const scope = useI18n({ instance: adminI18n, useScope: 'global' })
  return { ...scope, ready: readonly(ready) }
}

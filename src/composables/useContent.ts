import type { Locale, LocalizedPair } from '@/lib/content'
import { pickAllContent, pickContent } from '@/lib/content'
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'

/**
 * Resolves database-authored bilingual content against the active locale.
 *
 * Separate from `useI18n` on purpose: strings that ship in the repository are
 * translations of each other and fall back per language, while content columns
 * are authored independently by an admin in `/admin/pages` and resolve
 * per R2 — each side falls back to the other, and a link that has only one
 * language is simply monolingual rather than broken.
 */
export function useContent() {
  const { locale } = useI18n()
  const current = computed<Locale>(() => (locale.value === 'en' ? 'en' : 'bn'))

  return {
    locale: current,
    pick: (pair: LocalizedPair | null | undefined) =>
      pair ? pickContent(pair, current.value) : null,
    pickAll: (pairs: readonly LocalizedPair[]) => pickAllContent(pairs, current.value),
  }
}

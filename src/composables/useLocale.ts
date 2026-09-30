import type { Locale } from '@/lib/content'
import { setI18nLocale, storeLocale } from '@/i18n'
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'

/**
 * The active locale and the switch between the two.
 *
 * A choice made here is a deliberate override, so it is persisted and outranks
 * geo detection on later visits. The inline script in index.html reads the same
 * key before first paint, which is what prevents an English flash.
 */
export function useLocale() {
  const { locale } = useI18n()

  const current = computed<Locale>(() => (locale.value === 'en' ? 'en' : 'bn'))
  const other = computed<Locale>(() => (current.value === 'bn' ? 'en' : 'bn'))

  function set(next: Locale): void {
    storeLocale(next)
    setI18nLocale(next)
  }

  return {
    locale: current,
    otherLocale: other,
    set,
    toggle: () => set(other.value),
  }
}

import { readonly, ref } from 'vue'

/**
 * Whether the page on screen is standalone.
 *
 * A page hidden from the index is sold by its URL alone: no back link on the
 * page, and the layout's brand link goes nowhere. The page itself is the only
 * place that learns this - it arrives in the public payload's `is_listed` -
 * so the view sets it and the layout reads it.
 */
const standalone = ref(false)

export function usePageStandalone() {
  return {
    /** The page view calls this once it knows. */
    setStandalone: (value: boolean): void => {
      standalone.value = value
    },
    isStandalone: readonly(standalone),
  }
}

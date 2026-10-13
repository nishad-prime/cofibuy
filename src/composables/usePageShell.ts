import { readonly, ref } from 'vue'

/**
 * Whether the page on screen draws its own edge-to-edge chrome.
 *
 * A full-bleed template (the dark sales page) owns the viewport's colors: the
 * layout's white header and footer would frame it as a floating card, so the
 * view sets this once it knows which template it rendered and the layout
 * adapts its chrome. Mirrors `usePageStandalone`: the page learns it from the
 * registry, the layout only reads it.
 */
const fullBleed = ref(false)
/** True while a page view is fetching its page: the chrome stays out of the way. */
const pageLoading = ref(false)

export function usePageShell() {
  return {
    /** The page view calls this once the template is resolved. */
    setFullBleed: (value: boolean): void => {
      fullBleed.value = value
    },
    isFullBleed: readonly(fullBleed),
    /** The page view sets this around its fetch; the layout hides the chrome. */
    setPageLoading: (value: boolean): void => {
      pageLoading.value = value
    },
    isPageLoading: readonly(pageLoading),
  }
}

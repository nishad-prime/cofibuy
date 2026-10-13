import { onUnmounted } from 'vue'

/**
 * How template CTAs open the page's payment modal.
 *
 * Templates render buy CTAs above the checkout section - in a hero, in a
 * benefits row, after the FAQ - and every one of them must open the modal
 * itself, not scroll to the section: a scroll forces the customer to find and
 * tap the section's own button, which is two taps where one should do.
 *
 * The modal is hosted by the checkout section, which is a *descendant* of the
 * templates, so provide/inject cannot flow that way. A window event can: the
 * section listens while it is mounted, and each page's own listener dies with
 * it - so navigating to another page cannot inherit a stale "open" state the
 * way a shared module ref would.
 */
const OPEN_EVENT = 'cofibuy:open-checkout'

export function useCheckoutModal() {
  return {
    openCheckout: (): void => {
      window.dispatchEvent(new CustomEvent(OPEN_EVENT))
    },
    /** Binds the listener for one section; call in setup. */
    onOpenCheckout: (handler: () => void): void => {
      window.addEventListener(OPEN_EVENT, handler)
      onUnmounted(() => window.removeEventListener(OPEN_EVENT, handler))
    },
  }
}

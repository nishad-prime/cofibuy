/**
 * The store's configured currency, for the admin panel's money columns.
 *
 * The customer side gets this from `useSiteSettings`, which the customer layout
 * kicks off. Admin routes do not render that layout, so the queue and detail views
 * would otherwise format every amount with the default BDT even after the operator
 * changed the setting. `admin_settings` is owner-only and already returns the whole
 * settings row, so it is the natural source, and one memoised call is shared across
 * the views.
 */
import { readonly, ref } from 'vue'
import { getSupabase } from '@/lib/supabase'
import { DEFAULT_CURRENCY, isSupportedCurrency, type Currency } from '@/lib/currency'

const currency = ref<Currency>(DEFAULT_CURRENCY)

let started: Promise<void> | null = null

export function loadAdminCurrency(): Promise<void> {
  started ??= (async () => {
    try {
      const supabase = getSupabase()
      const { data, error } = await supabase.rpc('admin_settings')
      if (error) return
      const value = (data as { currency?: unknown } | null)?.currency
      if (isSupportedCurrency(value)) currency.value = value
    } catch {
      // Left at BDT. A wrong symbol in an operator view is cosmetic and must not
      // stop the queue from rendering.
    }
  })()

  return started
}

/**
 * Re-point the shared value after the settings page saves.
 *
 * The memoised fetch means a navigation to the queue would otherwise keep the old
 * symbol until a full reload.
 */
export function applyAdminCurrency(value: unknown): void {
  if (isSupportedCurrency(value)) currency.value = value
}

export function useAdminCurrency() {
  return { currency: readonly(currency), load: loadAdminCurrency }
}

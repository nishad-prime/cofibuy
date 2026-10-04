/**
 * Site settings the storefront needs before anyone signs in.
 *
 * Fetched once, through `api.get_public_settings()`, for the same reason copy is:
 * `public.site_settings` has RLS enabled with no policies and no grants, so there
 * is no table read available and a curated projection is the only way.
 *
 * What this deliberately does NOT do:
 *
 *   - Block first paint. A maintenance notice or a hidden form is not worth a blank
 *     page while the database is slow, so a failure resolves to the shipped defaults
 *     and the page renders. The trade is accepted and stated plainly: if the fetch
 *     fails, the order form stays visible and the customer discovers the shop is
 *     closed when the database refuses the order.
 *
 *   - Trust itself over the database. `maintenance_mode` here only decides what to
 *     *show*. `api.create_order()` refuses regardless, so a stale or failed settings
 *     read cannot let an order through. The UI copy is a courtesy; SQL is the gate.
 */
import { readonly, ref } from 'vue'
import { getSupabase } from '@/lib/supabase'
import { applySiteDefaultLocale } from '@/i18n'
import { DEFAULT_CURRENCY, isSupportedCurrency, type Currency } from '@/lib/currency'
import type { Locale } from '@/lib/content'

/**
 * One row of `api.get_public_settings()`.
 *
 * Hand-written for the same reason as `CopyOverride`: the generator resolves a
 * jsonb-returning function to `Json`, which would type every field as `any`.
 */
export interface SiteSettings {
  /** Null when the operator has hidden the global minimum. A number has no read path. */
  min_amount: number | null
  hide_min_amount: boolean
  recovery_enabled: boolean
  maintenance_mode: boolean
  default_lang: Locale
  /** ISO code money is formatted in; always one of the supported list. */
  currency: Currency
  contact: string | null
}

/**
 * The shipped defaults, which are also what a failed fetch leaves in place.
 *
 * `maintenance_mode: false` and `recovery_enabled: false` are the safe directions:
 * a storefront that cannot reach the database should look like a normal shop, not a
 * closed one -- an unnecessary "temporarily closed" banner costs real sales, while a
 * missing one costs nothing because `create_order` refuses anyway.
 */
function defaults(): SiteSettings {
  return {
    min_amount: null,
    hide_min_amount: false,
    recovery_enabled: false,
    maintenance_mode: false,
    default_lang: 'bn',
    currency: DEFAULT_CURRENCY,
    contact: null,
  }
}

const settings = ref<SiteSettings>(defaults())
const loaded = ref(false)

let started: Promise<void> | null = null

function coerce(raw: unknown): SiteSettings {
  const base = defaults()
  if (!raw || typeof raw !== 'object') return base
  const row = raw as Record<string, unknown>

  const rawMin =
    row.min_amount === null || row.min_amount === undefined ? null : Number(row.min_amount)
  const min = rawMin !== null && Number.isFinite(rawMin) ? rawMin : null
  const lang = row.default_lang === 'en' ? 'en' : 'bn'

  return {
    min_amount: min,
    hide_min_amount: row.hide_min_amount === true,
    recovery_enabled: row.recovery_enabled === true,
    maintenance_mode: row.maintenance_mode === true,
    default_lang: lang,
    currency: isSupportedCurrency(row.currency) ? row.currency : DEFAULT_CURRENCY,
    contact:
      typeof row.contact === 'string' && row.contact.trim() !== '' ? row.contact.trim() : null,
  }
}

/** Idempotent and shared, so every caller gets the one request. */
export async function loadSiteSettings(): Promise<void> {
  if (started) return started

  started = (async () => {
    try {
      const supabase = getSupabase()
      const { data, error } = await (
        supabase.rpc as (name: string) => Promise<{ data: unknown; error: unknown }>
      )('get_public_settings')
      if (error) throw error
      settings.value = coerce(data)
      // Only replaces the hardcoded fallback; see `applySiteDefaultLocale`.
      applySiteDefaultLocale(settings.value.default_lang)
    } catch {
      // Left at the defaults. See the note at the top of this file: showing a shop
      // as open when it is closed is recoverable, showing it as closed when it is
      // open is not.
    } finally {
      loaded.value = true
    }
  })()

  return started
}

export function useSiteSettings() {
  return {
    load: loadSiteSettings,
    settings: readonly(settings),
    loaded: readonly(loaded),
    /** True while the shop is closed. Decides what to show, never what is allowed. */
    isMaintenance: (): boolean => settings.value.maintenance_mode,
    isRecoveryAvailable: (): boolean => settings.value.recovery_enabled,
  }
}

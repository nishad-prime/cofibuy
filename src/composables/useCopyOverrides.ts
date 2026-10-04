/**
 * Editable customer copy, fetched once and merged over the bundled locale files.
 *
 * The merge happens inside vue-i18n's message store rather than at each call
 * site. That choice is what keeps this feature small: `t('customer.home.heading')`
 * already works in every view, so writing the override into the same store makes
 * it take effect with no changes to the five customer views and no chance of one
 * of them being missed.
 *
 * What this composable deliberately does NOT do:
 *
 *   - Block first paint. Awaiting here would mean a blank screen whenever the
 *     database is slow or unreachable, to save one wording change. So there is a
 *     bounded wait - `FIRST_PAINT_BUDGET_MS` - after which the app commits to
 *     rendering the bundle and applies overrides whenever they arrive. The
 *     consequence is accepted and should be remembered: on a slow connection the
 *     customer may read the shipped wording for a moment before it changes.
 *
 *   - Touch `adminI18n`. Admin chrome is not customer copy, and merging operator
 *     overrides into it would let the copy editor rewrite the panel that edits it.
 *     `adminI18n` is never installed on the app, so there is nothing to write to.
 */
import { readonly, ref } from 'vue'
import { getSupabase } from '@/lib/supabase'
import { i18n } from '@/i18n'
import type { Locale } from '@/lib/content'

/** Overrides are applied even if the fetch is still running when this elapses. */
const FIRST_PAINT_BUDGET_MS = 1500

/**
 * One row of `api.get_public_copy()`.
 *
 * Hand-written rather than taken from the generated types: the generator maps
 * every `setof`-returning RPC to `Json[]`, because it resolves a composite return
 * type by reading the underlying table and a bare `returns table (...)` does not
 * survive that path. `Database['public']['Tables']['copy_strings']['Row']`
 * describes the table; the RPC returns this projection of it. Same four columns.
 */
export interface CopyOverride {
  key: string
  value_bn: string | null
  value_en: string | null
  is_markdown: boolean
}

const pending = ref(false)
const settled = ref(false)
const failed = ref(false)
/**
 * Only the markdown-flagged keys, not every overridden key. The name used to be
 * `overriddenKeys`, which read as though the admin editor needed the full set; it
 * does not, and the distinction matters where this is consumed - rendering a plain
 * override through MarkdownBody would be the bug this name now rules out.
 */
const markdown = ref<Set<string>>(new Set())

let started: Promise<void> | null = null

/**
 * Recursively merge `override` into `base`, returning a new object.
 *
 * Deep rather than shallow, and that is the whole reason this function exists. The
 * overrides arrive nested - `home.heading` becomes `{ home: { heading } }` - so a
 * shallow spread of the `customer` branch replaces the entire bundled `home` object
 * with a one-key stub. Every other home string would then resolve to nothing and
 * fall through to the fallback locale, which on a Bangla page means the customer
 * sees English. One override would blank four strings.
 *
 * Only plain objects are descended into. An array or a function in the message
 * store is replaced wholesale, which is what a spread would have done anyway and is
 * the only safe reading: a partial merge of an array has no defined result, and
 * vue-i18n allows message functions for pluralisation.
 */
function deepMerge(base: unknown, override: unknown): unknown {
  if (!isPlainObject(base) || !isPlainObject(override)) return override

  const out: Record<string, unknown> = { ...base }

  for (const [key, value] of Object.entries(override)) {
    out[key] = key in out ? deepMerge(out[key], value) : value
  }

  return out
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * vue-i18n's message store is a `Ref<Record<locale, ...>>` under `legacy: false`,
 * and assigning a nested key is not reactive unless the whole object is replaced.
 * So each merge rebuilds the locale's `customer` branch rather than reaching in
 * with `setLocaleMessage` on every row.
 */
function mergeIntoLocale(locale: Locale, nested: Record<string, unknown>): void {
  const messages = i18n.global.messages.value
  const current = messages[locale] ?? {}

  messages[locale] = deepMerge(current, { customer: nested }) as (typeof messages)[Locale]
}

/**
 * Re-nest flat dotted paths into the shape vue-i18n resolves.
 *
 * Overrides are stored flat (`home.heading`) because that is what a human reads
 * in the admin editor, but `t('customer.home.heading')` walks the object, so
 * `home.heading` has to become `{ home: { heading: '...' } }`.
 */
function nest(flat: Record<string, string>): Record<string, unknown> {
  const out: Record<string, unknown> = {}

  for (const [key, value] of Object.entries(flat)) {
    const parts = key.split('.')
    const leaf = parts.pop()
    // The registry shape is checked in copyKeys.ts and every key has at least
    // two segments, so `leaf` cannot actually be undefined here.
    if (leaf === undefined) continue

    let node = out

    for (const part of parts) {
      // Reuse an existing branch so `paywall.amount` and `paywall.amountMin`
      // share one `paywall` object instead of the second overwriting the first.
      const child = node[part]
      const branch = child && typeof child === 'object' ? (child as Record<string, unknown>) : {}
      node[part] = branch
      node = branch
    }

    node[leaf] = value
  }

  return out
}

function apply(rows: CopyOverride[]): void {
  const bn: Record<string, string> = {}
  const en: Record<string, string> = {}
  const flagged = new Set<string>()

  for (const row of rows) {
    if (!row.key) continue
    if (row.value_bn) bn[row.key] = row.value_bn
    if (row.value_en) en[row.key] = row.value_en
    if (row.is_markdown) flagged.add(row.key)
  }

  // One locale can legitimately have nothing set - an operator may translate only
  // Bangla - so this merges whenever there is anything to merge and otherwise
  // leaves the bundle alone. `deepMerge` descends rather than replacing, which is
  // what makes a missing language or key fall back to the bundle instead of blank.
  if (Object.keys(bn).length > 0) mergeIntoLocale('bn', nest(bn))
  if (Object.keys(en).length > 0) mergeIntoLocale('en', nest(en))

  markdown.value = flagged
}

/**
 * Fetch and merge. Idempotent and shared: the layout calls this once, and anything
 * else that asks gets the same promise.
 *
 * The budget is a race between the network and a timer, and both outcomes are
 * fine - that is the point. Whichever lands first, the app renders something
 * correct.
 */
export async function loadCopyOverrides(): Promise<void> {
  if (started) return started

  pending.value = true

  started = (async () => {
    const timeout = new Promise<void>((resolve) => {
      setTimeout(resolve, FIRST_PAINT_BUDGET_MS)
    })

    try {
      const supabase = getSupabase()
      const request = supabase
        .rpc('get_public_copy')
        // Annotated because `getSupabase()` is typed `any` - see src/lib/supabase.ts
        // - so a destructured callback parameter would otherwise be implicitly
        // any and lose the error check.
        .then(({ data, error }: { data: unknown; error: { message: string } | null }) => {
          if (error) throw error
          apply((data ?? []) as CopyOverride[])
        })
        // Attached before the race, not after. If the timer wins and this rejects
        // a moment later with nobody awaiting it, the rejection is unhandled and
        // takes the page down - so the race decides who finishes first, and this
        // is what stops the loser throwing.
        .catch(() => {
          failed.value = true
        })

      await Promise.race([request, timeout])
    } catch {
      // A copy fetch failure is never worth surfacing to a customer. The bundle
      // is the fallback and it is already on screen.
      failed.value = true
    } finally {
      pending.value = false
      settled.value = true
    }
  })()

  return started
}

export function useCopyOverrides() {
  return {
    load: loadCopyOverrides,
    pending: readonly(pending),
    settled: readonly(settled),
    failed: readonly(failed),
    /** Keys stored as markdown. Render those through `MarkdownBody`. */
    markdownKeys: readonly(markdown),
    isMarkdown(key: string): boolean {
      return markdown.value.has(key)
    },
  }
}

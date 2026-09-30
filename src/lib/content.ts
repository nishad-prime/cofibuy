/**
 * Localised content resolution.
 *
 * Every bilingual column is a `(_bn, _en)` pair. Blank and whitespace-only are
 * treated as absent, so `''` and `NULL` can never disagree — the database
 * normalises blank to NULL on write, and this mirrors that.
 *
 * R2 fallback is symmetric: the viewer gets their own language when present,
 * otherwise the other one. A link missing a translation is not a broken page,
 * it is a single-language page.
 */

export type Locale = 'bn' | 'en'

export const LOCALES: readonly Locale[] = ['bn', 'en'] as const

export const DEFAULT_LOCALE: Locale = 'bn'

export type LocalizedPair = {
  bn?: string | null
  en?: string | null
}

/** Trimmed string, or `null` when blank. */
export function normalizeText(value: string | null | undefined): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

/**
 * Resolve a bilingual pair for a viewer.
 *
 * `bn` viewer: Bangla, else English. `en` viewer: English, else Bangla.
 * Returns `null` only when both sides are absent, which the database refuses
 * to let a link be published with.
 */
export function pickContent(pair: LocalizedPair, locale: Locale): string | null {
  const own = normalizeText(locale === 'bn' ? pair.bn : pair.en)
  if (own !== null) return own

  const other = normalizeText(locale === 'bn' ? pair.en : pair.bn)
  return other
}

/** True when the pair has at least one non-blank side. */
export function hasContent(pair: LocalizedPair): boolean {
  return normalizeText(pair.bn) !== null || normalizeText(pair.en) !== null
}

/**
 * Resolves a list of pairs, dropping any that have no content at all.
 *
 * Null and undefined entries are tolerated: these lists come straight from
 * database rows where a missing translation is represented as a null pair, and
 * a rendering pass should skip rather than throw.
 */
export function pickAllContent(
  pairs: readonly (LocalizedPair | null | undefined)[],
  locale: Locale,
): { value: string; index: number }[] {
  const out: { value: string; index: number }[] = []
  pairs.forEach((pair, index) => {
    if (!pair) return
    const value = pickContent(pair, locale)
    if (value !== null) out.push({ value, index })
  })
  return out
}

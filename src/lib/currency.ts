/**
 * The currencies the storefront will format money in.
 *
 * A closed list rather than "any three-letter code": the value is formatted through
 * `Intl.NumberFormat`, so a code the UI never offered is a configuration mistake
 * that would be printed to every customer. The same list is a check constraint in
 * `supabase/migrations/20261004180000_currency_branding.sql`, and
 * `currency.test.ts` reads that file so the two cannot drift.
 *
 * Whole units only. Every amount is stored and shown without a sub-unit, which is
 * why there are no fraction digits in `formatMoney`.
 */
export const CURRENCIES = [
  'BDT',
  'USD',
  'INR',
  'PKR',
  'NPR',
  'LKR',
  'MYR',
  'AED',
  'SAR',
  'EUR',
  'GBP',
] as const

export type Currency = (typeof CURRENCIES)[number]

export const DEFAULT_CURRENCY: Currency = 'BDT'

const SUPPORTED = new Set<string>(CURRENCIES)

export function isSupportedCurrency(value: unknown): value is Currency {
  return typeof value === 'string' && SUPPORTED.has(value)
}

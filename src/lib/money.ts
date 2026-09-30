import type { Locale } from './content'
import { toBengaliDigits } from './digits'

/**
 * Number and date formatting.
 *
 * R1: Bangla viewers see Bengali numerals, English viewers see Latin. Both
 * come from `Intl` rather than hand-rolled formatting, so grouping separators
 * and the Bangla calendar stay correct.
 *
 * The exception is anything the customer *transcribes* into bKash, Nagad or a
 * bank form — those stay Latin in both locales, see `.ltr-value` in main.css.
 */

const CACHE = new Map<string, Intl.NumberFormat>()

function numberFormat(locale: Locale, options: Intl.NumberFormatOptions): Intl.NumberFormat {
  const key = `${locale}:${JSON.stringify(options)}`
  let format = CACHE.get(key)
  if (!format) {
    format = new Intl.NumberFormat(locale === 'bn' ? 'bn-BD' : 'en-US', options)
    CACHE.set(key, format)
  }
  return format
}

const BDT = 'BDT'

/**
 * Money in Bangladeshi taka. BDT paywalls are whole taka, so no fraction
 * digits. `narrowSymbol` gives a bare ৳ rather than "BDT".
 */
export function formatMoney(amount: number, locale: Locale): string {
  if (!Number.isFinite(amount)) amount = 0
  return numberFormat(locale, {
    style: 'currency',
    currency: BDT,
    currencyDisplay: 'narrowSymbol',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  }).format(amount)
}

/** A plain integer, locale numerals. Used for counts and expiry minutes. */
export function formatNumber(value: number, locale: Locale): string {
  if (!Number.isFinite(value)) value = 0
  return numberFormat(locale, { maximumFractionDigits: 0 }).format(value)
}

/** Locale-aware date and time, including the Bangla calendar where relevant. */
export function formatDateTime(value: string | Date, locale: Locale): string {
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  return new Intl.DateTimeFormat(locale === 'bn' ? 'bn-BD' : 'en-US', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date)
}

export function formatDate(value: string | Date, locale: Locale): string {
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  return new Intl.DateTimeFormat(locale === 'bn' ? 'bn-BD' : 'en-US', {
    dateStyle: 'medium',
  }).format(date)
}

/** Digits of an opaque value the customer did not transcribe — counts, ages. */
export function formatDigits(value: string | number, locale: Locale): string {
  const asString = String(value)
  return locale === 'bn' ? toBengaliDigits(asString) : asString
}

/**
 * A value the customer transcribed into another app: TrxIDs, account numbers,
 * reference codes, phone numbers.
 *
 * Deliberately locale-independent. These must stay Latin in *both* locales,
 * because the customer reads them off a bKash SMS or a bank transfer form that
 * they are about to type into, and a Bengali-numeral TrxID cannot be found in
 * a statement search. R1's numeral policy has exactly one exception and this is
 * it — pair with the `.ltr-value` class for direction and isolation.
 */
export function formatReference(value: string): string {
  return value
}

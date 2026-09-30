import { toLatinDigits } from './digits'

/**
 * Bangladesh mobile number normalisation.
 *
 * The same subscriber number reaches us in many shapes — `01712345678`,
 * `+8801712345678`, `8801712345678`, `017 1234 5678`, and `০১৭১২৩৪৫৬৭৮` from a
 * Bangla keyboard. Naive string comparison creates duplicate identities that
 * silently break recovery months later, so everything is reduced to E.164.
 *
 * This is the JS twin of `private.normalize_bd_phone()` in the database. Both
 * must agree; the SQL version is authoritative and this one gives instant
 * feedback in the form.
 *
 * Valid Bangladesh mobile prefixes are 013-019.
 */
const NATIONAL_MOBILE = /^1[3-9]\d{8}$/

export type BdPhoneResult =
  { ok: true; e164: string; national: string } | { ok: false; reason: 'empty' | 'invalid' }

export function normalizeBdPhone(raw: string): BdPhoneResult {
  const digits = toLatinDigits(raw).replace(/\D/g, '')

  if (digits.length === 0) return { ok: false, reason: 'empty' }

  // International access prefix, then the country code, then a national
  // trunk zero. Order matters: strip the longest prefix first.
  let national = digits
  if (national.startsWith('00')) national = national.slice(2)
  if (national.startsWith('880')) national = national.slice(3)
  if (national.startsWith('0')) national = national.slice(1)

  if (!NATIONAL_MOBILE.test(national)) return { ok: false, reason: 'invalid' }

  return { ok: true, e164: `+880${national}`, national }
}

/** Convenience wrapper: the E.164 form, or `null` when the input is not a BD mobile. */
export function bdPhoneOrNull(raw: string): string | null {
  const result = normalizeBdPhone(raw)
  return result.ok ? result.e164 : null
}

/** True when the string is already a valid BD mobile in any accepted format. */
export function isBdPhone(raw: string): boolean {
  return normalizeBdPhone(raw).ok
}

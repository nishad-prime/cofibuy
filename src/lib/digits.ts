/**
 * Bengali digit transliteration.
 *
 * A Bangla keyboard can produce Bengali numerals (০১২৩). Those must be
 * transliterated to Latin ASCII anywhere the value is *compared* — TrxIDs,
 * phone numbers, bank references — because a payment app will have recorded the
 * customer's Latin keystrokes. Getting this wrong means a real, paid order
 * looks like it has no evidence.
 */

const BENGALI_ZERO = 0x09e6

const BENGALI_TO_LATIN: ReadonlyMap<string, string> = new Map(
  Array.from({ length: 10 }, (_, i) => [String.fromCharCode(BENGALI_ZERO + i), String(i)]),
)

const LATIN_TO_BENGALI: ReadonlyMap<string, string> = new Map(
  Array.from({ length: 10 }, (_, i) => [String(i), String.fromCharCode(BENGALI_ZERO + i)]),
)

/** Replaces Bengali numerals with Latin ASCII. Other characters pass through. */
export function toLatinDigits(input: string): string {
  let out = ''
  for (const char of input) {
    out += BENGALI_TO_LATIN.get(char) ?? char
  }
  return out
}

/** Replaces Latin ASCII digits with Bengali numerals. Other characters pass through. */
export function toBengaliDigits(input: string): string {
  let out = ''
  for (const char of input) {
    out += LATIN_TO_BENGALI.get(char) ?? char
  }
  return out
}

/**
 * Normalises a value the customer transcribed, for storage and comparison:
 * transliterate digits, collapse inner whitespace, trim, and uppercase.
 *
 * Applied to TrxIDs, bank references and account numbers. The original
 * keystrokes are always kept alongside it (`value_text_raw`) so an admin can
 * see exactly what was typed.
 */
export function normalizeReference(input: string): string {
  return toLatinDigits(input).replace(/\s+/g, ' ').trim().toUpperCase()
}

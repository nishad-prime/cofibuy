import { describe, expect, it } from 'vitest'
import { formatDate, formatDigits, formatMoney, formatNumber, formatReference } from './money'

const BENGALI_DIGIT = /[০-৯]/
const LATIN_DIGIT = /[0-9]/

describe('R1 numeral policy', () => {
  it('shows Bengali numerals to a Bangla viewer', () => {
    const formatted = formatMoney(1500, 'bn')
    expect(formatted).toMatch(BENGALI_DIGIT)
    expect(formatted).not.toMatch(LATIN_DIGIT)
  })

  it('shows Latin numerals to an English viewer', () => {
    const formatted = formatMoney(1500, 'en')
    expect(formatted).toMatch(LATIN_DIGIT)
    expect(formatted).not.toMatch(BENGALI_DIGIT)
  })

  it('keeps whole taka, because BDT paywalls have no paisa', () => {
    expect(formatMoney(1500, 'en')).not.toMatch(/\.\d/)
    expect(formatMoney(1500, 'bn')).not.toMatch(/\.\d/)
  })

  it('groups thousands', () => {
    expect(formatMoney(1234567, 'en')).toMatch(/1.234.567/)
  })

  it('degrades safely for a non-finite amount rather than printing NaN', () => {
    expect(formatMoney(Number.NaN, 'en')).toBe(formatMoney(0, 'en'))
    expect(formatMoney(Number.POSITIVE_INFINITY, 'bn')).toBe(formatMoney(0, 'bn'))
  })

  it('applies the same rule to plain counts', () => {
    expect(formatNumber(1234567, 'bn')).toMatch(BENGALI_DIGIT)
    expect(formatNumber(1234567, 'en')).toMatch(LATIN_DIGIT)
  })
})

/**
 * R1 has exactly one exception: values the customer transcribes into another
 * app. A Bengali-numeral TrxID cannot be found in a bKash statement search, so
 * these stay Latin in both locales.
 */
describe('transcribed values stay Latin in both locales', () => {
  const transcribed = '9ABC123XYZ'

  it('is unaffected by the locale', () => {
    expect(formatReference(transcribed)).toBe(transcribed)
  })

  it('differs from the display helper, which is the point', () => {
    expect(formatDigits(transcribed, 'bn')).toBe('৯ABC১২৩XYZ')
    expect(formatDigits(transcribed, 'en')).toBe(transcribed)
    expect(formatReference(transcribed)).not.toBe(formatDigits(transcribed, 'bn'))
  })

  it('keeps a phone number usable in both locales', () => {
    expect(formatReference('+8801712345678')).toBe('+8801712345678')
  })
})

describe('formatDigits', () => {
  it('converts only for the Bangla locale', () => {
    expect(formatDigits(42, 'bn')).toBe('৪২')
    expect(formatDigits(42, 'en')).toBe('42')
  })
})

describe('dates', () => {
  it('uses the Bangla calendar for a Bangla viewer', () => {
    const formatted = formatDate('2026-03-09T00:00:00Z', 'bn')
    expect(formatted).toMatch(BENGALI_DIGIT)
  })

  it('returns an empty string for an unparseable date', () => {
    expect(formatDate('not-a-date', 'en')).toBe('')
  })
})

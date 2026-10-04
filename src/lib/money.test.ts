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

/**
 * The unit is taka, and the figure printed has to be the figure the customer
 * types into bKash. Three views used to divide by 100 before printing, which
 * turned a taka 3100 order into "31.00".
 */
describe('taka amounts print unscaled', () => {
  it('shows the entered figure, not a fraction of it', () => {
    expect(formatMoney(100, 'en')).toMatch(/100/)
    expect(formatMoney(100, 'en')).not.toMatch(/1\D?00\./)
  })

  it('does not shrink an order that used to be divided by 100', () => {
    expect(formatMoney(3100, 'en')).toMatch(/3\D?100/)
    expect(formatMoney(3100, 'en')).not.toMatch(/31\D?00\D/)
  })

  it('keeps a four-figure amount whole in Bangla too', () => {
    expect(formatMoney(3100, 'bn')).toMatch(BENGALI_DIGIT)
    expect(formatMoney(3100, 'bn')).toMatch(/৩\D*১০০/)
  })

  it('treats zero as a real amount rather than a missing one', () => {
    expect(formatMoney(0, 'en')).toMatch(/0/)
  })
})

describe('currency is a setting', () => {
  it('formats in the requested currency', () => {
    expect(formatMoney(100, 'en', 'USD')).toMatch(/\$/)
    expect(formatMoney(100, 'en', 'BDT')).toMatch(/৳/)
    expect(formatMoney(100, 'en')).toBe(formatMoney(100, 'en', 'BDT'))
  })

  it('falls back to BDT rather than reaching Intl with an unknown code', () => {
    expect(formatMoney(100, 'en', 'ZZZ')).toBe(formatMoney(100, 'en', 'BDT'))
    expect(formatMoney(100, 'en', '')).toBe(formatMoney(100, 'en', 'BDT'))
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

import { describe, expect, it } from 'vitest'
import { toBengaliDigits, toLatinDigits, normalizeReference } from './digits'

describe('digit transliteration', () => {
  it('maps every Bengali numeral to Latin ASCII', () => {
    expect(toLatinDigits('০১২৩৪৫৬৭৮৯')).toBe('0123456789')
  })

  it('maps every Latin digit to a Bengali numeral', () => {
    expect(toBengaliDigits('0123456789')).toBe('০১২৩৪৫৬৭৮৯')
  })

  it('leaves non-digits untouched in both directions', () => {
    expect(toLatinDigits('TrxID ৯ABC')).toBe('TrxID 9ABC')
    expect(toBengaliDigits('TrxID 9ABC')).toBe('TrxID ৯ABC')
    expect(toBengaliDigits('বাংলা 12')).toBe('বাংলা ১২')
  })

  it('round-trips Latin input back to itself', () => {
    const latin = '012-345 xyz 678'
    expect(toLatinDigits(toBengaliDigits(latin))).toBe(latin)
  })

  it('leaves Bengali input unchanged when converting to Bengali', () => {
    expect(toBengaliDigits('০১২-৩৪৫')).toBe('০১২-৩৪৫')
  })

  it('passes through empty and symbol-only strings', () => {
    expect(toLatinDigits('')).toBe('')
    expect(toBengaliDigits('+-*/')).toBe('+-*/')
  })
})

describe('normalizeReference', () => {
  /**
   * The reason this exists: a customer who types their TrxID with a Bangla
   * keyboard produces Bengali numerals, and searching the bKash statement for
   * those finds nothing. A real, paid order then looks like it has no evidence.
   */
  it('transliterates Bengali digits so a typed TrxID still matches', () => {
    expect(normalizeReference('৯ABC123XYZ')).toBe('9ABC123XYZ')
    expect(normalizeReference('9ABC123XYZ')).toBe('9ABC123XYZ')
  })

  it('upper-cases and trims, because statements are not case sensitive', () => {
    expect(normalizeReference('  9abc123xyz  ')).toBe('9ABC123XYZ')
  })

  it('collapses inner whitespace', () => {
    expect(normalizeReference('9abc   123\txyz')).toBe('9ABC 123 XYZ')
  })

  it('is idempotent', () => {
    const once = normalizeReference(' ৯abc 123 ')
    expect(normalizeReference(once)).toBe(once)
  })

  it('returns an empty string for blank input rather than throwing', () => {
    expect(normalizeReference('')).toBe('')
    expect(normalizeReference('   ')).toBe('')
  })
})

import { describe, expect, it } from 'vitest'
import { bdPhoneOrNull, isBdPhone, normalizeBdPhone } from './phone'

/**
 * The same subscriber number reaches us in several shapes. Getting this wrong
 * creates duplicate identities that silently break recovery months later, so
 * every accepted format must collapse to one E.164 value.
 */
describe('normalizeBdPhone', () => {
  it.each([
    ['01712345678', 'national with trunk zero'],
    ['1712345678', 'national without trunk zero'],
    ['+8801712345678', 'international with plus'],
    ['8801712345678', 'country code without plus'],
    ['008801712345678', 'international access prefix'],
    ['017 1234 5678', 'spaced'],
    ['017-1234-5678', 'hyphenated'],
    ['(017) 1234 5678', 'parenthesised'],
    ['+880 1712 345678', 'spaced international'],
    ['০১৭১২৩৪৫৬৭৮', 'Bengali digits from a Bangla keyboard'],
    ['+৮৮০১৭১২৩৪৫৬৭৮', 'Bengali digits, international'],
  ])('normalises %s (%s)', (input) => {
    expect(normalizeBdPhone(input)).toEqual({
      ok: true,
      e164: '+8801712345678',
      national: '1712345678',
    })
  })

  it('accepts every valid operator prefix 013-019', () => {
    for (let second = 3; second <= 9; second++) {
      const national = `1${second}12345678`
      expect(isBdPhone(`0${national}`)).toBe(true)
    }
  })

  it('rejects prefixes that are not allocated mobile ranges', () => {
    expect(isBdPhone('01012345678')).toBe(false)
    expect(isBdPhone('01112345678')).toBe(false)
    expect(isBdPhone('01212345678')).toBe(false)
  })

  it('rejects wrong lengths', () => {
    expect(isBdPhone('0171234567')).toBe(false)
    expect(isBdPhone('017123456789')).toBe(false)
    expect(isBdPhone('88017123456789')).toBe(false)
  })

  it('reports why it failed', () => {
    // "empty" means nothing digit-like was present to validate at all.
    expect(normalizeBdPhone('   ')).toEqual({ ok: false, reason: 'empty' })
    expect(normalizeBdPhone('')).toEqual({ ok: false, reason: 'empty' })
    expect(normalizeBdPhone('()-')).toEqual({ ok: false, reason: 'empty' })
    expect(normalizeBdPhone('nonsense')).toEqual({ ok: false, reason: 'empty' })

    // "invalid" means digits were found but they are not a BD mobile number.
    expect(normalizeBdPhone('12345')).toEqual({ ok: false, reason: 'invalid' })
    expect(normalizeBdPhone('017123456789')).toEqual({ ok: false, reason: 'invalid' })
  })

  it('is idempotent — re-normalising E.164 changes nothing', () => {
    const once = bdPhoneOrNull('01712345678')
    expect(once).toBe('+8801712345678')
    expect(bdPhoneOrNull(once as string)).toBe(once)
    expect(bdPhoneOrNull(bdPhoneOrNull(once as string) as string)).toBe(once)
  })

  it('collapses distinct spellings of one number to a single identity', () => {
    const spellings = ['01712345678', '+8801712345678', '8801712345678', '০১৭১২৩৪৫৬৭৮']
    const unique = new Set(spellings.map(bdPhoneOrNull))
    expect(unique.size).toBe(1)
  })

  it('keeps genuinely different numbers apart', () => {
    expect(bdPhoneOrNull('01712345678')).not.toBe(bdPhoneOrNull('01912345678'))
  })
})

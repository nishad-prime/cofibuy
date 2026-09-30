import { describe, expect, it } from 'vitest'
import { hasContent, normalizeText, pickAllContent, pickContent } from './content'

/**
 * R2 — symmetric bilingual fallback.
 *
 * The four rows below are the entire contract. The bottom row is unreachable
 * through the UI because the database refuses to publish a link whose content
 * is blank in both languages, but it still has to behave rather than throw.
 */
describe('R2 bilingual fallback', () => {
  const cases = [
    { bn: 'বাংলা', en: 'english', expectBn: 'বাংলা', expectEn: 'english' },
    { bn: 'বাংলা', en: null, expectBn: 'বাংলা', expectEn: 'বাংলা' },
    { bn: null, en: 'english', expectBn: 'english', expectEn: 'english' },
    { bn: null, en: null, expectBn: null, expectEn: null },
  ] as const

  it.each(cases)(
    'bn=$bn en=$en -> bn viewer "$expectBn", en viewer "$expectEn"',
    ({ bn, en, expectBn, expectEn }) => {
      expect(pickContent({ bn, en }, 'bn')).toBe(expectBn)
      expect(pickContent({ bn, en }, 'en')).toBe(expectEn)
    },
  )

  it('treats whitespace-only as absent, in both directions', () => {
    expect(pickContent({ bn: '   ', en: 'english' }, 'bn')).toBe('english')
    expect(pickContent({ bn: 'বাংলা', en: '\t\n ' }, 'en')).toBe('বাংলা')
    expect(pickContent({ bn: '\u00a0', en: '\u00a0' }, 'bn')).toBeNull()
  })

  it('trims surrounding whitespace without altering the content', () => {
    expect(pickContent({ bn: '  বাংলা  ', en: null }, 'bn')).toBe('বাংলা')
  })

  it('is idempotent — resolving twice changes nothing', () => {
    const once = pickContent({ bn: null, en: 'english' }, 'bn')
    expect(once).toBe('english')
    expect(pickContent({ en: once }, 'bn')).toBe('english')
  })
})

describe('normalizeText', () => {
  it('maps blank, whitespace and non-strings to null', () => {
    expect(normalizeText(null)).toBeNull()
    expect(normalizeText(undefined)).toBeNull()
    expect(normalizeText('')).toBeNull()
    expect(normalizeText('  ')).toBeNull()
    expect(normalizeText('\n\t')).toBeNull()
  })

  it('keeps real content', () => {
    expect(normalizeText('  hello  ')).toBe('hello')
    expect(normalizeText('0')).toBe('0')
  })
})

describe('hasContent', () => {
  it('is true when either side is present', () => {
    expect(hasContent({ bn: 'x', en: null })).toBe(true)
    expect(hasContent({ bn: null, en: 'x' })).toBe(true)
    expect(hasContent({ bn: '  ', en: '' })).toBe(false)
  })
})

describe('pickAllContent', () => {
  it('drops fully empty pairs and keeps the source index', () => {
    const pairs = [
      { bn: 'এক', en: 'one' },
      { bn: '  ', en: null },
      { bn: null, en: 'three' },
    ]

    expect(pickAllContent(pairs, 'en')).toEqual([
      { value: 'one', index: 0 },
      { value: 'three', index: 2 },
    ])
    expect(pickAllContent(pairs, 'bn')).toEqual([
      { value: 'এক', index: 0 },
      { value: 'three', index: 2 },
    ])
  })

  it('tolerates null and undefined pairs', () => {
    expect(pickAllContent([null, undefined], 'bn')).toEqual([])
  })
})

import { describe, it, expect, beforeEach } from 'vitest'
import { resolveTrafficSource } from './trafficSource'

const STORAGE_KEY = 'cofibuy:traffic_source'

describe('resolveTrafficSource', () => {
  const setSearch = (search: string): void => {
    window.history.replaceState({}, '', `${window.location.pathname}${search}`)
  }

  const setReferrer = (value: string): void => {
    Object.defineProperty(document, 'referrer', { value, configurable: true })
  }

  beforeEach(() => {
    sessionStorage.clear()
    setSearch('')
    setReferrer('')
  })

  it('prefers utm_source and persists it', () => {
    setSearch('?utm_source=Telegram')
    expect(resolveTrafficSource()).toBe('telegram')
    expect(sessionStorage.getItem(STORAGE_KEY)).toBe('telegram')
  })

  it('accepts source and ref params', () => {
    setSearch('?ref=tg-channel')
    expect(resolveTrafficSource()).toBe('tg-channel')
  })

  it('accepts utm_medium when utm_source is absent', () => {
    setSearch('?utm_medium=facebook')
    expect(resolveTrafficSource()).toBe('facebook')
  })

  it('prefers utm_source over utm_medium', () => {
    setSearch('?utm_source=telegram&utm_medium=social')
    expect(resolveTrafficSource()).toBe('telegram')
  })

  it('keeps the saved source across navigation without params', () => {
    sessionStorage.setItem(STORAGE_KEY, 'telegram')
    expect(resolveTrafficSource()).toBe('telegram')
  })

  it('lets a fresh param override the saved source', () => {
    sessionStorage.setItem(STORAGE_KEY, 'telegram')
    setSearch('?utm_source=facebook')
    expect(resolveTrafficSource()).toBe('facebook')
    expect(sessionStorage.getItem(STORAGE_KEY)).toBe('facebook')
  })

  it('stores telegram hosts verbatim', () => {
    setReferrer('https://t.me/cofibuy/123')
    expect(resolveTrafficSource()).toBe('t.me')

    sessionStorage.clear()
    setSearch('')
    setReferrer('https://org.telegram.messenger/')
    expect(resolveTrafficSource()).toBe('org.telegram.messenger')
  })

  it('uses the hostname of other external referrers', () => {
    setReferrer('https://www.google.com/search?q=x')
    expect(resolveTrafficSource()).toBe('www.google.com')
  })

  it('ignores same-origin referrers', () => {
    setReferrer(`${window.location.origin}/pompom`)
    expect(resolveTrafficSource()).toBe('')
  })

  it('returns empty when nothing is known', () => {
    expect(resolveTrafficSource()).toBe('')
  })

  it('survives an unparseable referrer', () => {
    setReferrer('not a url')
    expect(() => resolveTrafficSource()).not.toThrow()
    expect(resolveTrafficSource()).toBe('')
  })
})

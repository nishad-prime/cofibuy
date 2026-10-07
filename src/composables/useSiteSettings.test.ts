import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The mock's behaviour, held in one variable, for the same reason as
 * `useCopyOverrides.test.ts`: a hoisted factory that reads it at call time keeps a
 * single mock in play while each test still arranges its own answer.
 */
let rpc: (name: string) => Promise<unknown>

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => ({ rpc: (name: string) => rpc(name) }),
}))

/**
 * A fresh composable and i18n per test.
 *
 * `loadSiteSettings` memoises its promise at module scope, so without
 * `resetModules` the first test would own the single fetch and every later test
 * would assert against its data. A fresh `@/i18n` also resets the active locale,
 * which the `default_lang` tests depend on.
 */
import type * as useSiteSettingsModule from '@/composables/useSiteSettings'

async function load(): Promise<{
  settings: typeof useSiteSettingsModule
  locale: () => string
}> {
  vi.resetModules()
  const [settings, i18n] = await Promise.all([
    import('@/composables/useSiteSettings'),
    import('@/i18n'),
  ])
  return { settings, locale: () => i18n.i18n.global.locale.value }
}

const FULL = {
  min_amount: 150,
  hide_min_amount: true,
  recovery_enabled: true,
  maintenance_mode: true,
  default_lang: 'en',
  currency: 'USD',
  contact: '  01700000000  ',
}

beforeEach(() => {
  window.localStorage.clear()
  window.history.replaceState({}, '', '/')
  // Neither Bangla nor English, so `detectLocale` falls through to its hardcoded
  // default and `applySiteDefaultLocale` is the only thing that can move it.
  Object.defineProperty(window.navigator, 'language', { value: 'fr-FR', configurable: true })
  rpc = () => Promise.resolve({ data: FULL, error: null })
})

afterEach(() => {
  vi.restoreAllMocks()
})

function answerWith(data: unknown, error: unknown = null): void {
  rpc = () => Promise.resolve({ data, error })
}

describe('before the fetch lands', () => {
  it('reports the safe defaults: open for business, recovery off', async () => {
    const { settings } = await load()
    const { settings: value } = settings.useSiteSettings()

    // Showing a closed shop when it is open costs sales; showing an open one when it
    // is closed costs nothing, because `create_order` refuses anyway.
    expect(value.value.maintenance_mode).toBe(false)
    expect(value.value.recovery_enabled).toBe(false)
    expect(value.value.min_amount).toBeNull()
    expect(value.value.default_lang).toBe('bn')
    expect(value.value.currency).toBe('BDT')
  })
})

describe('projecting the row', () => {
  it('copies each field and trims contact', async () => {
    const { settings } = await load()
    await settings.loadSiteSettings()

    const { settings: value } = settings.useSiteSettings()
    expect(value.value).toEqual({
      min_amount: 150,
      hide_min_amount: true,
      recovery_enabled: true,
      maintenance_mode: true,
      default_lang: 'en',
      currency: 'USD',
      contact: '01700000000',
      // The index words ride the same projection; a row without them leaves nulls.
      index_heading_en: null,
      index_heading_bn: null,
      index_subheading_en: null,
      index_subheading_bn: null,
    })
  })

  it('treats a non-boolean as false rather than truthy', async () => {
    answerWith({ ...FULL, maintenance_mode: 'yes', recovery_enabled: 1 })

    const { settings } = await load()
    await settings.loadSiteSettings()

    const { settings: value } = settings.useSiteSettings()
    // A stray string must not close the shop: `=== true` is the only thing accepted,
    // so a loosely-typed row cannot silently gate every order.
    expect(value.value.maintenance_mode).toBe(false)
    expect(value.value.recovery_enabled).toBe(false)
  })

  it('falls back to null for a min_amount that is not a number', async () => {
    answerWith({ ...FULL, min_amount: 'lots' })

    const { settings } = await load()
    await settings.loadSiteSettings()

    expect(settings.useSiteSettings().settings.value.min_amount).toBeNull()
  })

  it('falls back to BDT for a currency the app cannot format', async () => {
    answerWith({ ...FULL, currency: 'ZZZ' })

    const { settings } = await load()
    await settings.loadSiteSettings()

    // The select cannot produce this, but a direct write could. BDT is the safe
    // direction: the wrong symbol is recoverable, a throw at format time is not.
    expect(settings.useSiteSettings().settings.value.currency).toBe('BDT')
  })

  it('keeps a hidden minimum null', async () => {
    answerWith({ ...FULL, min_amount: null, hide_min_amount: true })

    const { settings } = await load()
    await settings.loadSiteSettings()

    const { settings: value } = settings.useSiteSettings()
    // The database withholds the number; the client must not turn that into a 0 that
    // could be rendered as a real "minimum ৳0".
    expect(value.value.min_amount).toBeNull()
    expect(value.value.hide_min_amount).toBe(true)
  })

  it('treats a blank contact as no contact', async () => {
    answerWith({ ...FULL, contact: '   ' })

    const { settings } = await load()
    await settings.loadSiteSettings()

    expect(settings.useSiteSettings().settings.value.contact).toBeNull()
  })
})

describe('failure, empty and sharing', () => {
  it('leaves the defaults in place when the fetch fails', async () => {
    answerWith(null, { message: 'network down' })

    const { settings } = await load()
    await expect(settings.loadSiteSettings()).resolves.toBeUndefined()

    const { settings: value, loaded } = settings.useSiteSettings()
    expect(value.value.maintenance_mode).toBe(false)
    expect(loaded.value).toBe(true)
  })

  it('shares one fetch across callers', async () => {
    let calls = 0
    rpc = () => {
      calls += 1
      return Promise.resolve({ data: FULL, error: null })
    }

    const { settings } = await load()
    await Promise.all([
      settings.loadSiteSettings(),
      settings.loadSiteSettings(),
      settings.loadSiteSettings(),
    ])

    // The customer layout calls this on every mount, including client-side
    // navigation. Three calls would be three round trips for the same six fields.
    expect(calls).toBe(1)
  })

  it('answers the accessors from the loaded row', async () => {
    const { settings } = await load()
    await settings.loadSiteSettings()

    const { isMaintenance, isRecoveryAvailable } = settings.useSiteSettings()
    expect(isMaintenance()).toBe(true)
    expect(isRecoveryAvailable()).toBe(true)
  })
})

describe('default_lang as a fallback', () => {
  it('adopts the owner default when the visitor expressed no preference', async () => {
    const { settings, locale } = await load()
    await settings.loadSiteSettings()

    // navigator.language is fr-FR, so the pre-paint script had nothing better than
    // the hardcoded Bangla and the owner's choice is a strict improvement.
    expect(locale()).toBe('en')
  })

  it('does not override an explicit browser language', async () => {
    Object.defineProperty(window.navigator, 'language', { value: 'bn-BD', configurable: true })

    const { settings, locale } = await load()
    // default_lang is en, but the visitor asked for Bangla.
    await settings.loadSiteSettings()

    expect(locale()).toBe('bn')
  })

  it('does not override a stored preference', async () => {
    window.localStorage.setItem('cofibuy.lang', 'en')

    const { settings, locale } = await load()
    // detectLocale honours the stored value; the owner default must not fight it.
    answerWith({ ...FULL, default_lang: 'bn' })
    await settings.loadSiteSettings()

    expect(locale()).toBe('en')
  })

  it('does not override a ?lang= link', async () => {
    window.history.replaceState({}, '', '/?lang=bn')

    const { settings, locale } = await load()
    await settings.loadSiteSettings()

    expect(locale()).toBe('bn')
  })
})

import { describe, expect, it } from 'vitest'
import { COPY_KEYS, copyKeyList, allowsMarkdown, placeholdersIn } from '@/config/copyKeys'
import enCustomer from '@/i18n/locales/en/customer.json'
import bnCustomer from '@/i18n/locales/bn/customer.json'

/** Walk a bundled message file the same way vue-i18n would. */
function resolve(source: unknown, key: string): string | undefined {
  let node: unknown = source
  for (const part of key.split('.')) {
    if (node && typeof node === 'object' && part in (node as Record<string, unknown>)) {
      node = (node as Record<string, unknown>)[part]
    } else {
      return undefined
    }
  }
  return typeof node === 'string' ? node : undefined
}

describe('copy key registry', () => {
  it('has no duplicate keys', () => {
    const list = copyKeyList()
    expect(new Set(list).size).toBe(list.length)
  })

  it('every registered key resolves in both bundled locales', () => {
    const missing: string[] = []

    for (const key of copyKeyList()) {
      if (resolve(enCustomer, key) === undefined) missing.push(`en:${key}`)
      if (resolve(bnCustomer, key) === undefined) missing.push(`bn:${key}`)
    }

    // A key the registry lists but the bundle lacks cannot be overridden: the
    // editor would show an empty box and saving it would change nothing.
    expect(missing).toEqual([])
  })

  it('every bundled key is registered', () => {
    const bundle = (source: unknown, prefix = ''): string[] => {
      const out: string[] = []
      for (const [name, value] of Object.entries(source as Record<string, unknown>)) {
        const key = prefix ? `${prefix}.${name}` : name
        if (value && typeof value === 'object') out.push(...bundle(value, key))
        else out.push(key)
      }
      return out
    }

    const registered = new Set(copyKeyList())
    const unregistered = bundle(enCustomer).filter((k) => !registered.has(k))

    // Drift the other way: a string added to the bundle but not the registry is
    // not editable, which is a choice someone has to make deliberately.
    expect(unregistered).toEqual([])
  })

  it('never allows markdown for a label', () => {
    const labels = ['home.heading', 'home.browse', 'paywall.submit', 'order.title', 'app.name']
    for (const key of labels) {
      expect(allowsMarkdown(key)).toBe(false)
    }
  })

  it('allows markdown only for prose', () => {
    const prose = [
      'recovery.body',
      'paywall.chooseMethodHint',
      'order.evidenceHint',
      'notFound.body',
    ]
    for (const key of prose) {
      expect(allowsMarkdown(key)).toBe(true)
    }
  })

  it('groups every key under a declared namespace', () => {
    for (const [ns, keys] of Object.entries(COPY_KEYS)) {
      for (const key of keys) {
        expect(key.startsWith(`${ns}.`)).toBe(true)
      }
    }
  })

  it('asks for the same placeholders in both locales', () => {
    // The save-time guard used to read only the English bundle, so a Bangla string
    // that had dropped `{amount}` slipped through. Parity is what makes the union of
    // tokens meaningful.
    for (const key of copyKeyList()) {
      const en = placeholdersIn(key, resolve(enCustomer, key) ?? '')
      const bn = placeholdersIn(key, resolve(bnCustomer, key) ?? '')
      expect([...bn].sort(), `${key} (bn)`).toEqual([...en].sort())
    }
  })

  it('keeps every currency symbol out of the copy', () => {
    // The symbol comes from `formatMoney` alone. One baked into a string would
    // shadow the setting and, when a value is also interpolated, print twice.
    const glyph = /[৳$€£¥₹]/
    const offenders: string[] = []
    for (const key of copyKeyList()) {
      if (glyph.test(resolve(enCustomer, key) ?? '')) offenders.push(`en:${key}`)
      if (glyph.test(resolve(bnCustomer, key) ?? '')) offenders.push(`bn:${key}`)
    }
    expect(offenders).toEqual([])
  })
})

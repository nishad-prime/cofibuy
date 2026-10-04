import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import {
  COPY_KEYS,
  copyKeyList,
  allowsMarkdown,
  placeholdersIn,
  isCopyKey,
  MARKDOWN_ALLOWED,
  SIMPLE_COPY,
  simpleCopyKeys,
} from '@/config/copyKeys'
import {
  COPY_FIELD_LABELS,
  COPY_SECTION_TITLES,
  buildCopySections,
  bundled,
} from '@/config/copySections'
import enCustomer from '@/i18n/locales/en/customer.json'
import bnCustomer from '@/i18n/locales/bn/customer.json'

/**
 * The copy length cap lives in SQL because the database is what refuses the write.
 * Read it out of the migration rather than repeating the number, so lowering the cap
 * under the shipped copy fails here instead of at the operator's save.
 */
const here = dirname(fileURLToPath(import.meta.url))

function migration(file: string): string {
  return join(here, '..', '..', 'supabase', 'migrations', file)
}

function readCap(): number {
  const sql = readFileSync(migration('20261004200000_copy_value_limits.sql'), 'utf8')
  return Number(sql.match(/c_max integer := (\d+);/)?.[1])
}

/**
 * The same cap is repeated in a CHECK constraint, because a constraint cannot read a
 * plpgsql variable. Two literals is a second source of truth waiting to drift, so the
 * two are read and compared rather than assumed to agree.
 */
function readConstraintCap(): number {
  const sql = readFileSync(migration('20261004220000_copy_value_length_constraint.sql'), 'utf8')
  return Number(sql.match(/char_length\(value_bn\) <= (\d+)/)?.[1])
}

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

  it('fits every bundled string inside the cap the database enforces', () => {
    const cap = readCap()
    expect(cap).toBeGreaterThan(0)

    // Counted by code point, because that is what Postgres `char_length` counts.
    const offenders: string[] = []
    for (const key of copyKeyList()) {
      for (const [lang, bundle] of [
        ['en', enCustomer],
        ['bn', bnCustomer],
      ] as const) {
        const length = [...(resolve(bundle, key) ?? '')].length
        if (length > cap) offenders.push(`${lang}:${key} (${length} chars)`)
      }
    }

    // A bundled string over the cap is copy the database would refuse to store, so
    // an operator could never restore it.
    expect(offenders).toEqual([])
  })

  it('caps the store constraint at the same number as the function', () => {
    // If these drift, the function accepts a value the table then rejects, and the
    // operator sees a raw constraint violation instead of the sentence the function
    // would have given them.
    expect(readConstraintCap()).toBe(readCap())
  })
})

describe('curated copy view', () => {
  it('only lists keys the registry knows', () => {
    // A key here that the registry lacks would render an empty box, and saving it
    // would be refused by the database as unknown.
    expect(simpleCopyKeys().filter((key) => !isCopyKey(key))).toEqual([])
  })

  it('lists no key twice', () => {
    // A duplicate renders two boxes bound to one draft field, so a save would send
    // the key twice and the operator would see the edit land in the wrong box.
    const list = simpleCopyKeys()
    expect(new Set(list).size).toBe(list.length)
  })

  it('is a strict subset, so the full view is never hidden', () => {
    const curated = new Set(simpleCopyKeys())
    expect(curated.size).toBeLessThan(copyKeyList().length)
    expect(curated.size).toBeGreaterThan(0)
  })

  it('keeps every markdown-capable key reachable in the curated view', () => {
    // Formatted prose is the reason the markdown rule exists, and the six prose keys
    // are all curated. If one were dropped from the tier, an operator reordering the
    // payment instructions would have to drop into the full view to find it.
    const curated = new Set(simpleCopyKeys())
    const orphans = MARKDOWN_ALLOWED.filter((key) => !curated.has(key))
    expect(orphans).toEqual([])
  })

  it('covers every key somewhere, between the two views', () => {
    // The round trip the editor depends on: a key that appears in neither the curated
    // view nor the full view is unreachable, so an operator cannot fix its wording.
    // This is the assertion that was missing before the curated view existed.
    const curated = new Set(simpleCopyKeys())
    const unreachable = copyKeyList().filter((key) => !curated.has(key))
    expect(unreachable).toHaveLength(copyKeyList().length - curated.size)
    expect(unreachable.length).toBeGreaterThan(0)
  })

  it('gives every curated key a real label', () => {
    // `copyKeyLabel` turns `paywall.chooseMethodHint` into "Choose Method Hint",
    // which is fine for a debug list and wrong in an operator form. Keyed by copy key
    // rather than by derived label so the map cannot drift out of step with the tier.
    const unlabelled = simpleCopyKeys().filter((key) => !COPY_FIELD_LABELS[key])
    expect(unlabelled).toEqual([])
  })

  it('gives every curated section a title', () => {
    const untitled = SIMPLE_COPY.filter((section) => !COPY_SECTION_TITLES[section.id])
    expect(untitled.map((section) => section.id)).toEqual([])
  })

  it('carries no label for a key the curated view does not show', () => {
    // A label with nothing behind it is a leftover, and usually means a key was
    // dropped from the tier without noticing.
    const curated = new Set(simpleCopyKeys())
    const stale = Object.keys(COPY_FIELD_LABELS).filter((key) => !curated.has(key))
    expect(stale).toEqual([])
  })
})

describe('copy editor sections', () => {
  const listed = (showAll: boolean, search = '') =>
    buildCopySections(showAll, search).flatMap((section) => [...section.keys])

  it('lists every key in the full view', () => {
    // The full view is the escape hatch. If it ever loses a key, that key becomes
    // uneditable and nothing reports an error - the editor still saves fine.
    expect([...listed(true)].sort()).toEqual([...copyKeyList()].sort())
  })

  it('lists only curated keys in the default view', () => {
    const curated = new Set(simpleCopyKeys())
    const stray = listed(false).filter((key) => !curated.has(key))
    expect(stray).toEqual([])
  })

  it('loses no key to a search, in either view', () => {
    // Searching narrows what is listed, so a key can be absent from the list while
    // still being perfectly editable. These assertions are about the *default*
    // listing above; this one is the guard that a search cannot corrupt the registry.
    for (const showAll of [false, true]) {
      for (const section of buildCopySections(showAll, 'zzz-no-such-copy')) {
        expect(section.keys).toEqual([])
      }
    }
  })

  it('finds a key by its shipped wording, not just its key', () => {
    // The operator reads the storefront, not the source. They will paste the phrase
    // they want to change, so search has to match the text in either language.
    const phrase = bundled('paywall.closedTitle', 'bn')
    expect(phrase.length).toBeGreaterThan(0)
    const hits = listed(true, phrase)
    expect(hits).toContain('paywall.closedTitle')
  })

  it('never repeats a key across sections', () => {
    // A duplicate renders two boxes bound to one draft field, so a save would send the
    // key twice and the edit would appear to land in the wrong box.
    for (const showAll of [false, true]) {
      const keys = listed(showAll)
      expect(new Set(keys).size).toBe(keys.length)
    }
  })

  it('gives every section a heading that is not a bare identifier', () => {
    // A raw `id` leaking into the heading means a section was added without a title.
    const untitled = buildCopySections(false).filter((section) => section.title === section.id)
    expect(untitled.map((section) => section.id)).toEqual([])
  })
})

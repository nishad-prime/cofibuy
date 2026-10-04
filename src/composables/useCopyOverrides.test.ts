import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The mock's behaviour, held in one variable.
 *
 * `vi.doMock` was tried here first and does not reliably override a hoisted
 * `vi.mock`: the request still went to the top-level stub, so a test asserted
 * against an answer the test never arranged. One hoisted factory that reads this at
 * call time keeps a single mock in play and still lets a test hand back a promise
 * it controls.
 */
let rpc: (name: string) => Promise<unknown>

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => ({ rpc: (name: string) => rpc(name) }),
}))

type I18n = typeof import('@/i18n').i18n
type CopyModule = typeof import('@/composables/useCopyOverrides')

/**
 * A fresh `i18n` and a fresh composable per test.
 *
 * Both are needed. `loadCopyOverrides` memoises its promise in a module-level
 * variable, so without `resetModules` the first test to run would own the single
 * fetch and every later test would silently assert against the first test's data.
 * A fresh `@/i18n` also resets the message store, so one test's overrides cannot
 * make another pass.
 */
async function load(): Promise<{ i18n: I18n } & CopyModule> {
  vi.resetModules()
  const [i18nModule, copy] = await Promise.all([
    import('@/i18n'),
    import('@/composables/useCopyOverrides'),
  ])
  return { i18n: i18nModule.i18n, ...copy }
}

function row(key: string, extra: Record<string, unknown> = {}) {
  return { key, value_bn: null, value_en: null, is_markdown: false, ...extra }
}

/** Answer with rows, or fail, or hand control of the response to the caller. */
function answering(opts: { rows?: unknown[]; error?: { message: string } | null } = {}) {
  rpc = () => Promise.resolve({ data: opts.rows ?? [], error: opts.error ?? null })
}

/** A response that never arrives until `send` is called. */
function deferred() {
  let send: (value: unknown) => void = () => {}
  const promise = new Promise((resolve) => {
    send = resolve
  })
  rpc = () => promise
  return send
}

/**
 * Read a key straight out of one locale's message store.
 *
 * Deliberately not `t()`. The app's active locale is `bn`, so `t('customer.x')`
 * answers for Bangla regardless of which locale was overridden, and an English
 * override asserted through it fails while the merge is working correctly. Naming
 * the locale also keeps the "one override must not leak into the other language"
 * assertions honest.
 */
function at(i18n: I18n, locale: 'bn' | 'en', path: string): unknown {
  const bundle = i18n.global.getLocaleMessage(locale) as Record<string, unknown>
  return path.split('.').reduce<unknown>((node, part) => {
    if (node === null || typeof node !== 'object') return undefined
    return (node as Record<string, unknown>)[part]
  }, bundle)
}

beforeEach(() => answering())
afterEach(() => vi.useRealTimers())

describe('overriding a bundled string', () => {
  it('replaces the one key the operator edited', async () => {
    answering({ rows: [row('home.heading', { value_bn: 'XAYIK KAGOJ' })] })

    const { i18n, loadCopyOverrides } = await load()
    await loadCopyOverrides()

    expect(at(i18n, 'bn', 'customer.home.heading')).toBe('XAYIK KAGOJ')
    // And through the real resolver, on the language the app is actually showing.
    expect((i18n.global.t as (key: string) => string)('customer.home.heading')).toBe('XAYIK KAGOJ')
  })

  /**
   * The regression this file exists for.
   *
   * Overrides arrive nested, so `{ home: { heading } }` has to be merged *into* the
   * bundled `home` object. A shallow spread of the `customer` branch instead
   * replaces it wholesale, and every sibling string - `home.subheading`,
   * `home.empty`, `home.browse` - resolves to nothing. On a Bangla page that falls
   * through to English, so one operator editing one heading would quietly switch
   * four strings to the wrong language.
   */
  it('leaves sibling strings in the same namespace alone', async () => {
    answering({ rows: [row('home.heading', { value_bn: 'X' })] })

    const { i18n, loadCopyOverrides } = await load()
    const browse = at(i18n, 'bn', 'customer.home.browse')
    const subheading = at(i18n, 'bn', 'customer.home.subheading')
    const empty = at(i18n, 'bn', 'customer.home.empty')

    await loadCopyOverrides()

    expect(at(i18n, 'bn', 'customer.home.heading')).toBe('X')
    expect(at(i18n, 'bn', 'customer.home.browse')).toBe(browse)
    expect(at(i18n, 'bn', 'customer.home.subheading')).toBe(subheading)
    expect(at(i18n, 'bn', 'customer.home.empty')).toBe(empty)
    // Guards against the degenerate fix: a merge that dropped the siblings would
    // satisfy the three assertions above if the bundle had been empty.
    expect(browse).not.toBeUndefined()
  })

  it('merges sibling overrides in one namespace without losing each other', async () => {
    answering({
      rows: [
        row('paywall.amount', { value_en: 'A' }),
        row('paywall.amountMin', { value_en: 'B' }),
        row('paywall.submit', { value_en: 'C' }),
      ],
    })

    const { i18n, loadCopyOverrides } = await load()
    await loadCopyOverrides()

    expect(at(i18n, 'en', 'customer.paywall.amount')).toBe('A')
    expect(at(i18n, 'en', 'customer.paywall.amountMin')).toBe('B')
    expect(at(i18n, 'en', 'customer.paywall.submit')).toBe('C')
  })

  it('leaves other namespaces and other top-level branches alone', async () => {
    answering({
      rows: [row('home.heading', { value_en: 'X' }), row('paywall.submit', { value_en: 'Y' })],
    })

    const { i18n, loadCopyOverrides } = await load()
    const reference = at(i18n, 'en', 'customer.order.reference')
    const topLevel = at(i18n, 'en', 'lang') // a sibling of `customer`

    await loadCopyOverrides()

    expect(at(i18n, 'en', 'customer.home.heading')).toBe('X')
    expect(at(i18n, 'en', 'customer.paywall.submit')).toBe('Y')
    expect(at(i18n, 'en', 'customer.order.reference')).toBe(reference)
    expect(at(i18n, 'en', 'lang')).toBe(topLevel)
  })

  it('merges a three-level path without discarding its parent object', async () => {
    answering({ rows: [row('order.status.approved', { value_en: 'Granted' })] })

    const { i18n, loadCopyOverrides } = await load()
    const rejected = at(i18n, 'en', 'customer.order.status.rejected')

    await loadCopyOverrides()

    expect(at(i18n, 'en', 'customer.order.status.approved')).toBe('Granted')
    // `status` is an object of seven labels. Replacing it would leave only
    // `approved`, and every other status badge on the order page would go blank.
    expect(at(i18n, 'en', 'customer.order.status.rejected')).toBe(rejected)
  })

  it('does not rebuild a locale that received no override', async () => {
    answering({ rows: [row('home.heading', { value_en: 'X' })] })

    const { i18n, loadCopyOverrides } = await load()
    const beforeBn = i18n.global.messages.value.bn

    await loadCopyOverrides()

    // Only English was overridden, so the Bangla bundle should still be the same
    // object reference. Replacing it is harmless in content terms but would re-render
    // every Bangla-bound component for an edit that cannot affect them.
    expect(i18n.global.messages.value.bn).toBe(beforeBn)
  })
})

describe('bilingual fallback', () => {
  it('keeps the bundled Bangla text when only English is overridden', async () => {
    answering({ rows: [row('notFound.body', { value_en: 'English only' })] })

    const { i18n, loadCopyOverrides } = await load()
    const bundledBn = at(i18n, 'bn', 'customer.notFound.body')

    await loadCopyOverrides()

    expect(at(i18n, 'en', 'customer.notFound.body')).toBe('English only')
    // An operator who has translated only one language must not blank the other.
    expect(at(i18n, 'bn', 'customer.notFound.body')).toBe(bundledBn)
    expect(bundledBn).not.toBeUndefined()
  })

  it('does not leak a Bangla override onto an English page', async () => {
    answering({ rows: [row('notFound.body', { value_bn: 'BANGLA ONLY' })] })

    const { i18n, loadCopyOverrides } = await load()
    const bundledEn = at(i18n, 'en', 'customer.notFound.body')

    await loadCopyOverrides()

    expect(at(i18n, 'bn', 'customer.notFound.body')).toBe('BANGLA ONLY')
    // Copying the Bangla override into English would be a guess about what the
    // operator wanted, and it would show Bangla to a customer who chose English.
    expect(at(i18n, 'en', 'customer.notFound.body')).toBe(bundledEn)
  })

  it('keeps both languages when both are overridden', async () => {
    answering({ rows: [row('notFound.body', { value_bn: 'BN', value_en: 'EN' })] })

    const { i18n, loadCopyOverrides } = await load()
    await loadCopyOverrides()

    expect(at(i18n, 'bn', 'customer.notFound.body')).toBe('BN')
    expect(at(i18n, 'en', 'customer.notFound.body')).toBe('EN')
  })
})

describe('markdown flags', () => {
  it('reports only the keys stored as markdown', async () => {
    answering({
      rows: [
        row('recovery.body', { value_en: 'Read **this**', is_markdown: true }),
        row('home.heading', { value_en: 'Plain' }),
      ],
    })

    const { loadCopyOverrides, useCopyOverrides } = await load()
    await loadCopyOverrides()

    const { isMarkdown, markdownKeys } = useCopyOverrides()
    expect(isMarkdown('recovery.body')).toBe(true)
    // A plain override must not be reported as markdown: the render path branches on
    // this flag, and a false positive would pipe a label through the markdown
    // renderer, which is the injection surface the registry exists to prevent.
    expect(isMarkdown('home.heading')).toBe(false)
    expect([...markdownKeys.value]).toEqual(['recovery.body'])
  })

  it('reports nothing when no row is flagged', async () => {
    answering({ rows: [row('home.heading', { value_en: 'Plain' })] })

    const { loadCopyOverrides, useCopyOverrides } = await load()
    await loadCopyOverrides()

    expect(useCopyOverrides().markdownKeys.value.size).toBe(0)
  })
})

describe('failure and empty states', () => {
  it('leaves every bundled string readable when the fetch fails', async () => {
    answering({ error: { message: 'network down' } })

    const { i18n, loadCopyOverrides, useCopyOverrides } = await load()
    await expect(loadCopyOverrides()).resolves.toBeUndefined()

    expect(at(i18n, 'bn', 'customer.home.heading')).not.toBeUndefined()
    expect(at(i18n, 'bn', 'customer.paywall.submit')).not.toBeUndefined()
    expect(useCopyOverrides().failed.value).toBe(true)
    expect(useCopyOverrides().settled.value).toBe(true)
  })

  it('treats an empty payload as no overrides', async () => {
    answering({ rows: [] })

    const { i18n, loadCopyOverrides, useCopyOverrides } = await load()
    await loadCopyOverrides()

    expect(at(i18n, 'bn', 'customer.home.heading')).not.toBeUndefined()
    expect(useCopyOverrides().failed.value).toBe(false)
  })

  it('ignores a row with an empty key', async () => {
    answering({ rows: [row(''), row('home.heading', { value_en: 'Kept' })] })

    const { i18n, loadCopyOverrides } = await load()
    await loadCopyOverrides()

    expect(at(i18n, 'en', 'customer.home.heading')).toBe('Kept')
    expect(Object.keys(i18n.global.getLocaleMessage('en') as object)).not.toContain('')
  })

  it('does not let a blank value replace real copy', async () => {
    answering({ rows: [row('home.heading', { value_bn: '', value_en: '' })] })

    const { i18n, loadCopyOverrides } = await load()
    const bundled = at(i18n, 'en', 'customer.home.heading')

    await loadCopyOverrides()

    // The database deletes rows where both languages are blank, so this should never
    // reach the client. If it ever does, an empty string replaces real copy and the
    // page renders a blank heading.
    expect(at(i18n, 'en', 'customer.home.heading')).toBe(bundled)
  })

  it('shares one fetch across callers', async () => {
    let calls = 0
    rpc = () => {
      calls += 1
      return Promise.resolve({ data: [], error: null })
    }

    const { loadCopyOverrides } = await load()
    await Promise.all([loadCopyOverrides(), loadCopyOverrides(), loadCopyOverrides()])

    // The customer layout calls this on every mount, including client-side
    // navigation. Three calls would be three round trips for the same strings.
    expect(calls).toBe(1)
  })
})

describe('fetch budget', () => {
  it('does not settle before the budget when the request hangs', async () => {
    vi.useFakeTimers()
    const release = deferred()

    const { loadCopyOverrides, useCopyOverrides } = await load()
    const settled = vi.fn()
    const done = loadCopyOverrides().then(settled)

    await vi.advanceTimersByTimeAsync(1000)
    expect(settled).not.toHaveBeenCalled()
    expect(useCopyOverrides().pending.value).toBe(true)

    await vi.advanceTimersByTimeAsync(600)
    await done
    expect(settled).toHaveBeenCalledOnce()
    expect(useCopyOverrides().settled.value).toBe(true)

    release({ data: [], error: null })
  })

  it('applies an override that arrives after the budget expired', async () => {
    vi.useFakeTimers()
    const send = deferred()

    const { i18n, loadCopyOverrides } = await load()
    const done = loadCopyOverrides()

    await vi.advanceTimersByTimeAsync(1600)
    await done

    // Timed out, so the customer is looking at the bundled wording.
    expect(at(i18n, 'en', 'customer.home.heading')).not.toBe('Late arrival')

    send({ data: [row('home.heading', { value_en: 'Late arrival' })], error: null })
    await Promise.resolve()
    await Promise.resolve()

    // The late answer still lands. This is the accepted trade for not blocking first
    // paint: on a slow connection the customer may read the shipped wording briefly.
    expect(at(i18n, 'en', 'customer.home.heading')).toBe('Late arrival')
  })

  it('does not surface an unhandled rejection when a late request fails', async () => {
    vi.useFakeTimers()
    const send = deferred()

    const { loadCopyOverrides, useCopyOverrides } = await load()
    const done = loadCopyOverrides()
    await vi.advanceTimersByTimeAsync(1600)
    await done

    // The race is long over. A rejection arriving now has nobody awaiting it, and an
    // unhandled rejection takes the page down - the `.catch` in the composable is
    // what prevents that, so this asserts the failure is absorbed rather than thrown.
    send({ data: null, error: { message: 'too late' } })
    await Promise.resolve()
    await Promise.resolve()
    await Promise.resolve()

    expect(useCopyOverrides().failed.value).toBe(true)
  })
})

import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The render half of the copy store. `useCopyOverrides.test.ts` proves the merge
 * is correct; this proves the merged string reaches the screen in the right shape.
 *
 * The gap between those two is where the Phase 2 work actually sat: the composable
 * was complete and correct while `CopyText` was used by no view at all, so an
 * operator could flag a key as markdown, save it, and see nothing change. These
 * tests mount the component, so a call site that stops routing through it, or a
 * flag that stops flipping the branch, fails here.
 */

let rpc: (name: string) => Promise<unknown>

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => ({ rpc: (name: string) => rpc(name) }),
}))

function row(key: string, extra: Record<string, unknown> = {}) {
  return { key, value_bn: null, value_en: null, is_markdown: false, ...extra }
}

function answering(opts: { rows?: unknown[]; error?: { message: string } | null } = {}) {
  rpc = () => Promise.resolve({ data: opts.rows ?? [], error: opts.error ?? null })
}

function deferred() {
  let send: (value: unknown) => void = () => {}
  const promise = new Promise((resolve) => {
    send = resolve
  })
  rpc = () => promise
  return send
}

/**
 * Fresh i18n, fresh component module, fresh Supabase mock per test.
 *
 * `resetModules` is what makes the isolation real: `loadCopyOverrides` memoises in
 * a module-level variable, so without it the first test would own the single fetch
 * and every later test would assert against the first test's rows.
 *
 * Must be called with real timers. `resetModules` re-imports the graph, and the
 * module loader is itself timer-driven, so switching to fake timers first makes the
 * import hang until the test times out.
 */
async function setup(locale: 'bn' | 'en' = 'en') {
  vi.resetModules()
  const [i18nModule, copyModule, component] = await Promise.all([
    import('@/i18n'),
    import('@/composables/useCopyOverrides'),
    import('@/components/CopyText.vue'),
  ])
  const i18n = i18nModule.i18n
  // `CopyText` resolves through `t()`, so it renders the *active* locale. English is
  // the readable one for assertions; the Bangla path is covered by the locale test.
  i18n.global.locale.value = locale

  return {
    i18n,
    load: copyModule.loadCopyOverrides,
    state: copyModule.useCopyOverrides,
    mount: (props: Record<string, unknown> = {}, attrs: Record<string, unknown> = {}) =>
      mount(component.default, {
        props: { copyKey: 'recovery.body', tag: 'p', ...props },
        attrs,
        global: { plugins: [i18n] },
      }),
  }
}

/** Mount, then let the already-resolved fetch settle. */
async function render(
  opts: {
    locale?: 'bn' | 'en'
    props?: Record<string, unknown>
    attrs?: Record<string, unknown>
  } = {},
) {
  const ctx = await setup(opts.locale ?? 'en')
  const wrapper = ctx.mount(opts.props, opts.attrs)
  await ctx.load()
  await wrapper.vm.$nextTick()
  return { ...ctx, wrapper }
}

beforeEach(() => answering())
afterEach(() => vi.useRealTimers())

describe('rendering an operator override', () => {
  it('shows the overridden text', async () => {
    answering({ rows: [row('recovery.body', { value_en: 'We will text you a code.' })] })
    const { wrapper } = await render()

    expect(wrapper.text()).toBe('We will text you a code.')
  })

  it('keeps the requested element on the plain path', async () => {
    const { wrapper } = await render()
    expect(wrapper.element.tagName).toBe('P')
  })

  it('does not blank the string when a sibling key is overridden instead', async () => {
    // The shallow-merge defect replaced the whole `customer` namespace with a
    // one-key stub, so every other string in it silently vanished.
    answering({ rows: [row('home.heading', { value_en: 'Somewhere else entirely' })] })
    const { wrapper } = await render()

    expect(wrapper.text().trim()).not.toBe('')
    expect(wrapper.text()).not.toContain('Somewhere else entirely')
  })
})

describe('markdown rendering', () => {
  it('renders through MarkdownBody when the key is flagged', async () => {
    answering({
      rows: [row('recovery.body', { value_en: 'Read the **terms** first.', is_markdown: true })],
    })
    const { wrapper } = await render()

    expect(wrapper.find('.prose-en').exists()).toBe(true)
    expect(wrapper.html()).toContain('<strong>terms</strong>')
  })

  it('renders plain text when the key is not flagged', async () => {
    answering({ rows: [row('recovery.body', { value_en: 'Read the **terms** first.' })] })
    const { wrapper } = await render()

    // Not prose-en, and the asterisks are still visible: markdown that is not
    // opted into must not be interpreted, or an operator would see bold text in the
    // editor that never appears on the storefront.
    expect(wrapper.find('.prose-en').exists()).toBe(false)
    expect(wrapper.text()).toContain('**terms**')
  })

  it('drops a script tag rather than trusting the operator', async () => {
    answering({
      rows: [
        row('recovery.body', {
          value_en: 'hello <script>alert(1)</script> world',
          is_markdown: true,
        }),
      ],
    })
    const { wrapper } = await render()

    expect(wrapper.html()).not.toContain('<script>')
    expect(wrapper.html()).not.toContain('alert(1)')
  })

  it('switches to a block element, because a div cannot live inside a p', async () => {
    answering({
      rows: [row('recovery.body', { value_en: 'A **list** follows.', is_markdown: true })],
    })
    const { wrapper } = await render()

    // Every call site was a `<p>`. Reusing the tag on the markdown branch would let
    // the browser close the paragraph early and turn the block into a sibling.
    expect(wrapper.element.tagName).toBe('DIV')
  })

  it('forwards classes to the plain branch', async () => {
    const { wrapper } = await render({ attrs: { class: 'page-subtitle' } })
    expect(wrapper.classes()).toContain('page-subtitle')
  })

  it('forwards classes to the markdown branch too', async () => {
    answering({
      rows: [row('recovery.body', { value_en: 'Something **bold**.', is_markdown: true })],
    })
    const { wrapper } = await render({ attrs: { class: 'page-subtitle' } })

    // Asserted on the element rather than the wrapper: the markdown branch renders a
    // child component, and the caller's classes have to land on *its* root.
    const prose = wrapper.find('.prose-en')
    expect(prose.exists()).toBe(true)
    expect(prose.classes()).toContain('page-subtitle')
  })
})

describe('arriving after the budget expired', () => {
  it('flips to markdown when the flag lands late', async () => {
    // Real timers for the module graph first, fake ones only for the budget itself.
    const ctx = await setup()
    const send = deferred()
    vi.useFakeTimers()

    const wrapper = ctx.mount()

    // `load` starts the race, and only then does the budget timer exist. Advancing
    // first would move time while no timer was registered, and the await below would
    // never return.
    const done = ctx.load()
    await vi.advanceTimersByTimeAsync(1600)
    await done
    await wrapper.vm.$nextTick()
    expect(wrapper.find('.prose-en').exists()).toBe(false)

    send({
      data: [row('recovery.body', { value_en: 'Late **arrival**.', is_markdown: true })],
      error: null,
    })
    await Promise.resolve()
    await Promise.resolve()
    await wrapper.vm.$nextTick()

    // Without this the operator's change is saved and invisible.
    expect(wrapper.find('.prose-en').exists()).toBe(true)
    expect(wrapper.html()).toContain('<strong>arrival</strong>')
  })
})

describe('switching language', () => {
  it('renders the override for whichever language is active', async () => {
    answering({
      rows: [
        row('recovery.body', { value_bn: 'আমরা কোড পাঠাব।', value_en: 'We will send a code.' }),
      ],
    })
    const { i18n, wrapper } = await render()

    expect(wrapper.text()).toBe('We will send a code.')

    i18n.global.locale.value = 'bn'
    await wrapper.vm.$nextTick()
    expect(wrapper.text()).toBe('আমরা কোড পাঠাব।')

    i18n.global.locale.value = 'en'
    await wrapper.vm.$nextTick()
    expect(wrapper.text()).toBe('We will send a code.')
  })

  it('falls back to the bundle for a language nobody translated', async () => {
    answering({ rows: [row('recovery.body', { value_en: 'Only English was written.' })] })
    const { i18n, wrapper } = await render()

    i18n.global.locale.value = 'bn'
    await wrapper.vm.$nextTick()

    // Bangla has no override here, so the bundle answers. Blank would be the failure.
    expect(wrapper.text().trim()).not.toBe('')
    expect(wrapper.text()).not.toBe('Only English was written.')
  })
})

describe('when the copy fetch fails', () => {
  it('keeps the bundled wording on screen', async () => {
    answering({ error: { message: 'network down' } })
    const { wrapper, state } = await render()

    expect(state().failed.value).toBe(true)
    // A copy fetch must never be able to blank a page someone is trying to pay
    // through. The bundle is the fallback and it is already on screen.
    expect(wrapper.text().trim()).not.toBe('')
  })
})

import { mount, flushPromises } from '@vue/test-utils'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { defineComponent, h } from 'vue'
import PageView from '@/views/customer/PageView.vue'
import { i18n } from '@/i18n'

/**
 * The page is the whole checkout.
 *
 * Every state a customer's order can be in is actionable here: an open online
 * order shows one pay button that runs the one-step flow in place, an open
 * manual order shows the account and the evidence form inline, and an approved
 * order shows what was bought. The page only falls back to the "new order"
 * form when the customer has nothing in flight for this slug.
 *
 * The old flow navigated to a separate order page; these tests pin the inline
 * behaviour instead, including the two ways the order lookup can fail, because
 * each one decides whether the customer sees their order or a working form.
 */

const SLUG = 'demo-report'
const ORDER_ID = '99999999-9999-4999-8999-999999999999'
const KIND = 'bkash Payment'

const routerPush = vi.fn()
const rpc = vi.fn()
const getSession = vi.fn()
const invoke = vi.fn()

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => ({
    rpc: (...args: unknown[]) => rpc(...args),
    functions: {
      invoke: (...args: unknown[]) => invoke(...args),
    },
    auth: {
      getSession: (...args: unknown[]) => getSession(...args),
      signInAnonymously: vi
        .fn()
        .mockResolvedValue({ data: { user: {}, session: {} }, error: null }),
    },
  }),
}))

/** Only `params.slug` is read, and `push` is the whole of what the router owes here. */
let currentSlug = SLUG

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { slug: currentSlug }, query: {} }),
  useRouter: () => ({ push: (...args: unknown[]) => routerPush(...args) }),
}))

/** Renders nothing, so only the event it emits is of interest. */
const SelectorStub = defineComponent({
  name: 'GatewaySelectorStub',
  props: { gateways: { type: Array, required: true } },
  emits: ['update:selected'],
  setup: () => () => h('div'),
})

/** One online gateway, so a page's kind is unambiguous in every test below. */
function publicLink(provider: string | null) {
  return {
    slug: SLUG,
    title_bn: 'টেস্ট',
    title_en: 'Test',
    teaser_md_bn: null,
    teaser_md_en: null,
    unlock_cta_label_bn: null,
    unlock_cta_label_en: 'Get the pack',
    unlock_cta_url: 'https://example.com/pack',
    min_amount: 0,
    min_hidden: false,
    template: 'standard',
    template_config: {},
    gateways: [
      {
        id: '11111111-1111-4111-8111-111111111111',
        kind: KIND,
        sort_order: 0,
        provider,
        account_number: '01700000000',
        account_name: 'Cofibuy',
        instructions_md_en: null,
        instructions_md_bn: null,
        reference_prompt_en: null,
        reference_prompt_bn: null,
        supports_reference: false,
        evidence_fields: [],
      },
    ],
  }
}

function openOrder() {
  return {
    id: ORDER_ID,
    slug: SLUG,
    gateway_kind: KIND,
    status: 'awaiting_proof',
    reference_code: 'AB12CD34',
    amount: 500,
    reject_reason_en: null,
    reject_reason_bn: null,
  }
}

beforeEach(() => {
  i18n.global.locale.value = 'en'
  currentSlug = SLUG
  rpc.mockReset()
  invoke.mockReset()
  getSession.mockReset()
  getSession.mockResolvedValue({ data: { session: { user: {} } }, error: null })
  routerPush.mockReset()
})

describe('the page as the whole checkout', () => {
  it('renders the open online order as one pay button', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink('bkash_pgw'), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [openOrder()], error: null })
      if (name === 'my_order_status')
        return Promise.resolve({ data: { id: ORDER_ID, status: 'awaiting_proof' }, error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    // The order is on the page: reference, amount, one button. No form, no
    // navigation - the customer pays from here.
    expect(wrapper.text()).toContain('AB12CD34')
    expect(wrapper.find('#amount').exists()).toBe(false)

    invoke.mockResolvedValue({
      data: { ok: true, redirectUrl: 'https://bkash.test/pay' },
      error: null,
    })
    await wrapper.find('button[type="button"]').trigger('click')
    await flushPromises()

    expect(invoke).toHaveBeenCalledWith(
      'bkash-create-payment',
      expect.objectContaining({
        body: expect.objectContaining({ slug: SLUG, kind: KIND, amount: 500 }),
      }),
    )
  })

  it('renders the open manual order with the evidence form inline', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [openOrder()], error: null })
      if (name === 'my_order_status')
        return Promise.resolve({
          data: {
            id: ORDER_ID,
            status: 'awaiting_proof',
            account_number: '01700000000',
            account_name: 'Cofibuy',
            account_fields: [],
            evidence_fields: [
              { key: 'trxid', type: 'text', required: true, label_en: 'TrxID', label_bn: null },
            ],
          },
          error: null,
        })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    expect(wrapper.text()).toContain('AB12CD34')
    expect(wrapper.find('form').exists()).toBe(true)
  })

  it('shows what an approved order bought, on the same page', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink('bkash_pgw'), error: null })
      if (name === 'my_orders')
        return Promise.resolve({
          data: [{ ...openOrder(), status: 'approved' }],
          error: null,
        })
      if (name === 'get_unlocked_page')
        return Promise.resolve({
          data: { unlock_body_md_en: 'Here is your guide.', unlock_body_md_bn: 'আপনার গাইড।' },
          error: null,
        })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    expect(wrapper.text()).toContain('Here is your guide.')
    expect(wrapper.find('#amount').exists()).toBe(false)
  })

  it('keeps the new-order form when the only order is expired', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders')
        return Promise.resolve({
          data: [{ ...openOrder(), status: 'expired' }],
          error: null,
        })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    expect(wrapper.find('#amount').exists()).toBe(true)
    expect(wrapper.text()).not.toContain('AB12CD34')
  })

  it('the summary shows for a manual selection too, not only online', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    // Summary heading and the deliverable note belong to both paths; the form
    // the summary once lived in was the online one, so a manual selection lost
    // everything above the account details.
    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.summary') as string)
    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.deliverable') as string)
    expect(wrapper.text()).toContain('01700000000')
  })

  it('the selected manual method shows its account rows on the page', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    // The gateway's own account_fields, not its proof fields: reading the wrong
    // array here rendered an empty account card above a perfectly good payload.
    expect(wrapper.text()).toContain('01700000000')
  })

  it('a hidden page drops the way back to the index', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({
          data: { ...publicLink(null), is_listed: false },
          error: null,
        })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    // No back link on the page, and the layout's brand link is inert. The
    // router-link stub renders without an href, so the back label is the signal.
    expect(wrapper.text()).not.toContain(i18n.global.t('customer.paywall.back') as string)
  })

  it('a listed page keeps the way back to the index', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({
          data: { ...publicLink(null), is_listed: true },
          error: null,
        })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.back') as string)
  })

  it('the panel survives a refresh, because a refresh is another mount', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink('bkash_pgw'), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [openOrder()], error: null })
      if (name === 'my_order_status')
        return Promise.resolve({ data: { id: ORDER_ID, status: 'awaiting_proof' }, error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    // First load: the customer submits nothing; the open order is already there.
    const first = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()
    expect(first.text()).toContain('AB12CD34')
    expect(first.find('#amount').exists()).toBe(false)

    // A refresh is exactly this: a second mount against the same session, which
    // re-reads my_orders and lands on the same panel. The form must not come
    // back just because the page was reloaded.
    const second = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()
    expect(second.text()).toContain('AB12CD34')
    expect(second.find('#amount').exists()).toBe(false)
  })

  it('an order under review survives the refresh too', async () => {
    // `under_review` is not one of the SQL's open statuses - a review does not
    // block a second order - but it is exactly where a manual order sits after
    // its proof was submitted. Skip it and the payment form reappears over the
    // customer's heads on the first refresh.
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders')
        return Promise.resolve({
          data: [{ ...openOrder(), status: 'under_review' }],
          error: null,
        })
      if (name === 'my_order_status')
        return Promise.resolve({ data: { id: ORDER_ID, status: 'under_review' }, error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const first = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()
    expect(first.text()).toContain('AB12CD34')
    expect(first.find('#amount').exists()).toBe(false)

    const second = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()
    expect(second.text()).toContain('AB12CD34')
    expect(second.find('#amount').exists()).toBe(false)
  })

  it('price chips set the amount, and Custom reveals the typing field', async () => {
    const presetLink = {
      ...publicLink(null),
      amount_presets: [200, 500, 1000],
    }
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page') return Promise.resolve({ data: presetLink, error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    // The chips are the interface; the typing field is hidden behind Custom.
    expect(wrapper.find('#amount').exists()).toBe(false)
    const chips = wrapper.findAll('button[type="button"]').filter((b) => b.text().includes('৳'))
    expect(chips.length).toBe(3)
    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.custom') as string)

    // Tapping a chip sets the amount the summary shows - no typing at all.
    await chips[1]!.trigger('click')
    expect(wrapper.text()).toContain('৳500')

    // Custom brings the field back, and it starts empty for an arbitrary value.
    const customChip = wrapper
      .findAll('button[type="button"]')
      .find((b) => b.text() === (i18n.global.t('customer.paywall.custom') as string))!
    await customChip.trigger('click')
    expect(wrapper.find('#amount').exists()).toBe(true)
  })

  it('presets below the effective minimum are not shown as tappable chips', async () => {
    const presetLink = {
      ...publicLink(null),
      min_amount: 300,
      amount_presets: [100, 200, 500],
    }
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page') return Promise.resolve({ data: presetLink, error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    const chipTexts = wrapper
      .findAll('button[type="button"]')
      .map((b) => b.text())
      .join('|')
    expect(chipTexts).not.toContain('৳100')
    expect(chipTexts).not.toContain('৳200')
    expect(chipTexts).toContain('৳500')
  })

  it('degrades to the new-order form when the order lookup fails', async () => {
    void 0
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders')
        return Promise.resolve({ data: null, error: { message: 'permission denied' } })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    const fs2 = await import('node:fs')
    fs2.writeFileSync('.tmp/debug2.html', wrapper.html())

    // A broken lookup must not take the form away: the customer can still try.
    expect(wrapper.find('#amount').exists()).toBe(true)
    expect(wrapper.text()).not.toContain('permission denied')
  })
})

import { mount, flushPromises } from '@vue/test-utils'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import PageView from '@/views/customer/PageView.vue'
import { i18n } from '@/i18n'

/**
 * The page is the whole checkout, and the checkout is a modal.
 *
 * Every pay CTA on the page opens the payment modal, which carries the whole
 * flow in three phases: gateway, send and confirm, status. Which phase a
 * fresh open lands on is decided by the customer's own order state - an open
 * online order goes to the pay step, a manual order waiting for proof goes to
 * the send step, and anything past submission opens on the status page.
 *
 * The old flow rendered the form inline and navigated to a separate order
 * page; these tests pin the modal behaviour instead, including the two ways
 * the order lookup can fail, because each one decides whether the customer
 * sees their order or a working form.
 */

const SLUG = 'demo-report'
const ORDER_ID = '99999999-9999-4999-8999-999999999999'
const KIND = 'bkash Payment'

const routerPush = vi.fn()
const rpc = vi.fn()
const getSession = vi.fn()
const invoke = vi.fn()

/** What `my_orders` answers with after the customer submits; set by tests that walk the flow. */
let order: Record<string, unknown> | null = null

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
    template: 'sales-landing',
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
        evidence_fields: [
          { key: 'trxid', type: 'text', required: true, label_en: 'TrxID', label_bn: null },
        ],
        country: null,
        is_primary_for_country: false,
        banner_url: null,
        banner_small_url: null,
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

/**
 * Mounts the page and opens the payment modal, walking it to `phase` when
 * there is only one gateway kind (the banner tap is the only step between
 * the CTA and the send screen).
 */
async function mountAndOpen(phase: 'gateway' | 'send' = 'send') {
  const wrapper = mount(PageView, {
    global: { plugins: [i18n], stubs: { teleport: true } },
  })
  await flushPromises()

  // The template's own CTA (marquee, first in the DOM) opens the modal.
  await wrapper.find('main button').trigger('click')
  await flushPromises()

  if (phase === 'gateway') return wrapper

  // A fresh open with no order in flight lands on the gateway phase; an open
  // order skips straight to send or status, so the banner tap is optional.
  const banner = wrapper.find('.gateway-banner')
  if (banner.exists()) {
    await banner.trigger('click')
    await flushPromises()
  }
  return wrapper
}

beforeEach(() => {
  i18n.global.locale.value = 'en'
  currentSlug = SLUG
  order = null
  rpc.mockReset()
  invoke.mockReset()
  getSession.mockReset()
  getSession.mockResolvedValue({ data: { session: { user: {} } }, error: null })
  routerPush.mockReset()
})

describe('the page as the whole checkout', () => {
  it('pays the open online order from the modal', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink('bkash_pgw'), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [openOrder()], error: null })
      if (name === 'my_order_status')
        return Promise.resolve({ data: { id: ORDER_ID, status: 'awaiting_proof' }, error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = await mountAndOpen()

    // The order is in the modal: one pay button. No form fields, no
    // navigation - the customer pays from here.
    const payLabel = i18n.global.t('customer.order.payOnline') as string
    expect(wrapper.findAll('button').some((b) => b.text() === payLabel)).toBe(true)
    expect(wrapper.find('#amount').exists()).toBe(false)

    invoke.mockResolvedValue({
      data: { ok: true, redirectUrl: 'https://bkash.test/pay' },
      error: null,
    })
    const payButton = wrapper.findAll('button').find((b) => b.text() === payLabel)
    await payButton!.trigger('click')
    await flushPromises()

    expect(invoke).toHaveBeenCalledWith(
      'bkash-create-payment',
      expect.objectContaining({
        body: expect.objectContaining({ slug: SLUG, kind: KIND, amount: 500 }),
      }),
    )
  })

  it('a manual order waiting for proof reopens at the send step, evidence form ready', async () => {
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

    const wrapper = await mountAndOpen()

    expect(wrapper.text()).toContain('AB12CD34')
    expect(wrapper.find('form').exists()).toBe(true)
  })

  it('a manual order past submission reopens on the status page only', async () => {
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

    const wrapper = await mountAndOpen('gateway')

    // The modal skipped both earlier phases: no gateway chooser, no amount.
    expect(wrapper.text()).toContain('AB12CD34')
    expect(wrapper.find('#amount').exists()).toBe(false)
    expect(wrapper.text()).toContain(i18n.global.t('customer.order.underReview') as string)
  })

  it('shows what an approved order bought, in the modal status phase', async () => {
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
      global: { plugins: [i18n], stubs: { teleport: true } },
    })
    await flushPromises()

    // The modal opens on the status phase for an approved order, and what
    // was bought renders right there.
    await wrapper.find('main button').trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('Here is your guide.')
    expect(wrapper.find('#amount').exists()).toBe(false)
  })

  it('keeps the pay CTA when the only order is expired', async () => {
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
      global: { plugins: [i18n], stubs: { teleport: true } },
    })
    await flushPromises()

    expect(wrapper.find('#amount').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('AB12CD34')
  })

  it('the send step shows the whole transfer for a manual selection, in one card', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = await mountAndOpen()

    // The pruned send step: the amount and the account together, nothing else.
    // The summary card is gone - the amount line and the account rows are the
    // summary now.
    expect(wrapper.text()).toContain('01700000000')
    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.sendTo') as string)
    expect(wrapper.text()).not.toContain(i18n.global.t('customer.paywall.summary') as string)
  })

  it('the selected manual method shows its account rows in the modal', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = await mountAndOpen()

    // The gateway's own account_fields, not its proof fields: reading the wrong
    // array here rendered an empty account card above a perfectly good payload.
    expect(wrapper.text()).toContain('01700000000')
  })

  it('a sales page carries no way back to the index, listed or not', async () => {
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
      global: { plugins: [i18n], stubs: { teleport: true } },
    })
    await flushPromises()

    // The full-bleed template owns the viewport: the layout header and the
    // back link would frame it, so they never show - even when listed.
    expect(wrapper.text()).not.toContain(i18n.global.t('customer.paywall.back') as string)
  })

  it('the modal survives a refresh, because a refresh is another mount', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink('bkash_pgw'), error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [openOrder()], error: null })
      if (name === 'my_order_status')
        return Promise.resolve({ data: { id: ORDER_ID, status: 'awaiting_proof' }, error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    // First load: the customer opens the modal and finds the open order's pay
    // step, not a fresh gateway chooser.
    const first = await mountAndOpen()
    const retryPayLabel = i18n.global.t('customer.order.payOnline') as string
    expect(first.findAll('button').some((b) => b.text() === retryPayLabel)).toBe(true)
    expect(first.find('#amount').exists()).toBe(false)

    // A refresh is exactly this: a second mount against the same session, which
    // re-reads my_orders and lands on the same step. The form must not come
    // back just because the page was reloaded.
    const second = await mountAndOpen()
    expect(second.findAll('button').some((b) => b.text() === retryPayLabel)).toBe(true)
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

    const wrapper = await mountAndOpen()

    // The chips are the interface; the typing field is always there beside
    // them, so a custom figure never hides behind a mode.
    expect(wrapper.find('#amount').exists()).toBe(true)
    const chips = wrapper.findAll('button[type="button"]').filter((b) => b.text().includes('৳'))
    expect(chips.length).toBe(3)
    expect(wrapper.text()).not.toContain(i18n.global.t('customer.paywall.custom') as string)

    // Tapping a chip fills the input with that figure - no typing at all.
    await chips[1]!.trigger('click')
    const amountInput = wrapper.find('#amount').element as HTMLInputElement
    expect(amountInput.value).toBe('500')

    // Typing a different figure is the custom path, no mode switch needed.
    await wrapper.find('#amount').setValue('750')
    expect((wrapper.find('#amount').element as HTMLInputElement).value).toBe('750')
  })

  it('the send step always opens with a default amount in place', async () => {
    const presetLink = {
      ...publicLink(null),
      amount_presets: [300, 700],
    }
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page') return Promise.resolve({ data: presetLink, error: null })
      if (name === 'my_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = await mountAndOpen()

    // The first preset is pre-filled in the input before the customer types.
    const amountInput = wrapper.find('#amount').element as HTMLInputElement
    expect(amountInput.value).toBe('300')
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

    const wrapper = await mountAndOpen()

    const chipTexts = wrapper
      .findAll('button[type="button"]')
      .map((b) => b.text())
      .join('|')
    expect(chipTexts).not.toContain('৳100')
    expect(chipTexts).not.toContain('৳200')
    expect(chipTexts).toContain('৳500')
  })

  it('reopening the modal after confirming a manual order shows the status page', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders')
        return Promise.resolve({
          data: order ? [order] : [],
          error: null,
        })
      if (name === 'my_order_status')
        return Promise.resolve({
          data: {
            id: ORDER_ID,
            status: order?.status ?? 'awaiting_proof',
            account_number: '01700000000',
            account_name: 'Cofibuy',
            account_fields: [],
            evidence_fields: [
              { key: 'trxid', type: 'text', required: true, label_en: 'TrxID', label_bn: null },
            ],
          },
          error: null,
        })
      if (name === 'create_order')
        return Promise.resolve({ data: { ok: true, order_id: ORDER_ID }, error: null })
      if (name === 'submit_evidence') {
        // The database moves the order to under review; `my_orders` reads it back.
        order = { ...openOrder(), status: 'under_review' }
        return Promise.resolve({ data: { ok: true }, error: null })
      }
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(PageView, {
      global: { plugins: [i18n], stubs: { teleport: true } },
    })
    await flushPromises()

    // Walk the flow: CTA, banner, proof, submit.
    await wrapper.find('main button').trigger('click')
    await flushPromises()
    await wrapper.find('.gateway-banner').trigger('click')
    await flushPromises()
    await wrapper.find('#trxid').setValue('TRX999999')
    await wrapper.find('form').trigger('submit')
    await flushPromises()

    expect(wrapper.text()).toContain('AB12CD34')
    expect(wrapper.text()).toContain(i18n.global.t('customer.order.underReview') as string)

    // Close, then reopen from the CTA: the status page is the whole story.
    const closeLabel = i18n.global.t('customer.common.close') as string
    await wrapper
      .findAll('button')
      .find((b) => b.attributes('aria-label') === closeLabel)!
      .trigger('click')
    await flushPromises()
    expect(wrapper.text()).not.toContain('AB12CD34')

    await wrapper.find('main button').trigger('click')
    await flushPromises()

    expect(wrapper.text()).toContain('AB12CD34')
    expect(wrapper.text()).toContain(i18n.global.t('customer.order.underReview') as string)
    expect(wrapper.text()).not.toContain(i18n.global.t('customer.paywall.stepAmount') as string)
  })

  it('degrades to a working modal when the order lookup fails', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_page')
        return Promise.resolve({ data: publicLink(null), error: null })
      if (name === 'my_orders')
        return Promise.resolve({ data: null, error: { message: 'permission denied' } })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = await mountAndOpen()

    // A broken lookup must not take the form away: the customer can still try.
    expect(wrapper.find('#amount').exists()).toBe(true)
    expect(wrapper.text()).not.toContain('permission denied')
  })
})

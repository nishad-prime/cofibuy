import { mount, flushPromises } from '@vue/test-utils'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { defineComponent, h } from 'vue'
import LinkView from '@/views/customer/LinkView.vue'
import { i18n } from '@/i18n'

/**
 * A regression test for the hand-off LinkView owes a `kind_mismatch` raise.
 *
 * `api.create_order` raises `kind_mismatch` rather than returning an `ok: false` payload,
 * and its own migration comment spells out why the client cannot answer it with a message:
 * the customer's open order is deliberately pinned to one gateway so a transfer receipt
 * cannot be re-pointed at an account nobody watches, so nothing they do on this form can
 * make the mismatch go away. A sentence after `kind_mismatch:` describes an order id and a
 * payment kind - neither of which a customer knows or can act on - and reading it as a
 * refusal invites them to retry the same submission forever.
 *
 * What the customer actually wants is the order that is already waiting, so the view
 * looks it up and navigates. These tests pin that behaviour, plus the two ways the lookup
 * itself can fail, because each leaves a different sentence owed to the customer.
 */

const SLUG = 'demo-report'
const ORDER_ID = '99999999-9999-4999-8999-999999999999'
const KIND = 'bkash Payment'

const routerPush = vi.fn()
const rpc = vi.fn()
const getSession = vi.fn()

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => ({
    rpc: (...args: unknown[]) => rpc(...args),
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
  useRoute: () => ({ params: { slug: currentSlug } }),
  useRouter: () => ({ push: (...args: unknown[]) => routerPush(...args) }),
}))

/** Renders nothing, so only the event it emits is of interest. */
const SelectorStub = defineComponent({
  name: 'GatewaySelectorStub',
  props: { gateways: { type: Array, required: true } },
  emits: ['update:selected'],
  setup: () => () => h('div'),
})

/** A link with one gateway, so the view preselects its kind and the amount field shows. */
function publicLink() {
  return {
    slug: SLUG,
    title_bn: 'টেস্ট',
    title_en: 'Test',
    teaser_md_bn: null,
    teaser_md_en: null,
    unlock_cta_label_bn: null,
    unlock_cta_label_en: null,
    unlock_cta_url: null,
    min_amount: 0,
    min_hidden: false,
    gateways: [{ id: '11111111-1111-4111-8111-111111111111', kind: KIND, sort_order: 0 }],
  }
}

beforeEach(() => {
  currentSlug = SLUG
  rpc.mockReset()
  getSession.mockReset()
  getSession.mockResolvedValue({ data: { session: { user: {} } }, error: null })
  routerPush.mockReset()
})

describe('kind_mismatch hand-off', () => {
  it('takes the customer to the open order that is in the way', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_link') return Promise.resolve({ data: publicLink(), error: null })
      if (name === 'create_order')
        return Promise.resolve({
          data: null,
          error: { message: `kind_mismatch: open order already uses payment kind ${KIND}` },
        })
      if (name === 'my_orders')
        return Promise.resolve({
          data: [
            // A different report, which must not be mistaken for the one in the way.
            { id: '11111111-1111-4111-8111-111111111111', slug: 'other', status: 'draft' },
            { id: ORDER_ID, slug: SLUG, status: 'awaiting_proof' },
          ],
          error: null,
        })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(LinkView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    await wrapper.get('#amount').setValue(500)
    await wrapper.get('form').trigger('submit')
    await flushPromises()

    expect(routerPush).toHaveBeenCalledWith(`/${SLUG}/order/${ORDER_ID}`)
    // The raw raise must not reach the customer, whatever else happens.
    expect(wrapper.text()).not.toContain('kind_mismatch')
  })

  it('ignores an order whose status is already closed', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_link') return Promise.resolve({ data: publicLink(), error: null })
      if (name === 'create_order')
        return Promise.resolve({
          data: null,
          error: { message: `kind_mismatch: open order already uses payment kind ${KIND}` },
        })
      if (name === 'my_orders')
        return Promise.resolve({
          data: [
            { id: ORDER_ID, slug: SLUG, status: 'approved' },
            { id: ORDER_ID, slug: SLUG, status: 'expired' },
          ],
          error: null,
        })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(LinkView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    await wrapper.get('#amount').setValue(500)
    await wrapper.get('form').trigger('submit')
    await flushPromises()

    // Nothing is open any more, so there is nowhere to navigate - but saying so is what
    // turns a dead end into an invitation to submit again.
    expect(routerPush).not.toHaveBeenCalled()
    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.openOrderExpired') as string)
    expect(wrapper.text()).not.toContain('kind_mismatch')
  })

  it('says an order is in progress when the lookup itself fails', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'get_public_link') return Promise.resolve({ data: publicLink(), error: null })
      if (name === 'create_order')
        return Promise.resolve({
          data: null,
          error: { message: `kind_mismatch: open order already uses payment kind ${KIND}` },
        })
      if (name === 'my_orders')
        return Promise.resolve({ data: null, error: { message: 'permission denied' } })
      return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
    })

    const wrapper = mount(LinkView, {
      global: { plugins: [i18n], stubs: { GatewaySelector: SelectorStub } },
    })
    await flushPromises()

    await wrapper.get('#amount').setValue(500)
    await wrapper.get('form').trigger('submit')
    await flushPromises()

    expect(routerPush).not.toHaveBeenCalled()
    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.openOrderExists') as string)
    // Quoting the lookup's own error would be the same mistake as the raise.
    expect(wrapper.text()).not.toContain('permission denied')
    expect(wrapper.text()).not.toContain('kind_mismatch')
  })
})

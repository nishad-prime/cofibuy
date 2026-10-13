import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it } from 'vitest'
import { computed, reactive, ref } from 'vue'
import PaymentModal from '@/components/customer/PaymentModal.vue'
import { i18n } from '@/i18n'
import type { PageCheckout } from '@/composables/usePageCheckout'

/**
 * The modal's own rules, independent of the page: a fresh open lands on the
 * phase the customer's order state dictates, a submission in flight may not
 * be closed away, and a proof that lands walks the modal to the status page
 * on its own.
 */

function fakeCheckout(overrides: Partial<PageCheckout> = {}): PageCheckout {
  /** A writable ref dressed as the composable's ref, so v-model targets work. */
  const asRef = <T>(value: T) => ref(value)
  const base = {
    maintenance: computed(() => false),
    supportContact: computed(() => ''),
    gateways: computed(() => [
      {
        id: 'g1',
        kind: 'bkash',
        name_bn: null,
        name_en: 'bKash',
        provider: null,
        sort_order: 0,
        account_number: '01700',
        account_name: 'Cofibuy',
        account_fields: [],
        instructions_md_en: null,
        instructions_md_bn: null,
        reference_prompt_en: null,
        reference_prompt_bn: null,
        supports_reference: false,
        evidence_fields: [],
        country: null,
        is_primary_for_country: false,
        banner_url: null,
        banner_small_url: null,
      },
    ]),
    selectedKind: asRef('bkash'),
    amount: asRef(0),
    creating: computed(() => false),
    error: asRef(null),
    existingOrder: asRef(null),
    orderDetails: asRef(null),
    unlockedBody: asRef(null),
    paying: computed(() => false),
    submittingEvidence: computed(() => false),
    amountMode: asRef('preset'),
    justPaid: computed(() => false),
    orderGateway: computed(() => undefined),
    orderPaysOnline: computed(() => false),
    selectedGateway: computed(() => undefined),
    pickedGatewayName: computed(() => ''),
    selectedAccountFields: computed(() => []),
    selectedInstructions: computed(() => null),
    orderAccountFields: computed(() => []),
    orderAccountLegacy: computed(() => ({ number: null, name: null })),
    orderEvidenceFields: computed(() => []),
    pageTitle: computed(() => 'Test page'),
    pageCta: computed(() => ''),
    ctaUrl: computed(() => ''),
    effectiveMin: computed(() => 0),
    hideMin: computed(() => false),
    amountPresets: computed(() => [200, 500]),
    fixedAmount: computed(() => null),
    isAmountValid: computed(() => true),
    amountHint: computed(() => ''),
    amountError: computed(() => ''),
    kindPaysOnline: computed(() => false),
    pick: ({ en }: { en?: string }) => en ?? '',
    money: (n: number) => `৳${n}`,
    formatExpiry: () => '',
    selectPreset: () => {},
    applyDefaultAmount: () => {},
    startInvitePolling: () => {},
    stopInvitePolling: () => {},
    telegramInvite: asRef(null),
    init: () => {},
    payExisting: async () => {},
    submitEvidence: async () => {},
    createOrder: async () => {},
    createManualOrder: async () => {},
  }
  // Plain object, deliberately not reactive: the modal reads everything
  // through `.value`, so wrapping computeds in a reactive proxy breaks them.
  const merged = { ...base, ...overrides }
  const result = merged as unknown as PageCheckout & {
    customerCountry: unknown
    gatewayBanners: unknown
  }
  result.customerCountry = computed(() => null)
  // One banner per kind, derived from whatever gateways the test provided.
  result.gatewayBanners = computed(() =>
    ((merged.gateways as unknown as { value: Array<Record<string, unknown>> }).value ?? []).map(
      (g, index) => ({
        kind: g.kind as string,
        name: (g.name_en as string) || (g.kind as string),
        provider: (g.provider as string | null) ?? null,
        bannerUrl: null,
        size: index === 0 ? ('big' as const) : ('normal' as const),
      }),
    ),
  )
  return result as unknown as PageCheckout
}

const mountModal = async (checkout: PageCheckout, open = true) => {
  const wrapper = mount(PaymentModal, {
    props: { checkout, open },
    global: { plugins: [i18n], stubs: { teleport: true } },
  })
  await flushPromises()
  return wrapper
}

beforeEach(() => {
  i18n.global.locale.value = 'en'
})

describe('the payment modal', () => {
  it('a fresh open with no order starts at the gateway phase', async () => {
    const wrapper = await mountModal(fakeCheckout())
    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.chooseMethod') as string)
  })

  it('closing releases the body scroll lock', async () => {
    const wrapper = await mountModal(fakeCheckout())
    expect(document.body.style.overflow).toBe('hidden')
    await wrapper.find('button[aria-label="Close"]').trigger('click')
    expect(wrapper.emitted('update:open')?.[0]).toEqual([false])
  })

  it('a submission in flight cannot be closed, not even with Escape', async () => {
    const wrapper = await mountModal(
      fakeCheckout({ creating: computed(() => true) as unknown as PageCheckout['creating'] }),
    )
    await wrapper.find('button[aria-label="Close"]').trigger('click')
    expect(wrapper.emitted('update:open')).toBeUndefined()

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(wrapper.emitted('update:open')).toBeUndefined()
  })

  it('a fresh manual submission lands on the status page, not the pay step', async () => {
    // Both kinds on the page: the whole point is that confirming the manual
    // order must not leave the online pay option reachable.
    const order = ref<Record<string, unknown> | null>(null)
    const checkout = fakeCheckout({
      gateways: computed(() => [
        {
          id: 'g1',
          kind: 'bkash',
          name_bn: null,
          name_en: 'bKash',
          provider: 'bkash_pgw',
          sort_order: 0,
          account_number: null,
          account_name: null,
          account_fields: [],
          instructions_md_en: null,
          instructions_md_bn: null,
          evidence_fields: [],
          country: null,
          is_primary_for_country: false,
          banner_url: null,
          banner_small_url: null,
        },
        {
          id: 'g2',
          kind: 'bank',
          name_bn: null,
          name_en: 'Bank',
          provider: null,
          sort_order: 1,
          account_number: '01700',
          account_name: 'Cofibuy',
          account_fields: [],
          instructions_md_en: null,
          instructions_md_bn: null,
          evidence_fields: [
            { key: 'trxid', type: 'text', required: true, label_en: 'TrxID', label_bn: null },
          ],
          country: null,
          is_primary_for_country: false,
          banner_url: null,
          banner_small_url: null,
        },
      ]),
      selectedGateway: computed(() => undefined) as unknown as PageCheckout['selectedGateway'],
      kindPaysOnline: computed(() => false),
      createManualOrder: async () => {
        order.value = {
          id: 'o2',
          slug: 's',
          gateway_kind: 'bank',
          status: 'under_review',
          reference_code: 'RC2',
          amount: 500,
          reject_reason_en: null,
          reject_reason_bn: null,
        }
      },
    })
    checkout.selectedGateway = computed(() =>
      (checkout.gateways.value as unknown as Array<Record<string, unknown>>).find(
        (g) => g.kind === 'bank',
      ),
    ) as unknown as PageCheckout['selectedGateway']
    checkout.existingOrder = computed(() => order.value) as unknown as PageCheckout['existingOrder']

    const wrapper = await mountModal(checkout)
    // Walk to send: tap the bank banner.
    const banners = wrapper.findAll('.gateway-banner')
    await banners[1]!.trigger('click')
    await flushPromises()

    // The evidence form belongs to the manual kind; filling it and submitting
    // confirms the order.
    await wrapper.find('#trxid').setValue('TRX123456')
    const submitLabel = i18n.global.t('customer.order.submitEvidenceCta') as string
    await wrapper.find('form').trigger('submit')
    await flushPromises()

    expect(wrapper.text()).toContain('RC2')
    expect(wrapper.text()).toContain(i18n.global.t('customer.order.underReview') as string)
    expect(wrapper.text()).not.toContain(submitLabel)
  })

  it('an automatic payment past awaiting_proof reads as success, never as review', async () => {
    // bKash confirmed the money: the transient under_review hop the settlement
    // RPC walks through must never surface as proof language.
    const state = reactive({ status: 'under_review' as string | null })
    const checkout = fakeCheckout({
      existingOrder: computed(() =>
        state.status
          ? ({
              id: 'o3',
              slug: 's',
              gateway_kind: 'bkash',
              status: state.status,
              reference_code: 'RC3',
              amount: 500,
              reject_reason_en: null,
              reject_reason_bn: null,
            } as never)
          : null,
      ) as unknown as PageCheckout['existingOrder'],
      orderGateway: computed(() => ({
        provider: 'bkash_pgw',
      })) as unknown as PageCheckout['orderGateway'],
      orderPaysOnline: computed(() => true),
    })

    // Open with the order already under review: straight to the status page.
    const wrapper = await mountModal(checkout)
    expect(wrapper.text()).toContain('RC3')

    const approvedLabel = i18n.global.t('customer.order.status.approved') as string
    const reviewText = i18n.global.t('customer.order.underReview') as string
    expect(wrapper.text()).toContain(approvedLabel)
    expect(wrapper.text()).not.toContain(reviewText)
  })

  it('reopening after a confirmed manual submission shows the status page, not send', async () => {
    const order = ref<Record<string, unknown> | null>(null)
    const bankGateway = {
      id: 'g2',
      kind: 'bank',
      name_bn: null,
      name_en: 'Bank',
      provider: null,
      sort_order: 1,
      account_number: '01700',
      account_name: 'Cofibuy',
      account_fields: [],
      instructions_md_en: null,
      instructions_md_bn: null,
      reference_prompt_en: null,
      reference_prompt_bn: null,
      supports_reference: false,
      evidence_fields: [
        { key: 'trxid', type: 'text', required: true, label_en: 'TrxID', label_bn: null },
      ],
    }
    const checkout = fakeCheckout({
      selectedKind: ref('bank') as unknown as PageCheckout['selectedKind'],
      selectedGateway: computed(() => bankGateway) as unknown as PageCheckout['selectedGateway'],
      pickedGatewayName: computed(() => 'Bank') as unknown as PageCheckout['pickedGatewayName'],
      selectedAccountFields: computed(() => []) as unknown as PageCheckout['selectedAccountFields'],
      selectedInstructions: computed(() => null) as unknown as PageCheckout['selectedInstructions'],
      kindPaysOnline: computed(() => false),
      createManualOrder: async () => {
        order.value = {
          id: 'o4',
          slug: 's',
          gateway_kind: 'bank',
          status: 'under_review',
          reference_code: 'RC4',
          amount: 500,
          reject_reason_en: null,
          reject_reason_bn: null,
        }
      },
    })
    checkout.existingOrder = computed(() => order.value) as unknown as PageCheckout['existingOrder']

    const wrapper = await mountModal(checkout, false)
    await wrapper.setProps({ open: true })
    await flushPromises()

    // Walk to send: gateway phase (no order yet), then the banner.
    await wrapper.find('.gateway-banner').trigger('click')
    await flushPromises()

    // Confirm a manual payment from the send step.
    await wrapper.find('#trxid').setValue('TRX654321')
    await wrapper.find('form').trigger('submit')
    await flushPromises()
    expect(wrapper.text()).toContain('RC4')

    // Close, then reopen: the status page is the whole story now.
    await wrapper.setProps({ open: false })
    await flushPromises()
    await wrapper.setProps({ open: true })
    await flushPromises()

    expect(wrapper.text()).toContain('RC4')
    const reviewText = i18n.global.t('customer.order.underReview') as string
    expect(wrapper.text()).toContain(reviewText)
  })

  it('an order that expires while the modal is open returns to the gateway phase', async () => {
    // Reactive, so the modal's watcher sees the expiry the polling would report.
    const state = reactive({ status: 'awaiting_proof' as string | null })
    const checkout = fakeCheckout({
      existingOrder: computed(() =>
        state.status
          ? ({
              id: 'o1',
              slug: 's',
              gateway_kind: 'bkash',
              status: state.status,
              reference_code: 'RC1',
              amount: 500,
              reject_reason_en: null,
              reject_reason_bn: null,
            } as never)
          : null,
      ) as unknown as PageCheckout['existingOrder'],
    })
    const wrapper = await mountModal(checkout)
    // awaiting_proof opens at the send step.
    expect(wrapper.text()).toContain('RC1')

    state.status = 'expired'
    await flushPromises()
    expect(wrapper.text()).toContain(i18n.global.t('customer.paywall.chooseMethod') as string)
  })
})

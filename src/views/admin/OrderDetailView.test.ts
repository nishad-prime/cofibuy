import { mount, flushPromises } from '@vue/test-utils'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { computed, defineComponent, h } from 'vue'
import OrderDetailView from '@/views/admin/OrderDetailView.vue'

/**
 * The actions on this page follow the order's state. The RPCs refuse anything
 * else - approve and reject only move an order out of `under_review`, and the
 * probe reset matters only while the customer can still act - so buttons that
 * render on every order were a promise the database breaks on press.
 */

const rpc = vi.fn()

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => ({ rpc: (...args: unknown[]) => rpc(...args) }),
}))

vi.mock('@/composables/useStaffRole', () => ({
  // `isStaff` is a ComputedRef in the real composable; the view reads `.value`.
  useStaffRole: () => ({
    isStaff: computed(() => true),
    isOwner: computed(() => true),
  }),
}))

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { id: '11111111-1111-4111-8111-111111111111' } }),
  useRouter: () => ({ push: vi.fn() }),
}))

vi.mock('@/i18n/admin', () => ({
  useAdminI18n: () => ({ t: (key: string) => key }),
  ensureAdminMessages: async () => undefined,
}))

/** The evidence fields editor is a real component with inputs of its own. */
const FieldEditorStub = defineComponent({
  name: 'FieldEditorStub',
  props: { fields: { type: Array, default: () => [] } },
  setup: () => () => h('div'),
})

function orderRow(status: string) {
  return {
    id: '11111111-1111-4111-8111-111111111111',
    status,
    amount: 500,
    reference_code: 'AB12CD34',
    created_at: '2026-01-01T00:00:00Z',
    submitted_at: '2026-01-01T00:05:00Z',
    phone_e: null,
    phone_e164: null,
    has_duplicate_trxid: null,
    reject_reason_en: null,
    reject_reason_bn: null,
    gateway: { name_en: 'bKash Personal', name_bn: null },
    link: { slug: 'report', title_en: 'Report', title_bn: null },
    evidence: [],
    duplicates: [],
  }
}

async function mountAt(status: string) {
  rpc.mockImplementation((name: string) => {
    if (name === 'admin_order_detail')
      return Promise.resolve({ data: orderRow(status), error: null })
    return Promise.resolve({ data: null, error: null })
  })

  const wrapper = mount(OrderDetailView, {
    global: {
      plugins: [],
      stubs: {
        EvidenceFieldEditor: FieldEditorStub,
        AccountFieldEditor: FieldEditorStub,
        OrderStatusBadge: defineComponent({
          name: 'BadgeStub',
          props: { status: String },
          setup: () => () => h('span'),
        }),
      },
    },
  })
  await flushPromises()
  return wrapper
}

beforeEach(() => {
  rpc.mockReset()
})

describe('order actions follow the order state', () => {
  it('an under-review order offers approve and reject', async () => {
    const wrapper = await mountAt('under_review')
    expect(wrapper.text()).toContain('admin.queue.approve')
    expect(wrapper.text()).toContain('admin.queue.reject')
  })

  it('an approved order offers nothing to press, but says so', async () => {
    const wrapper = await mountAt('approved')
    expect(wrapper.text()).not.toContain('admin.queue.approve')
    expect(wrapper.text()).not.toContain('admin.queue.reject')
    // The empty action area explains itself instead of reading as a bug.
    expect(wrapper.text()).toContain('admin.queue.hintApproved')
  })

  it('a locked order offers only the probe reset', async () => {
    const wrapper = await mountAt('locked')
    expect(wrapper.text()).not.toContain('admin.queue.approve')
    expect(wrapper.text()).toContain('admin.queue.resetProbes')
  })
})

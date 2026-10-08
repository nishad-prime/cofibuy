import { mount, flushPromises } from '@vue/test-utils'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import DashboardView from '@/views/admin/DashboardView.vue'

/**
 * The dashboard is the panel's landing surface: four cards the operator reads
 * before anything else, the trend the RPCs compute, and the two lists that
 * link onward. These tests pin what each card and list shows, because a
 * dashboard that silently renders zeros is worse than one that fails loudly.
 */

const rpc = vi.fn()

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => ({ rpc: (...args: unknown[]) => rpc(...args) }),
}))

vi.mock('vue-chartjs', () => ({
  // The chart needs a real canvas, which jsdom does not draw; the test cares
  // about the numbers around it, not the pixels inside it.
  Chart: { template: '<canvas />' },
}))

vi.mock('@/i18n/admin', () => ({
  useAdminI18n: () => ({ t: (key: string) => key }),
  ensureAdminMessages: async () => undefined,
}))

const STATS = {
  awaiting_review: 2,
  awaiting_proof: 1,
  rejected: 0,
  approved_total: 5,
  locked: 0,
  expired_total: 3,
  total_orders: 11,
  customers: 7,
  revenue: 5000,
  revenue_30d: 2500,
  orders_30d: 8,
  active_pages: 3,
  active_gateways: 1,
}

beforeEach(() => {
  rpc.mockReset()
  rpc.mockImplementation((name: string) => {
    if (name === 'admin_stats') return Promise.resolve({ data: STATS, error: null })
    if (name === 'admin_analytics')
      return Promise.resolve({
        data: [
          { day: '2026-01-01', orders_created: 1, orders_approved: 0, revenue_approved: 0 },
          { day: '2026-01-02', orders_created: 2, orders_approved: 1, revenue_approved: 500 },
        ],
        error: null,
      })
    if (name === 'admin_page_performance')
      return Promise.resolve({
        data: [
          { slug: 'report', title_en: 'Report', title_bn: null, orders_approved: 1, revenue: 500 },
        ],
        error: null,
      })
    if (name === 'admin_orders')
      return Promise.resolve({
        data: [
          {
            id: '11111111-1111-4111-8111-111111111111',
            slug: 'report',
            title_en: 'Report',
            title_bn: null,
            gateway_kind: 'bkash',
            status: 'under_review',
            reference_code: 'AB12CD34',
            amount: 500,
            phone_e164: null,
            attempt_count: 0,
            probe_count: 0,
            created_at: '2026-01-01T00:00:00Z',
            expires_at: '2026-01-02T00:00:00Z',
            submitted_at: null,
            reject_reason_en: null,
            reject_reason_bn: null,
          },
        ],
        error: null,
      })
    return Promise.resolve({ data: null, error: { message: `unexpected rpc: ${name}` } })
  })
})

describe('the dashboard', () => {
  it('shows the four cards with the numbers that decide what happens next', async () => {
    const wrapper = mount(DashboardView, { global: { plugins: [] } })
    await flushPromises()

    expect(wrapper.text()).toContain('admin.dashboard.revenue30')
    expect(wrapper.text()).toContain('admin.dashboard.awaitingReview')
    // The actionable number links straight into the queue it belongs to.
    expect(wrapper.text()).toContain('admin.dashboard.awaitingReviewHint')
  })

  it('renders the 30-day series and the two lists', async () => {
    const wrapper = mount(DashboardView, { global: { plugins: [] } })
    await flushPromises()

    expect(wrapper.text()).toContain('Report')
    expect(wrapper.text()).toContain('AB12CD34')
    expect(wrapper.text()).toContain('admin.dashboard.topPages')
  })

  it('fails loudly when any of the four reads breaks', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'admin_stats') return Promise.resolve({ data: STATS, error: null })
      return Promise.resolve({ data: null, error: { message: `broken: ${name}` } })
    })

    const wrapper = mount(DashboardView, { global: { plugins: [] } })
    await flushPromises()

    expect(wrapper.text()).toContain('broken: admin_analytics')
    // A half-loaded dashboard must not render: zeros read as truth.
    expect(wrapper.text()).not.toContain('admin.dashboard.topPages')
  })
})

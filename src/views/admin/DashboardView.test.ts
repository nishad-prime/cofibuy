import { mount, flushPromises } from '@vue/test-utils'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import DashboardView from '@/views/admin/DashboardView.vue'

/**
 * The dashboard is the panel's landing surface: the cards the operator reads
 * before anything else, the trend the RPCs compute, and the lists that link
 * onward. These tests pin what each card and list shows, because a dashboard
 * that silently renders zeros is worse than one that fails loudly.
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

const ANALYTICS = [
  { day: '2026-01-01', views: 10, orders_created: 1, orders_approved: 0, revenue_approved: 0 },
  { day: '2026-01-02', views: 20, orders_created: 2, orders_approved: 1, revenue_approved: 500 },
]

const TRAFFIC = {
  days: 30,
  funnel: {
    views: 30,
    orders_created: 3,
    orders_submitted: 2,
    orders_approved: 1,
    conversion_rate: 3.33,
  },
  countries: [{ country: 'BD', views: 25 }],
  devices: [
    { device_type: 'mobile', views: 20 },
    { device_type: 'desktop', views: 10 },
  ],
  referrers: [{ referrer: 'google.com', views: 12 }],
  gateways: [{ kind: 'bkash Personal', orders: 1, revenue: 500 }],
  turnaround: { avg_minutes: 42.5, median_minutes: 30 },
  rejections: [{ reason: 'unclear proof', orders: 1 }],
  pages: [
    {
      slug: 'report',
      title_en: 'Report',
      title_bn: null,
      views: 30,
      orders_created: 3,
      orders_approved: 1,
      revenue: 500,
      conversion_rate: 3.33,
    },
  ],
}

beforeEach(() => {
  rpc.mockReset()
  rpc.mockImplementation((name: string) => {
    if (name === 'admin_stats') return Promise.resolve({ data: STATS, error: null })
    if (name === 'admin_analytics') return Promise.resolve({ data: ANALYTICS, error: null })
    if (name === 'admin_traffic_stats') return Promise.resolve({ data: TRAFFIC, error: null })
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
  it('shows the cards with the numbers that decide what happens next', async () => {
    const wrapper = mount(DashboardView, { global: { plugins: [] } })
    await flushPromises()

    expect(wrapper.text()).toContain('admin.dashboard.revenue30')
    expect(wrapper.text()).toContain('admin.dashboard.awaitingReview')
    // The actionable number links straight into the queue it belongs to.
    expect(wrapper.text()).toContain('admin.dashboard.awaitingReviewHint')
    // The traffic row: the window's visits and what they became.
    expect(wrapper.text()).toContain('admin.dashboard.views')
    expect(wrapper.text()).toContain('admin.dashboard.conversion')
    expect(wrapper.text()).toContain('3.33')
    expect(wrapper.text()).toContain('42.5m')
  })

  it('renders the trend, funnel and the lists', async () => {
    const wrapper = mount(DashboardView, { global: { plugins: [] } })
    await flushPromises()

    expect(wrapper.text()).toContain('Report')
    expect(wrapper.text()).toContain('AB12CD34')
    expect(wrapper.text()).toContain('admin.dashboard.topPages')
    // Funnel stages with the window's numbers.
    expect(wrapper.text()).toContain('admin.dashboard.stageViews')
    expect(wrapper.text()).toContain('admin.dashboard.stageApproved')
    // Traffic breakdowns render from the stats payload.
    expect(wrapper.text()).toContain('BD')
    expect(wrapper.text()).toContain('unclear proof')
  })

  it('switching the range refetches the windowed reads with the new days', async () => {
    const wrapper = mount(DashboardView, { global: { plugins: [] } })
    await flushPromises()

    rpc.mockClear()
    const buttons = wrapper.findAll('button')
    const seven = buttons.find((b) => b.text() === '7d')!
    await seven.trigger('click')
    await flushPromises()

    const analyticsCall = rpc.mock.calls.find((call) => call[0] === 'admin_analytics')
    expect(analyticsCall?.[1]).toEqual({ p_days: 7 })
    const trafficCall = rpc.mock.calls.find((call) => call[0] === 'admin_traffic_stats')
    expect(trafficCall?.[1]).toEqual({ p_days: 7 })
  })

  it('fails loudly when a windowed read breaks', async () => {
    rpc.mockImplementation((name: string) => {
      if (name === 'admin_stats') return Promise.resolve({ data: STATS, error: null })
      if (name === 'admin_orders') return Promise.resolve({ data: [], error: null })
      return Promise.resolve({ data: null, error: { message: `broken: ${name}` } })
    })

    const wrapper = mount(DashboardView, { global: { plugins: [] } })
    await flushPromises()

    expect(wrapper.text()).toContain('broken: admin_analytics')
    // A half-loaded dashboard must not render: zeros read as truth.
    expect(wrapper.text()).not.toContain('admin.dashboard.topPages')
  })
})

<template>
  <div>
    <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="page-title">{{ t('admin.dashboard.heading') }}</h1>
        <p class="page-subtitle">{{ t('admin.dashboard.subtitle') }}</p>
      </div>

      <!-- The range: every chart and windowed number below follows it. -->
      <div class="flex items-center gap-4">
        <span v-if="connected" class="flex items-center gap-1.5 text-xs font-medium text-stone-400">
          <span class="live-dot size-2 rounded-full bg-emerald-500" aria-hidden="true" />
          {{ t('admin.dashboard.live') }}
        </span>

        <div class="flex rounded-lg border border-white/15 bg-white/5 p-0.5">
          <button
            v-for="range in RANGES"
            :key="range"
            type="button"
            class="rounded-md px-3 py-1.5 text-sm font-medium transition"
            :class="
              range === selectedRange
                ? 'bg-stone-100 text-stone-900'
                : 'text-stone-400 hover:text-stone-100'
            "
            @click="selectRange(range)"
          >
            {{ range }}d
          </button>
        </div>
      </div>
    </header>

    <div v-if="loading" class="empty-state">{{ t('admin.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <template v-else-if="stats">
      <!-- Cards: the numbers that decide what the operator does next. -->
      <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.revenue30') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900">
            <AnimatedNumber :value="live?.revenue_30d ?? stats.revenue_30d" money />
          </p>
          <p class="hint mt-1">
            {{ t('admin.dashboard.allTime') }}:
            <span class="ltr-value">{{ formatMoney(stats.revenue, 'en', currency) }}</span>
          </p>
        </div>
        <router-link to="/admin/queue" class="card card-pad hover:border-brand-400">
          <p class="hint">{{ t('admin.dashboard.awaitingReview') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900">
            <AnimatedNumber :value="live?.awaiting_review ?? stats.awaiting_review" />
          </p>
          <p class="hint mt-1">{{ t('admin.dashboard.awaitingReviewHint') }}</p>
        </router-link>
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.orders30') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900">
            <AnimatedNumber :value="live?.orders_created_30d ?? stats.orders_30d" />
          </p>
          <p class="hint mt-1">
            {{ t('admin.dashboard.allTime') }}:
            <span class="ltr-value">{{ stats.total_orders }}</span>
          </p>
        </div>
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.livePages') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900 ltr-value">{{ stats.active_pages }}</p>
          <p class="hint mt-1">
            {{ t('admin.dashboard.customers') }}:
            <AnimatedNumber :value="live?.customers ?? stats.customers" />
          </p>
        </div>
      </div>

      <!-- Traffic row: the window's visits and what they became. Deferred with
           the charts, so it shimmers until tier 2 lands. -->
      <div v-if="traffic" class="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.views') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900">
            <AnimatedNumber :value="live?.views_total ?? traffic.funnel.views" />
          </p>
          <p class="hint mt-1">
            {{ t('admin.dashboard.windowNote').replace('{days}', String(traffic.days)) }}
          </p>
        </div>
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.conversion') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900 ltr-value">
            {{ traffic.funnel.conversion_rate ?? '—'
            }}<span v-if="traffic.funnel.conversion_rate !== null">%</span>
          </p>
          <p class="hint mt-1">{{ t('admin.dashboard.conversionNote') }}</p>
        </div>
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.turnaround') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900 ltr-value">
            {{ formatTurnaround(traffic.turnaround.avg_minutes) }}
          </p>
          <p class="hint mt-1">
            {{ t('admin.dashboard.median') }}:
            <span class="ltr-value">
              {{ formatTurnaround(traffic.turnaround.median_minutes) }}
            </span>
          </p>
        </div>
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.ordersSubmitted') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900 ltr-value">
            {{ traffic.funnel.orders_submitted }}
          </p>
          <p class="hint mt-1">
            {{ t('admin.dashboard.windowNote').replace('{days}', String(traffic.days)) }}
          </p>
        </div>
      </div>
      <div v-else class="dash-skeleton mt-4 h-28 w-full" aria-hidden="true" />

      <!-- The trend: orders as bars, revenue and views as lines. Two axes
           because the units differ, and the bar shape keeps quiet days visibly
           zero rather than implying a line through nothing. -->
      <section v-if="!analyticsLoading && traffic" class="card card-pad mt-6">
        <h2 class="text-sm font-semibold text-stone-900">
          {{ t('admin.dashboard.trend').replace('{days}', String(traffic.days)) }}
        </h2>
        <div class="mt-4 h-64">
          <Chart :type="chartType" :data="chartData" :options="chartOptions" />
        </div>
      </section>
      <div v-else class="dash-skeleton mt-6 h-80 w-full" aria-hidden="true" />

      <!-- Funnel: views to money, one horizontal bar per stage. -->
      <section v-if="traffic" class="card card-pad mt-6">
        <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.dashboard.funnel') }}</h2>
        <div class="mt-4 space-y-3">
          <div v-for="stage in funnelStages" :key="stage.label" class="flex items-center gap-3">
            <span class="w-28 shrink-0 text-xs font-medium text-stone-500">
              {{ stage.label }}
            </span>
            <div class="h-6 flex-1 overflow-hidden rounded-md bg-stone-100">
              <div
                class="flex h-full items-center justify-end rounded-md bg-brand-500/80 pr-2 transition-all"
                :style="{ width: `${stage.pct}%` }"
              >
                <span v-if="stage.pct > 12" class="text-xs font-bold text-white ltr-value">
                  {{ stage.value }}
                </span>
              </div>
            </div>
            <span class="w-12 shrink-0 text-right text-xs text-stone-500 ltr-value">
              {{ stage.pct }}%
            </span>
          </div>
        </div>
      </section>

      <div v-if="traffic" class="mt-6 grid gap-6 lg:grid-cols-2">
        <!-- Devices: where the shop is opened. Bars, not a canvas: the split
             must stay readable even if a chart fails to draw. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.dashboard.devices') }}</h2>
          <ul v-if="deviceRows.length > 0" class="mt-4 space-y-2.5">
            <li v-for="row in deviceRows" :key="row.device_type" class="flex items-center gap-3">
              <span class="w-20 shrink-0 text-xs font-medium text-stone-400">
                {{ t(`admin.dashboard.device.${row.device_type}`) }}
              </span>
              <div class="h-2.5 flex-1 overflow-hidden rounded-full bg-stone-100">
                <div
                  class="h-full rounded-full bg-brand-500"
                  :style="{ width: `${(row.views / maxDeviceViews) * 100}%` }"
                />
              </div>
              <span class="w-12 shrink-0 text-right text-xs text-stone-500 ltr-value">
                {{ row.views }}
              </span>
              <span class="w-14 shrink-0 text-right text-xs text-stone-500 ltr-value">
                {{ Math.round((row.views / totalDeviceViews) * 100) }}%
              </span>
            </li>
          </ul>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noTraffic') }}</p>
        </section>

        <!-- Top locations: city and country, the IP-derived view. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">
            {{ t('admin.dashboard.locations') }}
          </h2>
          <ul v-if="locationRows.length > 0" class="mt-4 space-y-2.5">
            <li
              v-for="row in locationRows"
              :key="`${row.country}-${row.city}`"
              class="flex items-center gap-3"
            >
              <span class="w-32 shrink-0 truncate text-xs font-bold text-stone-700">
                <span v-if="row.city">{{ row.city }}, </span>
                <span class="ltr-value">{{ row.country }}</span>
              </span>
              <div class="h-2.5 flex-1 overflow-hidden rounded-full bg-stone-100">
                <div
                  class="h-full rounded-full bg-brand-500"
                  :style="{ width: `${(row.views / maxLocationViews) * 100}%` }"
                />
              </div>
              <span class="w-12 shrink-0 text-right text-xs text-stone-500 ltr-value">
                {{ row.views }}
              </span>
            </li>
          </ul>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noTraffic') }}</p>
        </section>

        <!-- Traffic sources: where the visitors came from. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">
            {{ t('admin.dashboard.trafficSources') }}
          </h2>
          <ul v-if="sourceRows.length > 0" class="mt-4 space-y-2.5">
            <li v-for="row in sourceRows" :key="row.referrer" class="flex items-center gap-3">
              <span class="w-32 shrink-0 truncate text-xs font-bold text-stone-700 ltr-value">
                {{ row.referrer }}
              </span>
              <div class="h-2.5 flex-1 overflow-hidden rounded-full bg-stone-100">
                <div
                  class="h-full rounded-full bg-brand-500"
                  :style="{ width: `${(row.views / maxSourceViews) * 100}%` }"
                />
              </div>
              <span class="w-12 shrink-0 text-right text-xs text-stone-500 ltr-value">
                {{ row.views }}
              </span>
            </li>
          </ul>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noSources') }}</p>
        </section>

        <!-- Gateways: which rails the approved money used. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.dashboard.gateways') }}</h2>
          <table v-if="gatewayRows.length > 0" class="mt-4 w-full text-sm">
            <thead>
              <tr>
                <th class="th text-left">{{ t('admin.dashboard.gateway') }}</th>
                <th class="th text-right">{{ t('admin.dashboard.orders') }}</th>
                <th class="th text-right">{{ t('admin.dashboard.revenue') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="row in gatewayRows" :key="row.kind">
                <td class="td">{{ row.kind }}</td>
                <td class="td text-right ltr-value">{{ row.orders }}</td>
                <td class="td text-right ltr-value">
                  {{ formatMoney(row.revenue, 'en', currency) }}
                </td>
              </tr>
            </tbody>
          </table>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noSales') }}</p>
        </section>

        <!-- Rejections: what the operator says no to, most often. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">
            {{ t('admin.dashboard.rejections') }}
          </h2>
          <ul v-if="rejectionRows.length > 0" class="mt-4 space-y-2.5">
            <li v-for="row in rejectionRows" :key="row.reason" class="flex items-center gap-3">
              <span class="min-w-0 flex-1 truncate text-sm text-stone-700">
                {{ row.reason }}
              </span>
              <span class="ltr-value text-sm font-bold text-stone-900">{{ row.orders }}</span>
            </li>
          </ul>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noRejections') }}</p>
        </section>
      </div>

      <div class="mt-6 grid gap-6 lg:grid-cols-2">
        <!-- Top pages: what actually sells, and how well it converts. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.dashboard.topPages') }}</h2>
          <table v-if="pageRows.length > 0" class="mt-4 w-full text-sm">
            <thead>
              <tr>
                <th class="th text-left">{{ t('admin.dashboard.page') }}</th>
                <th class="th text-right">{{ t('admin.dashboard.views') }}</th>
                <th class="th text-right">{{ t('admin.dashboard.orders') }}</th>
                <th class="th text-right">{{ t('admin.dashboard.conversionShort') }}</th>
                <th class="th text-right">{{ t('admin.dashboard.revenue') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="row in pageRows" :key="row.slug" class="row-link">
                <td class="td">{{ row.title_en || row.title_bn || row.slug }}</td>
                <td class="td text-right ltr-value">{{ row.views }}</td>
                <td class="td text-right ltr-value">{{ row.orders_approved }}</td>
                <td class="td text-right ltr-value">
                  {{ row.conversion_rate !== null ? `${row.conversion_rate}%` : '—' }}
                </td>
                <td class="td text-right ltr-value">
                  {{ formatMoney(row.revenue, 'en', currency) }}
                </td>
              </tr>
            </tbody>
          </table>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noSales') }}</p>
        </section>

        <!-- Recent orders: the queue's newest rows, one click from here. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">
            {{ t('admin.dashboard.recentOrders') }}
          </h2>
          <ul v-if="recentOrders.length > 0" class="mt-4 space-y-2">
            <li v-for="order in recentOrders" :key="order.id">
              <router-link
                :to="`/admin/orders/${order.id}`"
                class="flex items-center justify-between gap-3 rounded-lg border border-stone-100 px-3 py-2 text-sm hover:border-stone-300"
              >
                <span class="min-w-0">
                  <span class="ltr-value font-medium text-stone-900">
                    {{ order.reference_code }}
                  </span>
                  <span class="ml-2 text-stone-500">{{ order.title_en || order.slug }}</span>
                </span>
                <span class="shrink-0 text-right">
                  <span class="ltr-value font-medium text-stone-900">
                    {{ formatMoney(order.amount ?? 0, 'en', currency) }}
                  </span>
                  <OrderStatusBadge :status="order.status" :label="statusLabel(order.status)" />
                </span>
              </router-link>
            </li>
          </ul>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noOrders') }}</p>
        </section>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { Chart } from 'vue-chartjs'
import type { ChartData } from 'chart.js'
import {
  Chart as ChartJS,
  CategoryScale,
  Legend,
  LinearScale,
  LineElement,
  BarElement,
  PointElement,
  ArcElement,
  Tooltip,
} from 'chart.js'
import { formatMoney } from '@/lib/money'
import { useAdminCurrency } from '@/composables/useAdminCurrency'
import { useLiveStats } from '@/composables/useLiveStats'
import { rpc, rpcList } from '@/lib/rpc'
import type { MyOrder } from '@/lib/rpc'
import AnimatedNumber from '@/components/admin/AnimatedNumber.vue'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import { useAdminI18n } from '@/i18n/admin'

ChartJS.register(
  CategoryScale,
  LinearScale,
  BarElement,
  LineElement,
  PointElement,
  ArcElement,
  Tooltip,
  Legend,
)

const { t } = useAdminI18n()
const { currency, load: loadCurrency } = useAdminCurrency()

const RANGES = [7, 30, 90] as const
type Range = (typeof RANGES)[number]

interface Stats {
  awaiting_review: number
  awaiting_proof: number
  rejected: number
  approved_total: number
  locked: number
  expired_total: number
  total_orders: number
  customers: number
  revenue: number
  revenue_30d: number
  orders_30d: number
  active_pages: number
  active_gateways: number
}

interface AnalyticsRow {
  day: string
  views: number
  orders_created: number
  orders_approved: number
  revenue_approved: number
}

interface TrafficStats {
  days: number
  funnel: {
    views: number
    orders_created: number
    orders_submitted: number
    orders_approved: number
    conversion_rate: number | null
  }
  countries: Array<{ country: string; views: number }>
  locations: Array<{ country: string; city: string | null; views: number }>
  devices: Array<{ device_type: string; views: number }>
  referrers: Array<{ referrer: string; views: number }>
  gateways: Array<{ kind: string; orders: number; revenue: number }>
  turnaround: { avg_minutes: number | null; median_minutes: number | null }
  rejections: Array<{ reason: string; orders: number }>
  pages: Array<{
    slug: string
    title_en: string | null
    title_bn: string | null
    views: number
    orders_created: number
    orders_approved: number
    revenue: number
    conversion_rate: number | null
  }>
}

const stats = ref<Stats | null>(null)
const analytics = ref<AnalyticsRow[]>([])
const traffic = ref<TrafficStats | null>(null)
const recentOrders = ref<MyOrder[]>([])
const loading = ref(true)
const analyticsLoading = ref(false)
const error = ref<string | null>(null)
const selectedRange = ref<Range>(30)

const { snapshot: live, connected } = useLiveStats()

const statusLabel = (status: string): string => t(`admin.status.${status}`)

const loadAnalytics = async (): Promise<void> => {
  analyticsLoading.value = true
  try {
    const [analyticsRes, trafficRes] = await Promise.all([
      rpc<AnalyticsRow[]>('admin_analytics', { p_days: selectedRange.value }),
      rpc<TrafficStats>('admin_traffic_stats', { p_days: selectedRange.value }),
    ])

    for (const res of [analyticsRes, trafficRes]) {
      if (res.error) {
        error.value = res.error.message
        return
      }
    }

    analytics.value = (analyticsRes.data ?? []) as unknown as AnalyticsRow[]
    traffic.value = trafficRes.data
  } finally {
    analyticsLoading.value = false
  }
}

const selectRange = async (range: Range): Promise<void> => {
  if (range === selectedRange.value) return
  selectedRange.value = range
  await loadAnalytics()
}

const formatTurnaround = (minutes: number | null): string => {
  if (minutes === null) return '—'
  if (minutes < 60) return `${minutes}m`
  if (minutes < 60 * 24) return `${(minutes / 60).toFixed(1)}h`
  return `${(minutes / (60 * 24)).toFixed(1)}d`
}

const chartType = 'bar' as const

const chartData = computed<ChartData<'bar' | 'line'>>(() => ({
  labels: analytics.value.map((row) => row.day.slice(5)),
  datasets: [
    {
      type: 'bar' as const,
      label: t('admin.dashboard.ordersCreated'),
      data: analytics.value.map((row) => row.orders_created),
      backgroundColor: 'rgba(13, 148, 136, 0.35)',
      yAxisID: 'yOrders',
    },
    {
      type: 'line' as const,
      label: t('admin.dashboard.revenuePerDay'),
      data: analytics.value.map((row) => row.revenue_approved),
      borderColor: '#0f766e',
      backgroundColor: '#0f766e',
      tension: 0.3,
      pointRadius: 2,
      yAxisID: 'yRevenue',
    },
    {
      type: 'line' as const,
      label: t('admin.dashboard.viewsPerDay'),
      data: analytics.value.map((row) => row.views),
      borderColor: '#94a3b8',
      backgroundColor: '#94a3b8',
      tension: 0.3,
      pointRadius: 2,
      borderDash: [4, 4],
      yAxisID: 'yOrders',
    },
  ],
}))

const chartOptions = {
  responsive: true,
  maintainAspectRatio: false,
  scales: {
    yOrders: {
      position: 'left' as const,
      beginAtZero: true,
      ticks: { precision: 0, color: '#a8a29e' },
      grid: { color: 'rgba(255, 255, 255, 0.06)' },
    },
    yRevenue: {
      position: 'right' as const,
      beginAtZero: true,
      ticks: { color: '#a8a29e' },
      grid: { drawOnChartArea: false },
    },
    x: { ticks: { color: '#a8a29e' }, grid: { display: false } },
  },
}

const funnelStages = computed(() => {
  const funnel = traffic.value?.funnel
  if (!funnel) return []
  const top = Math.max(funnel.views, 1)
  const stage = (label: string, value: number): { label: string; value: number; pct: number } => ({
    label,
    value,
    pct: Math.round((value / top) * 100),
  })
  return [
    stage(t('admin.dashboard.stageViews'), funnel.views),
    stage(t('admin.dashboard.stageCreated'), funnel.orders_created),
    stage(t('admin.dashboard.stageSubmitted'), funnel.orders_submitted),
    stage(t('admin.dashboard.stageApproved'), funnel.orders_approved),
  ]
})

const deviceRows = computed(() => traffic.value?.devices ?? [])
const maxDeviceViews = computed(() => Math.max(...deviceRows.value.map((r) => r.views), 1))
const totalDeviceViews = computed(() =>
  Math.max(
    deviceRows.value.reduce((sum, r) => sum + r.views, 0),
    1,
  ),
)

const sourceRows = computed(() => traffic.value?.referrers ?? [])
const maxSourceViews = computed(() => Math.max(...sourceRows.value.map((r) => r.views), 1))

const locationRows = computed(() => traffic.value?.locations ?? [])
const maxLocationViews = computed(() => Math.max(...locationRows.value.map((r) => r.views), 1))
const gatewayRows = computed(() => traffic.value?.gateways ?? [])
const rejectionRows = computed(() => traffic.value?.rejections ?? [])
const pageRows = computed(() => traffic.value?.pages ?? [])

onMounted(async () => {
  void loadCurrency()
  try {
    const [statsRes, recentRes] = await Promise.all([
      rpc<Stats>('admin_stats'),
      rpcList<MyOrder>('admin_orders', { p_limit: 8 }),
    ])

    for (const res of [statsRes, recentRes]) {
      if (res.error) {
        error.value = res.error.message
        loading.value = false
        return
      }
    }

    stats.value = statsRes.data
    recentOrders.value = (recentRes.data ?? []) as unknown as MyOrder[]
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load dashboard'
    loading.value = false
    return
  } finally {
    loading.value = false
  }

  // Tier 2: the heavy aggregates land behind their skeletons; KPIs are already
  // on screen and the live poller is running by now.
  await loadAnalytics()
})
</script>

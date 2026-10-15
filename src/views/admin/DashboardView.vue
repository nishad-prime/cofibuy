<template>
  <div>
    <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="page-title">{{ t('admin.dashboard.heading') }}</h1>
        <p class="page-subtitle">{{ t('admin.dashboard.subtitle') }}</p>
      </div>

      <!-- The range: every chart and windowed number below follows it. -->
      <div class="flex rounded-lg border border-stone-200 bg-white p-0.5">
        <button
          v-for="range in RANGES"
          :key="range"
          type="button"
          class="rounded-md px-3 py-1.5 text-sm font-medium transition"
          :class="
            range === selectedRange
              ? 'bg-stone-900 text-white'
              : 'text-stone-500 hover:text-stone-900'
          "
          @click="selectRange(range)"
        >
          {{ range }}d
        </button>
      </div>
    </header>

    <div v-if="loading" class="empty-state">{{ t('admin.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <template v-else-if="stats && traffic">
      <!-- Cards: the numbers that decide what the operator does next. -->
      <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.revenue30') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900 ltr-value">
            {{ formatMoney(stats.revenue_30d, 'en', currency) }}
          </p>
          <p class="hint mt-1">
            {{ t('admin.dashboard.allTime') }}:
            <span class="ltr-value">{{ formatMoney(stats.revenue, 'en', currency) }}</span>
          </p>
        </div>
        <router-link to="/admin/queue" class="card card-pad hover:border-brand-400">
          <p class="hint">{{ t('admin.dashboard.awaitingReview') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900 ltr-value">
            {{ stats.awaiting_review }}
          </p>
          <p class="hint mt-1">{{ t('admin.dashboard.awaitingReviewHint') }}</p>
        </router-link>
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.orders30') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900 ltr-value">{{ stats.orders_30d }}</p>
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
            <span class="ltr-value">{{ stats.customers }}</span>
          </p>
        </div>
      </div>

      <!-- Traffic row: the window's visits and what they became. -->
      <div class="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <div class="card card-pad">
          <p class="hint">{{ t('admin.dashboard.views') }}</p>
          <p class="mt-1 text-2xl font-bold text-stone-900 ltr-value">
            {{ traffic.funnel.views }}
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

      <!-- The trend: orders as bars, revenue and views as lines. Two axes
           because the units differ, and the bar shape keeps quiet days visibly
           zero rather than implying a line through nothing. -->
      <section class="card card-pad mt-6">
        <h2 class="text-sm font-semibold text-stone-900">
          {{ t('admin.dashboard.trend').replace('{days}', String(traffic.days)) }}
        </h2>
        <div class="mt-4 h-64">
          <Chart :type="chartType" :data="chartData" :options="chartOptions" />
        </div>
      </section>

      <!-- Funnel: views to money, one horizontal bar per stage. -->
      <section class="card card-pad mt-6">
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

      <div class="mt-6 grid gap-6 lg:grid-cols-2">
        <!-- Devices: where the shop is opened. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.dashboard.devices') }}</h2>
          <div v-if="deviceRows.length > 0" class="mx-auto mt-4 h-56">
            <Chart type="doughnut" :data="deviceChartData" :options="doughnutOptions" />
          </div>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noTraffic') }}</p>
        </section>

        <!-- Countries: where the visitors are. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.dashboard.countries') }}</h2>
          <ul v-if="countryRows.length > 0" class="mt-4 space-y-2.5">
            <li v-for="row in countryRows" :key="row.country" class="flex items-center gap-3">
              <span class="w-10 shrink-0 text-xs font-bold text-stone-700 ltr-value">
                {{ row.country }}
              </span>
              <div class="h-2.5 flex-1 overflow-hidden rounded-full bg-stone-100">
                <div
                  class="h-full rounded-full bg-brand-500"
                  :style="{ width: `${(row.views / maxCountryViews) * 100}%` }"
                />
              </div>
              <span class="w-12 shrink-0 text-right text-xs text-stone-500 ltr-value">
                {{ row.views }}
              </span>
            </li>
          </ul>
          <p v-else class="empty-state mt-4">{{ t('admin.dashboard.noTraffic') }}</p>
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
import { rpc, rpcList } from '@/lib/rpc'
import type { MyOrder } from '@/lib/rpc'
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
const error = ref<string | null>(null)
const selectedRange = ref<Range>(30)

const statusLabel = (status: string): string => t(`admin.status.${status}`)

const loadAnalytics = async (): Promise<void> => {
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
}

const selectRange = async (range: Range): Promise<void> => {
  if (range === selectedRange.value) return
  selectedRange.value = range
  loading.value = true
  await loadAnalytics()
  loading.value = false
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
    yOrders: { position: 'left' as const, beginAtZero: true, ticks: { precision: 0 } },
    yRevenue: { position: 'right' as const, beginAtZero: true, grid: { drawOnChartArea: false } },
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
const deviceColors = ['#0d9488', '#14b8a6', '#5eead4', '#94a3b8']

const deviceChartData = computed<ChartData<'doughnut'>>(() => ({
  // The RPC clamps device_type to three buckets, so the keys always exist.
  labels: deviceRows.value.map((row) => t(`admin.dashboard.device.${row.device_type}`)),
  datasets: [
    {
      data: deviceRows.value.map((row) => row.views),
      backgroundColor: deviceColors,
      borderWidth: 0,
    },
  ],
}))

const doughnutOptions = {
  responsive: true,
  maintainAspectRatio: false,
  cutout: '65%',
  plugins: { legend: { position: 'right' as const } },
}

const countryRows = computed(() => traffic.value?.countries ?? [])
const maxCountryViews = computed(() => Math.max(...countryRows.value.map((r) => r.views), 1))
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

    await loadAnalytics()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load dashboard'
  } finally {
    loading.value = false
  }
})
</script>

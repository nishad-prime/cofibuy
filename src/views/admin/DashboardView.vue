<template>
  <div>
    <header class="mb-6">
      <h1 class="page-title">{{ t('admin.dashboard.heading') }}</h1>
      <p class="page-subtitle">{{ t('admin.dashboard.subtitle') }}</p>
    </header>

    <div v-if="loading" class="empty-state">{{ t('admin.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <template v-else-if="stats">
      <!-- Cards: the four numbers that decide what the operator does next. -->
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

      <!-- The 30-day trend: orders appear as bars, revenue as the line. Two
           axes because the units differ, and the bar shape keeps quiet days
           visibly zero rather than implying a line through nothing. -->
      <section class="card card-pad mt-6">
        <h2 class="text-sm font-semibold text-stone-900">
          {{ t('admin.dashboard.trend').replace('{days}', String(analyticsDays)) }}
        </h2>
        <div class="mt-4 h-64">
          <Chart :type="chartType" :data="chartData" :options="chartOptions" />
        </div>
      </section>

      <div class="mt-6 grid gap-6 lg:grid-cols-2">
        <!-- Top pages: what actually sells. -->
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">
            {{ t('admin.dashboard.topPages') }}
          </h2>
          <table v-if="topPages.length > 0" class="mt-4 w-full text-sm">
            <thead>
              <tr>
                <th class="th text-left">{{ t('admin.dashboard.page') }}</th>
                <th class="th text-right">{{ t('admin.dashboard.orders') }}</th>
                <th class="th text-right">{{ t('admin.dashboard.revenue') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="row in topPages" :key="row.slug" class="row-link">
                <td class="td">{{ row.title_en || row.title_bn || row.slug }}</td>
                <td class="td text-right ltr-value">{{ row.orders_approved }}</td>
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
  Tooltip,
} from 'chart.js'
import { formatMoney } from '@/lib/money'
import { useAdminCurrency } from '@/composables/useAdminCurrency'
import { rpc, rpcList } from '@/lib/rpc'
import type { MyOrder } from '@/lib/rpc'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import { useAdminI18n } from '@/i18n/admin'

ChartJS.register(CategoryScale, LinearScale, BarElement, LineElement, PointElement, Tooltip, Legend)

const { t } = useAdminI18n()
const { currency, load: loadCurrency } = useAdminCurrency()

const analyticsDays = 30

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
  orders_created: number
  orders_approved: number
  revenue_approved: number
}

interface PagePerformance {
  slug: string
  title_en: string | null
  title_bn: string | null
  orders_approved: number
  revenue: number
}

const stats = ref<Stats | null>(null)
const analytics = ref<AnalyticsRow[]>([])
const topPages = ref<PagePerformance[]>([])
const recentOrders = ref<MyOrder[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const statusLabel = (status: string): string => t(`admin.status.${status}`)

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

onMounted(async () => {
  void loadCurrency()
  try {
    const [statsRes, analyticsRes, perfRes, recentRes] = await Promise.all([
      rpc<Stats>('admin_stats'),
      rpc<AnalyticsRow[]>('admin_analytics', { p_days: analyticsDays }),
      rpc<PagePerformance[]>('admin_page_performance', { p_limit: 5 }),
      rpcList<MyOrder>('admin_orders', { p_limit: 8 }),
    ])

    for (const res of [statsRes, analyticsRes, perfRes, recentRes]) {
      if (res.error) {
        error.value = res.error.message
        loading.value = false
        return
      }
    }

    stats.value = statsRes.data
    analytics.value = (analyticsRes.data ?? []) as unknown as AnalyticsRow[]
    topPages.value = (perfRes.data ?? []) as unknown as PagePerformance[]
    recentOrders.value = (recentRes.data ?? []) as unknown as MyOrder[]
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load dashboard'
  } finally {
    loading.value = false
  }
})
</script>

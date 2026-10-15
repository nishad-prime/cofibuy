<template>
  <div>
    <header class="mb-6">
      <h1 class="page-title">{{ t('admin.queue.heading') }}</h1>
      <p class="page-subtitle">Every order in the shop, filtered by where it stands.</p>
    </header>

    <!--
      Filter chips: one tap answers "show me the rejected ones" without the
      operator reading rows they have already decided on. All is an explicit
      chip rather than the absence of a filter, so the active state is always
      visible.
    -->
    <div class="mb-4 flex flex-wrap items-center gap-2">
      <button
        type="button"
        class="rounded-full border px-3 py-1.5 text-sm font-medium transition"
        :class="
          statusFilter === null
            ? 'border-brand-600 bg-brand-50 text-brand-800'
            : 'border-stone-200 bg-white text-stone-600 hover:border-stone-300'
        "
        @click="setStatusFilter(null)"
      >
        All
      </button>
      <button
        v-for="status in STATUSES"
        :key="status"
        type="button"
        class="rounded-full border px-3 py-1.5 text-sm font-medium transition"
        :class="
          statusFilter === status
            ? 'border-brand-600 bg-brand-50 text-brand-800'
            : 'border-stone-200 bg-white text-stone-600 hover:border-stone-300'
        "
        @click="setStatusFilter(status)"
      >
        {{ statusLabel(status) }}
      </button>
      <span class="ml-auto text-sm text-stone-500 ltr-value">{{ orders.length }}</span>
    </div>

    <p v-if="error" class="alert-error" role="alert">{{ error }}</p>

    <div v-else-if="loading" class="empty-state">{{ t('admin.common.loading') }}</div>

    <div v-else-if="orders.length === 0" class="card empty-state">
      <AppIcon name="check" :size="28" class="mx-auto mb-3 text-emerald-600" />
      <p class="font-medium text-stone-700">
        {{ statusFilter ? t('admin.status.' + statusFilter) : 'Nothing to review' }}
      </p>
      <p class="mt-1">New orders will appear here as soon as customers submit payment.</p>
    </div>

    <div v-else class="table-wrap">
      <div class="table-scroll">
        <table class="min-w-full divide-y divide-stone-200">
          <thead class="bg-stone-50">
            <tr>
              <th class="th">{{ t('admin.queue.reference') }}</th>
              <th class="th">{{ t('admin.common.status') }}</th>
              <th class="th">{{ t('admin.queue.amount') }}</th>
              <th class="th">{{ t('admin.queue.gateway') }}</th>
              <th class="th">{{ t('admin.queue.submitted') }}</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-stone-200">
            <tr
              v-for="order in orders"
              :key="order.id"
              class="row-link cursor-pointer"
              @click="viewOrder(order.id)"
            >
              <td class="td">
                <span class="ltr-value font-medium text-stone-900">
                  {{ order.reference_code || '—' }}
                </span>
              </td>
              <td class="td">
                <OrderStatusBadge :status="order.status" :label="statusLabel(order.status)" />
              </td>
              <td class="td">
                <span class="ltr-value">{{ formatMoney(order.amount ?? 0, 'en', currency) }}</span>
              </td>
              <td class="td">{{ gatewayLabel(order.kind) }}</td>
              <td class="td whitespace-nowrap text-stone-500">
                {{ formatDate(order.created_at) }}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { formatMoney } from '@/lib/money'
import { useAdminCurrency } from '@/composables/useAdminCurrency'
import { useAdminI18n } from '@/i18n/admin'
import AppIcon from '@/components/AppIcon.vue'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import { rpc } from '@/lib/rpc'

const router = useRouter()
const { t } = useAdminI18n()
const { currency, load: loadCurrency } = useAdminCurrency()

interface QueueOrder {
  id: string
  reference_code: string | null
  status: string
  amount: number | null
  kind: string
  created_at: string
}

const orders = ref<QueueOrder[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

/**
 * The status filter. `admin_orders` has taken `p_status` since the day it was
 * written; the UI just never offered it, so the operator scrolled a 500-row
 * table looking for the one rejected order.
 */
const STATUSES = [
  'under_review',
  'awaiting_proof',
  'approved',
  'rejected',
  'locked',
  'expired',
] as const

const statusFilter = ref<string | null>(null)
const loadedFor = ref<string | null>(null)

const loadOrders = async (): Promise<void> => {
  loading.value = true
  error.value = null
  try {
    const { data, error: rpcError } = await rpc<Record<string, unknown>>('admin_orders', {
      p_status: statusFilter.value,
    })

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    orders.value = (data ?? []) as unknown as typeof orders.value
    loadedFor.value = statusFilter.value
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load orders'
  } finally {
    loading.value = false
  }
}

const setStatusFilter = (status: string | null): void => {
  if (status === statusFilter.value) return
  statusFilter.value = status
  void loadOrders()
}

/**
 * `admin_orders` returns flat columns, not a nested gateway object: the amount
 * column is `amount`, in whole taka, and the method is `kind`.
 *
 * The queue is an operator tool and the amount gets reconciled against a bank
 * statement, so it stays Latin whatever the customer-facing locale is doing.
 */
const statusLabel = (status: string): string => t(`admin.status.${status}`)

/**
 * The gateway kinds are operator-authored free text these days ("bKash
 * Personal"), so the label is the kind itself. The old translation table
 * (`admin.gateways.<kind>`) only ever covered the enum era, and a lookup miss
 * rendered the raw key into the cell.
 */
const gatewayLabel = (kind: string): string => (kind ? kind : '—')

const formatDate = (date: string): string => {
  return new Date(date).toLocaleString()
}

const viewOrder = (orderId: string): void => {
  router.push(`/admin/orders/${orderId}`)
}

onMounted(() => {
  void loadCurrency()
  void loadOrders()
})
</script>

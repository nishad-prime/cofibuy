<template>
  <div>
    <header class="mb-6">
      <h1 class="page-title">Order queue</h1>
      <p class="page-subtitle">Payments awaiting your review and approval.</p>
    </header>

    <div v-if="loading" class="empty-state">Loading...</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <div v-else-if="orders.length === 0" class="card empty-state">
      <AppIcon name="check" :size="28" class="mx-auto mb-3 text-emerald-600" />
      <p class="font-medium text-stone-700">Nothing to review</p>
      <p class="mt-1">New orders will appear here as soon as customers submit payment.</p>
    </div>

    <div v-else class="table-wrap">
      <div class="table-scroll">
        <table class="min-w-full divide-y divide-stone-200">
          <thead class="bg-stone-50">
            <tr>
              <th class="th">Reference</th>
              <th class="th">Status</th>
              <th class="th">Amount</th>
              <th class="th">Gateway</th>
              <th class="th">Submitted</th>
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
 * `admin_orders` returns flat columns, not a nested gateway object: the amount
 * column is `amount`, in whole taka, and the method is `kind`.
 *
 * The queue is an operator tool and the amount gets reconciled against a bank
 * statement, so it stays Latin whatever the customer-facing locale is doing.
 */
const statusLabel = (status: string): string => t(`admin.status.${status}`)

const gatewayLabel = (kind: string): string => (kind ? t(`admin.gateways.${kind}`) || kind : '—')

const formatDate = (date: string): string => {
  return new Date(date).toLocaleString()
}

const viewOrder = (orderId: string): void => {
  router.push(`/admin/orders/${orderId}`)
}

onMounted(async () => {
  void loadCurrency()
  try {
    const { data, error: rpcError } = await rpc<Record<string, unknown>>('admin_orders')

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    orders.value = (data ?? []) as unknown as typeof orders.value
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load orders'
  } finally {
    loading.value = false
  }
})
</script>

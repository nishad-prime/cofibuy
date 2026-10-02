<template>
  <div>
    <h1 class="mb-6 text-2xl font-bold text-gray-900">Order Queue</h1>

    <div v-if="loading" class="text-gray-600">Loading...</div>

    <div v-else-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
      {{ error }}
    </div>

    <div
      v-else-if="orders.length === 0"
      class="rounded-lg bg-gray-50 p-8 text-center text-gray-600"
    >
      Nothing to review.
    </div>

    <div v-else class="overflow-hidden rounded-lg border border-gray-200 bg-white">
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Reference
            </th>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Status
            </th>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Amount
            </th>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Gateway
            </th>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Submitted
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-200 bg-white">
          <tr
            v-for="order in orders"
            :key="order.id"
            class="cursor-pointer hover:bg-gray-50"
            @click="viewOrder(order.id)"
          >
            <td class="px-6 py-4 text-sm font-medium text-gray-900">
              {{ order.reference_code || '-' }}
            </td>
            <td class="px-6 py-4 text-sm text-gray-500">
              <OrderStatusBadge :status="order.status" />
            </td>
            <td class="px-6 py-4 text-sm text-gray-500">৳{{ formatAmount(order.amount_minor) }}</td>
            <td class="px-6 py-4 text-sm text-gray-500">
              {{ order.gateway?.name_en || '-' }}
            </td>
            <td class="px-6 py-4 text-sm text-gray-500">
              {{ formatDate(order.created_at) }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'

const router = useRouter()
const supabase = getSupabase()

const orders = ref<any[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const formatAmount = (amt: number): string => {
  return (amt / 100).toFixed(2)
}

const formatDate = (date: string): string => {
  return new Date(date).toLocaleString()
}

const viewOrder = (orderId: string): void => {
  router.push(`/admin/orders/${orderId}`)
}

onMounted(async () => {
  try {
    const { data, error: rpcError } = await (supabase.rpc as any)('admin_orders')

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    orders.value = data || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load orders'
  } finally {
    loading.value = false
  }
})
</script>

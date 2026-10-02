<template>
  <div>
    <router-link to="/admin/queue" class="mb-4 inline-block text-blue-600 hover:underline">
      ← Back to queue
    </router-link>

    <div v-if="loading" class="text-gray-600">Loading...</div>

    <div v-else-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
      {{ error }}
    </div>

    <div v-else-if="order">
      <div class="mb-6 flex items-center justify-between">
        <h1 class="text-2xl font-bold text-gray-900">Order {{ order.reference_code }}</h1>
        <OrderStatusBadge :status="order.status" />
      </div>

      <div class="mb-6 grid gap-6 md:grid-cols-2">
        <div class="rounded-lg border border-gray-200 bg-white p-6">
          <h2 class="mb-4 text-lg font-semibold">Order Details</h2>
          <dl class="space-y-2">
            <div>
              <dt class="text-sm font-medium text-gray-500">Amount</dt>
              <dd class="text-sm text-gray-900">৳{{ formatAmount(order.amount_minor) }}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Gateway</dt>
              <dd class="text-sm text-gray-900">{{ order.gateway?.name_en || '-' }}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Customer Phone</dt>
              <dd class="text-sm text-gray-900">{{ order.phone_e164 || '-' }}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Created</dt>
              <dd class="text-sm text-gray-900">{{ formatDate(order.created_at) }}</dd>
            </div>
          </dl>
        </div>

        <div v-if="duplicates.length > 0" class="rounded-lg border border-red-200 bg-red-50 p-6">
          <h2 class="mb-2 text-lg font-semibold text-red-800">Duplicate TrxID</h2>
          <p class="mb-2 text-sm text-red-700">This transaction ID appears on other orders.</p>
          <ul class="space-y-1">
            <li v-for="dup in duplicates" :key="dup.id" class="text-sm text-red-700">
              Order {{ dup.reference_code }} ({{ dup.status }})
            </li>
          </ul>
        </div>
      </div>

      <div
        v-if="order.evidence && Object.keys(order.evidence).length > 0"
        class="mb-6 rounded-lg border border-gray-200 bg-white p-6"
      >
        <h2 class="mb-4 text-lg font-semibold">Evidence</h2>
        <div class="space-y-4">
          <div v-for="(ev, key) in order.evidence" :key="key">
            <dt class="text-sm font-medium text-gray-500">{{ key }}</dt>
            <dd class="mt-1 text-sm text-gray-900">
              <span v-if="ev.storage_path">File uploaded</span>
              <span v-else>{{ ev.value }}</span>
            </dd>
          </div>
        </div>
      </div>

      <div v-if="canReview" class="flex space-x-3">
        <button
          @click="approve"
          :disabled="actionLoading"
          class="rounded-md bg-green-600 px-4 py-2 text-white hover:bg-green-700 disabled:bg-gray-400"
        >
          Approve
        </button>
        <button
          @click="showRejectModal = true"
          :disabled="actionLoading"
          class="rounded-md bg-red-600 px-4 py-2 text-white hover:bg-red-700 disabled:bg-gray-400"
        >
          Reject
        </button>
        <button
          @click="resetProbes"
          :disabled="actionLoading"
          class="rounded-md bg-gray-600 px-4 py-2 text-white hover:bg-gray-700 disabled:bg-gray-400"
        >
          Reset Probes
        </button>
      </div>

      <div v-if="actionError" class="mt-4 rounded-lg bg-red-50 p-4 text-red-800">
        {{ actionError }}
      </div>
    </div>

    <div
      v-if="showRejectModal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black bg-opacity-50"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-6">
        <h2 class="mb-4 text-lg font-semibold">Reject Order</h2>
        <div class="mb-4">
          <label for="reason" class="block text-sm font-medium text-gray-700"
            >Rejection Reason</label
          >
          <textarea
            id="reason"
            v-model="rejectReason"
            rows="3"
            required
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>
        <div class="flex justify-end space-x-3">
          <button
            @click="showRejectModal = false"
            class="rounded-md border border-gray-300 px-4 py-2 hover:bg-gray-50"
          >
            Cancel
          </button>
          <button
            @click="reject"
            :disabled="actionLoading || !rejectReason.trim()"
            class="rounded-md bg-red-600 px-4 py-2 text-white hover:bg-red-700 disabled:bg-gray-400"
          >
            Reject
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import { useStaffRole } from '@/composables/useStaffRole'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'

const route = useRoute()
const supabase = getSupabase()
const { isStaff } = useStaffRole()

const orderId = computed(() => route.params.id as string)

const order = ref<any>(null)
const duplicates = ref<any[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const actionLoading = ref(false)
const actionError = ref<string | null>(null)
const showRejectModal = ref(false)
const rejectReason = ref('')

const canReview = computed(() => isStaff.value)

const formatAmount = (amt: number): string => {
  return (amt / 100).toFixed(2)
}

const formatDate = (date: string): string => {
  return new Date(date).toLocaleString()
}

const loadOrder = async (): Promise<void> => {
  try {
    const { data, error: rpcError } = await (supabase.rpc as any)('admin_order_detail', {
      p_order_id: orderId.value,
    })

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    order.value = data

    const { data: dupData } = await (supabase.rpc as any)('admin_order_duplicate_trxids', {
      p_order_id: orderId.value,
    })
    duplicates.value = dupData || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load order'
  } finally {
    loading.value = false
  }
}

const approve = async (): Promise<void> => {
  actionError.value = null
  actionLoading.value = true
  try {
    const { error: rpcError } = await (supabase.rpc as any)('approve_order', {
      p_order_id: orderId.value,
    })
    if (rpcError) {
      actionError.value = rpcError.message
      return
    }
    await loadOrder()
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : 'Failed to approve'
  } finally {
    actionLoading.value = false
  }
}

const reject = async (): Promise<void> => {
  actionError.value = null
  actionLoading.value = true
  try {
    const { error: rpcError } = await (supabase.rpc as any)('reject_order', {
      p_order_id: orderId.value,
      p_reason: rejectReason.value.trim(),
    })
    if (rpcError) {
      actionError.value = rpcError.message
      return
    }
    showRejectModal.value = false
    rejectReason.value = ''
    await loadOrder()
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : 'Failed to reject'
  } finally {
    actionLoading.value = false
  }
}

const resetProbes = async (): Promise<void> => {
  actionError.value = null
  actionLoading.value = true
  try {
    const { error: rpcError } = await (supabase.rpc as any)('admin_reset_probes', {
      p_order_id: orderId.value,
    })
    if (rpcError) {
      actionError.value = rpcError.message
      return
    }
    await loadOrder()
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : 'Failed to reset probes'
  } finally {
    actionLoading.value = false
  }
}

onMounted(async () => {
  await loadOrder()
})
</script>

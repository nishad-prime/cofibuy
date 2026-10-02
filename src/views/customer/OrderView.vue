<template>
  <div class="mx-auto max-w-2xl px-4 py-8">
    <router-link :to="`/${slug}`" class="mb-4 inline-block text-blue-600 hover:underline">
      ← Back to link
    </router-link>

    <div v-if="loading && !order" class="py-8 text-center text-gray-600">Loading...</div>

    <div v-else-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
      {{ error }}
    </div>

    <div v-else>
      <div class="mb-6 flex items-center justify-between">
        <h1 class="text-2xl font-bold text-gray-900">Order Status</h1>
        <OrderStatusBadge :status="currentStatus || 'draft'" :is-polling="isPolling" />
      </div>

      <div v-if="order" class="mb-6 rounded-lg border border-gray-200 bg-gray-50 p-4">
        <div v-if="(order as any).reference_code" class="mb-2">
          <span class="font-semibold">Reference Code:</span> {{ (order as any).reference_code }}
        </div>
        <div
          v-if="(order as any).reject_reason && currentStatus === 'rejected'"
          class="text-red-800"
        >
          <span class="font-semibold">Rejection Reason:</span> {{ (order as any).reject_reason }}
        </div>
      </div>

      <div v-if="currentStatus === 'awaiting_proof'" class="mb-6">
        <h2 class="mb-4 text-xl font-semibold">Submit Evidence</h2>
        <EvidenceForm
          :evidence-fields="evidenceFields"
          :submitting="submitting"
          @submit="submitEvidence"
        />
      </div>

      <div v-if="currentStatus === 'approved' && unlockedContent" class="mb-6">
        <h2 class="mb-4 text-xl font-semibold">Unlocked Content</h2>
        <div class="prose max-w-none">
          <MarkdownBody :content="unlockedContent" />
        </div>
      </div>

      <div
        v-if="
          currentStatus === 'rejected' || currentStatus === 'expired' || currentStatus === 'locked'
        "
        class="mb-6 rounded-lg bg-yellow-50 p-4 text-yellow-800"
      >
        <p v-if="currentStatus === 'rejected'">
          Your order was rejected. You can try again with new evidence.
        </p>
        <p v-if="currentStatus === 'expired'">Your order has expired. Please create a new order.</p>
        <p v-if="currentStatus === 'locked'">
          Your order is locked. Please try again later or create a new order.
        </p>
        <router-link :to="`/${slug}`" class="mt-2 inline-block text-blue-600 hover:underline">
          Create new order →
        </router-link>
      </div>

      <div
        v-if="currentStatus === 'under_review'"
        class="mb-6 rounded-lg bg-blue-50 p-4 text-blue-800"
      >
        Your evidence is under review. We'll update the status automatically.
      </div>
    </div>

    <LanguageToggle class="mt-8" />
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import { useOrderPolling } from '@/composables/useOrderPolling'
import { useFileUpload } from '@/composables/useFileUpload'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import EvidenceForm from '@/components/customer/EvidenceForm.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import LanguageToggle from '@/components/LanguageToggle.vue'

const route = useRoute()
const supabase = getSupabase()
const fileUpload = useFileUpload()

const slug = computed(() => route.params.slug as string)
const orderId = computed(() => route.params.orderId as string)

const {
  status: currentStatus,
  order,
  isPolling,
  startPolling,
  refresh,
} = useOrderPolling(orderId.value) as any

const loading = ref(true)
const error = ref<string | null>(null)
const submitting = ref(false)
const evidenceFields = ref<any>([])
const unlockedContent = ref<string | null>(null)

watch(currentStatus, async (newStatus) => {
  if (newStatus === 'approved') {
    await fetchUnlockedContent()
  }
})

const fetchUnlockedContent = async (): Promise<void> => {
  try {
    const { data, error: rpcError } = await (supabase.rpc as any)('get_unlocked_link', {
      p_slug: slug.value,
    })

    if (!rpcError && data) {
      // get_unlocked_link returns unlocked content
      const unlocked = data
      unlockedContent.value = unlocked.body_bn || unlocked.body_en || null
    }
  } catch (err) {
    // Ignore error for unlocked content
  }
}

onMounted(async () => {
  try {
    await refresh()
    startPolling()

    // Fetch order details for evidence fields
    // const { data: orderData } = await supabase
    //   .from('orders')
    //   .select('gateway:evidence_fields, payment_gateways:evidence_fields')
    //   .eq('id', orderId.value)
    //   .maybeSingle()

    // Try to get gateway evidence fields
    const { data: orderFull } = await supabase
      .from('orders')
      .select('gateway_id')
      .eq('id', orderId.value)
      .maybeSingle()

    if (orderFull?.gateway_id) {
      const { data: gw } = await supabase
        .from('payment_gateways')
        .select('evidence_fields')
        .eq('id', orderFull.gateway_id)
        .maybeSingle()
      if (gw?.evidence_fields) {
        evidenceFields.value = gw.evidence_fields
      }
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load order'
  } finally {
    loading.value = false
  }
})

const submitEvidence = async (evidence: Record<string, any>): Promise<void> => {
  submitting.value = true
  try {
    const processedEvidence: Record<string, any> = {}

    for (const [key, value] of Object.entries(evidence)) {
      if (value instanceof File) {
        const result = await fileUpload.upload(value, key, orderId.value)
        processedEvidence[key] = {
          value: value.name,
          storage_path: result.storage_path,
        }
      } else {
        processedEvidence[key] = { value }
      }
    }

    const { error: submitError } = await (supabase.rpc as any)('submit_evidence', {
      p_order_id: orderId.value,
      p_evidence: processedEvidence,
    })

    if (submitError) {
      error.value = submitError.message
      return
    }

    await refresh()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to submit evidence'
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div>
    <router-link
      to="/admin/queue"
      class="mb-6 inline-flex items-center gap-2 text-sm font-medium text-stone-600 hover:text-stone-900"
    >
      <AppIcon name="arrowLeft" :size="16" />
      {{ t('admin.queue.heading') }}
    </router-link>

    <div v-if="loading" class="empty-state">Loading...</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <template v-else-if="order">
      <header class="mb-6 flex flex-wrap items-center justify-between gap-3">
        <h1 class="page-title">
          <span class="ltr-value">{{ order.reference_code || order.id.slice(0, 8) }}</span>
        </h1>
        <OrderStatusBadge :status="order.status" :label="statusLabel(order.status)" />
      </header>

      <div
        v-if="order.has_duplicate_trxid || duplicates.length > 0"
        class="alert-error mb-6"
        role="alert"
      >
        <p class="font-medium">{{ t('admin.queue.duplicate') }}</p>
        <p class="mt-1">{{ t('admin.queue.duplicateHint') }}</p>
        <ul v-if="duplicates.length > 0" class="mt-2 space-y-1">
          <li v-for="dup in duplicates" :key="dup.id" class="ltr-value text-xs">
            {{ dup.reference_code }} · {{ dup.status }}
          </li>
        </ul>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">Order details</h2>
          <dl class="mt-4 space-y-3 text-sm">
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.queue.amount') }}</dt>
              <dd class="text-right">
                <span class="ltr-value font-medium text-stone-900">
                  {{ formatMoney(order.amount ?? 0, 'en', currency) }}
                </span>
                <span
                  v-if="order.amount_received !== null && order.amount_received !== order.amount"
                  class="mt-0.5 block text-xs"
                >
                  <span class="text-stone-500">{{ t('admin.order.received') }}:</span>
                  <span
                    class="ltr-value font-medium"
                    :class="
                      (order.amount_received ?? 0) < (order.amount ?? 0)
                        ? 'text-red-400'
                        : 'text-emerald-400'
                    "
                  >
                    {{ formatMoney(order.amount_received, 'en', currency) }}
                  </span>
                </span>
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.queue.gateway') }}</dt>
              <dd class="font-medium text-stone-900">{{ order.gateway?.name_en || '—' }}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.queue.customerNumber') }}</dt>
              <dd class="ltr-value font-medium text-stone-900">{{ order.phone_e164 || '—' }}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.order.report') }}</dt>
              <dd class="text-right font-medium text-stone-900">
                {{ order.link?.title_en || order.link?.slug || '—' }}
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.queue.submitted') }}</dt>
              <dd class="text-stone-600">
                {{ formatDate(order.submitted_at || order.created_at) }}
              </dd>
            </div>
            <div v-if="displayedRejectReason" class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.queue.rejectReason') }}</dt>
              <dd class="text-right text-red-700">{{ displayedRejectReason }}</dd>
            </div>
          </dl>
        </section>

        <section class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">Evidence</h2>

          <p v-if="evidenceRows.length === 0" class="empty-state !py-8">
            {{ t('admin.queue.noScreenshot') }}
          </p>

          <ul v-else class="mt-4 space-y-4 text-sm">
            <li v-for="ev in evidenceRows" :key="`${ev.field_key}-${ev.attempt}`" class="space-y-2">
              <div class="flex justify-between gap-4">
                <span class="text-stone-500">
                  {{ ev.field_key }}
                  <span
                    v-if="evidenceRows.filter((r) => r.field_key === ev.field_key).length > 1"
                    class="ml-1 rounded-full bg-stone-100 px-1.5 py-0.5 text-xs text-stone-500"
                  >
                    #{{ ev.attempt }}
                  </span>
                </span>
                <span class="text-right font-medium text-stone-900">
                  <span v-if="ev.file_path && !evidenceUrl(ev)" class="badge-ok">
                    {{ t('admin.queue.screenshot') }}
                  </span>
                  <span v-else>{{ ev.value_text_raw ?? '—' }}</span>
                </span>
              </div>
              <!-- The actual screenshot, one click from full size. -->
              <a
                v-if="ev.file_path && evidenceUrl(ev)"
                :href="evidenceUrl(ev)!"
                target="_blank"
                rel="noopener noreferrer"
                class="block"
              >
                <img
                  :src="evidenceUrl(ev)!"
                  :alt="ev.field_key"
                  class="max-h-80 rounded-lg border border-stone-200 object-contain transition hover:border-brand-400"
                  loading="lazy"
                />
              </a>
            </li>
          </ul>
        </section>

        <!--
          The customer behind the order: their identity and their shop-wide
          footprint, so approve and reject decisions see the pattern, not just
          this one attempt.
        -->
        <section v-if="order.customer" class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.order.customer') }}</h2>
          <dl class="mt-4 space-y-3 text-sm">
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.order.customer') }}</dt>
              <dd class="text-right font-medium text-stone-900">
                {{ customerLabel || t('admin.order.none') }}
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.order.customerSince') }}</dt>
              <dd class="text-stone-900">
                {{ order.customer.created_at ? formatDate(order.customer.created_at) : '—' }}
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.order.ordersApproved') }}</dt>
              <dd class="ltr-value text-stone-900">
                {{ order.customer.orders_total }} ({{ order.customer.orders_approved }})
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.order.approvedRevenue') }}</dt>
              <dd class="ltr-value font-medium text-stone-900">
                {{ formatMoney(order.customer.revenue_approved, 'en', currency) }}
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.order.location') }}</dt>
              <dd class="text-right font-medium text-stone-900">
                <template v-if="order.country || order.city">
                  <span v-if="order.city">{{ order.city }}, </span>
                  <span class="ltr-value">{{ order.country }}</span>
                </template>
                <span v-else class="text-stone-400">{{ t('admin.order.none') }}</span>
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.order.device') }}</dt>
              <dd class="text-right font-medium text-stone-900">
                <template v-if="order.device_type || order.os || order.browser">
                  <span>{{ t(`admin.dashboard.device.${order.device_type || 'desktop'}`) }}</span>
                  <span v-if="order.os" class="text-stone-500"> · {{ order.os }}</span>
                  <span v-if="order.browser" class="text-stone-500"> · {{ order.browser }}</span>
                </template>
                <span v-else class="text-stone-400">{{ t('admin.order.none') }}</span>
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('admin.order.referrer') }}</dt>
              <dd class="text-right font-medium text-stone-900">
                {{ order.referrer || t('admin.order.none') }}
              </dd>
            </div>
          </dl>
        </section>
      </div>

      <div v-if="canReview" class="mt-6 flex flex-wrap gap-3">
        <button
          type="button"
          class="btn-primary"
          :disabled="actionLoading"
          @click="openApproveModal"
        >
          <AppIcon name="check" :size="18" />
          {{ t('admin.queue.approve') }}
        </button>
        <button
          type="button"
          class="btn-secondary text-red-700"
          :disabled="actionLoading"
          @click="showRejectModal = true"
        >
          {{ t('admin.queue.reject') }}
        </button>
      </div>

      <div v-if="canResetProbes" class="mt-6 flex flex-wrap gap-3">
        <button type="button" class="btn-secondary" :disabled="actionLoading" @click="resetProbes">
          {{ t('admin.queue.resetProbes') }}
        </button>
      </div>

      <p v-if="!canReview && !canResetProbes && stateHint" class="hint mt-6" role="status">
        {{ stateHint }}
      </p>

      <p v-if="actionError" class="alert-error mt-4" role="alert">{{ actionError }}</p>

      <div
        v-if="showRejectModal"
        class="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4"
      >
        <div class="w-full max-w-md rounded-xl border border-white/15 bg-stone-950 p-5 shadow-2xl">
          <h2 class="text-lg font-semibold text-stone-100">{{ t('admin.queue.reject') }}</h2>
          <div class="mt-4">
            <label class="label" for="reason">{{ t('admin.queue.rejectReason') }}</label>
            <textarea
              id="reason"
              v-model="rejectReason"
              rows="3"
              class="field"
              :placeholder="t('admin.queue.rejectReasonPlaceholder')"
            />
            <p class="hint">{{ t('admin.queue.rejectReasonRequired') }}</p>
          </div>
          <div class="mt-6 flex justify-end gap-3">
            <button type="button" class="btn-secondary" @click="showRejectModal = false">
              {{ t('admin.common.close') }}
            </button>
            <button
              type="button"
              class="btn-danger"
              :disabled="actionLoading || !rejectReason.trim()"
              @click="reject"
            >
              {{ actionLoading ? t('admin.queue.rejecting') : t('admin.queue.reject') }}
            </button>
          </div>
        </div>
      </div>

      <!--
        Approve: the operator records what actually arrived, because a
        customer who under-pays is still a customer - just at a different
        figure. Prefilled with the requested amount.
      -->
      <div
        v-if="showApproveModal"
        class="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4"
      >
        <div class="w-full max-w-md rounded-xl border border-white/15 bg-stone-950 p-5 shadow-2xl">
          <h2 class="text-lg font-semibold text-stone-100">
            {{ t('admin.order.approveHeading') }}
          </h2>
          <div class="mt-4">
            <label class="label" for="received">{{ t('admin.order.received') }} (৳)</label>
            <input
              id="received"
              v-model="receivedInput"
              type="number"
              min="0"
              step="0.01"
              class="field ltr-value"
            />
            <p class="hint">{{ t('admin.order.approveHint') }}</p>
          </div>
          <div class="mt-6 flex justify-end gap-3">
            <button
              type="button"
              class="btn-secondary"
              :disabled="actionLoading"
              @click="showApproveModal = false"
            >
              {{ t('admin.common.cancel') }}
            </button>
            <button
              type="button"
              class="btn-primary"
              :disabled="actionLoading || !receivedInput"
              @click="approve"
            >
              {{ actionLoading ? t('admin.order.approving') : t('admin.queue.approve') }}
            </button>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import { formatMoney } from '@/lib/money'
import { useAdminCurrency } from '@/composables/useAdminCurrency'
import { useStaffRole } from '@/composables/useStaffRole'
import { useAdminI18n } from '@/i18n/admin'
import AppIcon from '@/components/AppIcon.vue'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import { rpc } from '@/lib/rpc'
import { getSupabase } from '@/lib/supabase'

const route = useRoute()
const { isStaff } = useStaffRole()
const { t } = useAdminI18n()
const { currency, load: loadCurrency } = useAdminCurrency()

const orderId = computed(() => route.params.id as string)

interface AdminOrderRow {
  id: string
  status: string
  amount: number | null
  reference_code: string | null
  created_at: string
  submitted_at: string | null
  phone_e: string | null
  phone_e164: string | null
  has_duplicate_trxid: boolean | null
  reject_reason_en: string | null
  reject_reason_bn: string | null
  gateway: { name_en: string | null; name_bn: string | null } | null
  customer: {
    id: string
    email: string | null
    created_at: string | null
    orders_total: number
    orders_approved: number
    revenue_approved: number
  } | null
  country: string | null
  city: string | null
  device_type: string | null
  os: string | null
  browser: string | null
  referrer: string | null
  amount_received: number | null
  // `link` is the jsonb field name `admin_order_detail` returns (the orders
  // table still calls its FK link_id); renaming it means SQL churn for zero
  // visible effect, so the view maps it as-is.
  link: { slug: string; title_en: string | null; title_bn: string | null } | null
  evidence: Record<string, unknown>[]
  duplicates: Record<string, unknown>[]
}

const order = ref<AdminOrderRow | null>(null)
const loading = ref(true)
const error = ref<string | null>(null)
const actionLoading = ref(false)
const actionError = ref<string | null>(null)
const showRejectModal = ref(false)
const showApproveModal = ref(false)
const receivedInput = ref('')
const rejectReason = ref('')

/**
 * The actions follow the order's state, because the RPCs refuse anything else:
 * approve and reject move an order out of `under_review` and nowhere else, and
 * the probe reset matters only while a customer can still act on the order.
 * A staff badge alone used to render all three buttons on every order -
 * approved, expired, draft - and every press was a database error.
 */
const canReview = computed(() => isStaff.value && order.value?.status === 'under_review')

const canResetProbes = computed(
  () => isStaff.value && ['draft', 'awaiting_proof', 'locked'].includes(order.value?.status ?? ''),
)

/**
 * When the action area is empty, say why. An operator landing on an approved
 * order used to find nothing where buttons usually sit - a state worth a
 * sentence, not a hole in the page.
 */
const stateHint = computed(() => {
  if (!order.value || canReview.value) return null
  switch (order.value.status) {
    case 'awaiting_proof':
      return t('admin.queue.hintAwaitingProof')
    case 'approved':
      return t('admin.queue.hintApproved')
    case 'expired':
      return t('admin.queue.hintExpired')
    case 'locked':
      return t('admin.queue.hintLocked')
    default:
      return null
  }
})
/**
 * `admin_order_detail` returns `amount` in whole taka, not `amount_minor`.
 *
 * The panel is an operator tool and the figure gets reconciled against a bank
 * statement, so it stays Latin whatever the customer-facing locale is doing.
 */
const statusLabel = (status: string): string => t(`admin.status.${status}`)

/**
 * `admin_order_detail` returns evidence as an array of rows (one per field per
 * attempt), not a keyed object, and embeds `duplicates` alongside it.
 */
interface EvidenceRow {
  id: string
  field_key: string
  attempt: number
  file_path: string | null
  value_text_raw: string | null
}

interface DuplicateRow {
  id: string
  reference_code: string | null
  status: string
}

const evidenceRows = computed<EvidenceRow[]>(
  () => (order.value?.evidence ?? []) as unknown as EvidenceRow[],
)

/**
 * The proofs bucket is private, so the screenshots cannot be linked directly.
 * Each file path is exchanged for a one-hour signed URL after the order
 * loads, and the evidence list renders the actual image. A row whose URL
 * cannot be minted falls back to the file badge.
 */
const evidenceUrls = ref<Record<string, string>>({})

const loadEvidenceUrls = async (): Promise<void> => {
  evidenceUrls.value = {}
  const paths = evidenceRows.value
    .map((row) => row.file_path)
    .filter((path): path is string => !!path)

  await Promise.all(
    paths.map(async (path) => {
      const { data, error } = await getSupabase().storage.from('proofs').createSignedUrl(path, 3600)
      if (!error && data?.signedUrl) {
        evidenceUrls.value[path] = data.signedUrl
      }
    }),
  )
}

const evidenceUrl = (row: EvidenceRow): string | null =>
  row.file_path ? (evidenceUrls.value[row.file_path] ?? null) : null
const duplicates = computed<DuplicateRow[]>(
  () => (order.value?.duplicates ?? []) as unknown as DuplicateRow[],
)

// The RPC stores the reason per language; the panel is English-only.
const displayedRejectReason = computed(
  () => order.value?.reject_reason_en || order.value?.reject_reason_bn || '',
)

const formatDate = (date: string): string => {
  return date ? new Date(date).toLocaleString() : '—'
}

/**
 * Anonymous signups have no email; the short id is the only handle they
 * offer, and it is what the auth admin would search by anyway.
 */
const customerLabel = computed(() => {
  const customer = order.value?.customer
  if (!customer) return null
  // Anonymous signups carry no email; the short id is the handle the auth
  // admin would search by.
  return customer.email || `Anonymous · ${customer.id.slice(0, 8)}`
})

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const loadOrder = async (): Promise<void> => {
  // The route param is whatever the URL carried; the RPC takes a uuid. A
  // malformed id is refused here with a plain sentence instead of letting
  // Postgres answer with an operator error.
  if (!UUID_RE.test(orderId.value)) {
    error.value = 'Order not found.'
    loading.value = false
    return
  }
  try {
    const { data, error: rpcError } = await rpc<Record<string, unknown>>('admin_order_detail', {
      p_order_id: orderId.value,
    })

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    order.value = data as unknown as AdminOrderRow
    void loadEvidenceUrls()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load order'
  } finally {
    loading.value = false
  }
}

const openApproveModal = (): void => {
  receivedInput.value = order.value?.amount != null ? String(order.value.amount) : ''
  showApproveModal.value = true
}

const approve = async (): Promise<void> => {
  actionError.value = null
  actionLoading.value = true
  if (!UUID_RE.test(orderId.value)) {
    actionError.value = 'Order not found.'
    actionLoading.value = false
    return
  }
  const received = Number(receivedInput.value)
  try {
    const { error: rpcError } = await rpc<Record<string, unknown>>('approve_order', {
      p_order_id: orderId.value,
      p_amount_received: Number.isFinite(received) && received > 0 ? received : null,
    })
    if (rpcError) {
      actionError.value = rpcError.message
      return
    }
    showApproveModal.value = false
    // Fire-and-forget: the telegram bot's cron is the safety net if this
    // fails, but the customer sees the invite faster when it lands.
    void getSupabase()
      .functions.invoke('telegram-request-invite', { body: { orderId: orderId.value } })
      .then(({ error: fnError }) => {
        if (fnError) console.warn('[telegram-invite]', fnError)
      })
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
    const { error: rpcError } = await rpc<Record<string, unknown>>('reject_order', {
      p_order_id: orderId.value,
      p_reason: rejectReason.value.trim(),
    })
    if (rpcError) {
      actionError.value = rpcError.message
      return
    }
    showRejectModal.value = false
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
    const { error: rpcError } = await rpc<Record<string, unknown>>('admin_reset_probes', {
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
  void loadCurrency()
  await loadOrder()
})
</script>

<template>
  <main class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
    <router-link
      :to="`/${slug}`"
      class="mb-6 inline-flex items-center gap-2 text-sm font-medium text-stone-600 hover:text-stone-900"
    >
      <AppIcon name="arrowLeft" :size="16" />
      {{ t('customer.common.back') }}
    </router-link>

    <div v-if="loading && !order" class="empty-state">{{ t('customer.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <template v-else>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h1 class="page-title">{{ t('customer.order.title') }}</h1>
        <OrderStatusBadge
          :status="currentStatus || 'draft'"
          :label="statusLabel"
          :is-polling="isPolling"
        />
      </div>

      <div
        v-if="order && (order as any).reference_code"
        class="card card-pad mt-6 flex flex-wrap items-center justify-between gap-3"
      >
        <div>
          <p class="label !mb-1">{{ t('customer.order.reference') }}</p>
          <p class="ltr-value text-lg font-semibold text-stone-900">
            {{ (order as any).reference_code }}
          </p>
        </div>
        <button type="button" class="btn-secondary" @click="copyReference">
          <AppIcon :name="copied ? 'check' : 'copy'" :size="16" />
          {{ copied ? t('customer.common.copied') : t('customer.common.copy') }}
        </button>
      </div>

      <!--
          The online method has one button and no fields. The customer leaves this page for
          bKash and comes back to a different route, so nothing here has to survive the
          round trip except the order itself.
        -->
      <section
        v-if="currentStatus === 'awaiting_proof' && isOnlineGateway"
        class="card card-pad mt-6 border-brand-200 bg-brand-50"
      >
        <h2 class="flex items-center gap-2 text-sm font-semibold text-brand-900">
          <AppIcon name="wallet" :size="18" />
          {{ t('customer.order.payOnline') }}
        </h2>

        <p v-if="isSandboxGateway" class="mt-2 text-sm text-brand-900/80">
          {{ t('customer.order.payOnlineSandbox') }}
        </p>

        <button type="button" class="btn-primary mt-4" :disabled="paying" @click="payOnline">
          <AppIcon v-if="!paying" name="wallet" :size="16" />
          {{ paying ? t('customer.order.payOnlinePending') : t('customer.order.payOnline') }}
        </button>
      </section>

      <!--
          The payment reminder stays visible until the order leaves
          awaiting_proof, because the customer usually has to leave this page to
          pay and then come back.

          Manual methods only. An automated one has no account to send money to and no
          evidence for a customer to upload, so this section would be an empty form under a
          heading that promises something will be submitted.
        -->
      <section
        v-if="currentStatus === 'awaiting_proof' && gateway && !isOnlineGateway"
        class="card card-pad mt-6 border-brand-200 bg-brand-50"
      >
        <h2 class="flex items-center gap-2 text-sm font-semibold text-brand-900">
          <AppIcon name="clock" :size="18" />
          {{ t('customer.order.reminder') }}
        </h2>
        <CopyText copy-key="order.reminderBody" tag="p" class="mt-2 text-sm text-brand-900/80" />

        <div class="mt-4 grid gap-4 sm:grid-cols-2">
          <div>
            <p class="label">{{ t('customer.paywall.sendTo') }}</p>
            <GatewayAccountDetails
              class="rounded-lg bg-white px-3 py-2.5"
              :fields="gateway.account_fields"
              :legacy-number="gateway.account_number"
              :legacy-name="gateway.account_name"
            />
            <p v-if="!hasDetails" class="hint">{{ t('customer.paywall.noDetails') }}</p>
          </div>
        </div>

        <div v-if="gatewayInstructions" class="mt-4 border-t border-brand-200 pt-3">
          <MarkdownBody :source="gatewayInstructions" />
        </div>
      </section>

      <section
        v-if="currentStatus === 'awaiting_proof' && !isOnlineGateway"
        class="card card-pad mt-6"
      >
        <h2 class="text-lg font-semibold text-stone-900">
          {{ t('customer.order.submitEvidence') }}
        </h2>
        <CopyText copy-key="order.evidenceHint" tag="p" class="hint mb-5" />
        <EvidenceForm
          :evidence-fields="evidenceFields"
          :submitting="submitting"
          @submit="submitEvidence"
        />
      </section>

      <section v-if="currentStatus === 'approved' && unlockedContent" class="card card-pad mt-6">
        <h2 class="text-lg font-semibold text-stone-900">{{ t('customer.order.unlocked') }}</h2>
        <MarkdownBody :source="unlockedContent" class="mt-2" />
      </section>

      <section v-if="currentStatus === 'under_review'" class="alert-info mt-6">
        {{ t('customer.order.underReview') }}
      </section>

      <section
        v-if="
          currentStatus === 'rejected' || currentStatus === 'expired' || currentStatus === 'locked'
        "
        class="card card-pad mt-6"
      >
        <p class="text-sm text-stone-700">
          <template v-if="currentStatus === 'rejected'">{{
            t('customer.order.rejected')
          }}</template>
          <template v-else-if="currentStatus === 'expired'">{{
            t('customer.order.expired')
          }}</template>
          <template v-else>{{ t('customer.order.locked') }}</template>
        </p>
        <p v-if="currentStatus === 'rejected' && rejectReason" class="mt-2 text-sm text-red-700">
          <span class="font-medium">{{ t('customer.order.rejectReason') }}:</span>
          {{ rejectReason }}
        </p>
        <router-link :to="`/${slug}`" class="btn-primary mt-4">
          {{ t('customer.order.newOrder') }}
        </router-link>
      </section>
    </template>
  </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { getSupabase } from '@/lib/supabase'
import { useContent } from '@/composables/useContent'
import { useOrderPolling } from '@/composables/useOrderPolling'
import { useFileUpload } from '@/composables/useFileUpload'
import AppIcon from '@/components/AppIcon.vue'
import CopyText from '@/components/CopyText.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import EvidenceForm, { type EvidenceField } from '@/components/customer/EvidenceForm.vue'
import GatewayAccountDetails, {
  type AccountField,
} from '@/components/customer/GatewayAccountDetails.vue'
import { buildEvidencePayload } from '@/lib/evidencePayload'
import { describeEdgeFailure } from '@/lib/edgeError'

const route = useRoute()
const supabase = getSupabase()
const fileUpload = useFileUpload()
const { pick } = useContent()
const { t } = useI18n()

const slug = computed(() => route.params.slug as string)
const orderId = computed(() => route.params.orderId as string)

interface OrderGateway {
  id: string
  kind: string
  provider: string | null
  environment: string | null
  name_en: string | null
  name_bn: string | null
  account_fields: AccountField[] | null
  account_number: string | null
  account_name: string | null
  instructions_md_en: string | null
  instructions_md_bn: string | null
  reference_prompt_en: string | null
  reference_prompt_bn: string | null
  supports_reference: boolean
  evidence_fields: EvidenceField[] | null
}

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
const paying = ref(false)
const copied = ref(false)
const evidenceFields = ref<EvidenceField[]>([])
const gateway = ref<OrderGateway | null>(null)
const unlockedContent = ref<string | null>(null)

const gatewayInstructions = computed(() =>
  gateway.value
    ? pick({ bn: gateway.value.instructions_md_bn, en: gateway.value.instructions_md_en } as any)
    : '',
)

/**
 * Whether bKash takes the payment itself.
 *
 * Keyed on `provider` rather than on the method kind. A kind is what the customer picked
 * and what routing groups by; the provider is what says there is a server-side API behind
 * it. They happen to line up today, and the day a second provider shares a kind the two
 * stop being the same question.
 */
const isOnlineGateway = computed(() => gateway.value?.provider === 'bkash_pgw')

/**
 * Whether this method is a test one.
 *
 * Only ever true for a gateway an owner configured as a sandbox, so it is used to label the
 * button and to explain afterwards that no money moved. It is deliberately not used to hide
 * the payment option: a sandbox method is how the integration gets tested, and the whole
 * value of running one is that a person can click it.
 */
const isSandboxGateway = computed(() => gateway.value?.environment === 'sandbox')

/** Whether this method has anywhere to send money. Automated ones do not. */
const hasDetails = computed(() => {
  const g = gateway.value
  if (!g) return false
  if ((g.account_fields ?? []).some((field) => field.value?.trim())) return true
  return !!(g.account_number?.trim() || g.account_name?.trim())
})

// The order RPC returns the reason per language and never a bare
// `reject_reason`, so fall back to English when the Bangla one was not set.
const rejectReason = computed(
  () => order.value?.reject_reason_bn || order.value?.reject_reason_en || '',
)

const statusLabel = computed(() => t(`customer.order.status.${currentStatus.value || 'draft'}`))

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
      // `get_unlocked_link` names the fields `unlock_body_md_*`, and resolves them
      // per locale rather than always preferring Bangla.
      unlockedContent.value = pick({
        bn: data.unlock_body_md_bn,
        en: data.unlock_body_md_en,
      } as any)
    }
  } catch {
    // The status is already correct; a missing body is not worth an error banner.
  }
}

const copyReference = async (): Promise<void> => {
  const code = (order.value as any)?.reference_code
  if (!code) return
  try {
    await navigator.clipboard.writeText(code)
    copied.value = true
    setTimeout(() => (copied.value = false), 1500)
  } catch {
    // Clipboard access can be refused; the code is still visible to read.
  }
}

/**
 * Starts the payment and hands the customer to bKash.
 *
 * The window is left to bKash rather than being opened here. A popup the payment provider
 * opened itself survives the customer switching to their banking app and back, which a
 * popup we opened tends not to; and a full-page redirect leaves nothing to go stale if the
 * customer walks away from it.
 */
const payOnline = async (): Promise<void> => {
  if (!isOnlineGateway.value) return
  paying.value = true
  error.value = null

  try {
    const { data, error: payError } = await supabase.functions.invoke('bkash-create-payment', {
      body: { orderId: orderId.value },
    })

    if (payError || data?.error) {
      // The function's own message. `gateway_not_configured` in particular is the operator
      // reading this page, not the customer, and hiding it behind a generic failure would
      // cost them an hour of wondering why the button does nothing.
      //
      // `describeEdgeFailure` rather than `payError.message`, because for a request that
      // never reached the function that message is the SDK's generic
      // `Failed to send a request to the Edge Function` - true, but identical whether the
      // customer is offline, behind a VPN, or being blocked, so it tells nobody anything.
      const failure = await describeEdgeFailure(
        payError ?? data,
        t('customer.checkout.payOnlineFailed'),
      )
      if (failure.cause !== '') console.warn('[bkash-create-payment]', failure)
      error.value = failure.message
      return
    }

    if (typeof data?.redirectUrl === 'string' && data.redirectUrl !== '') {
      window.location.assign(data.redirectUrl)
    }
  } catch (err) {
    const failure = await describeEdgeFailure(err, t('customer.checkout.payOnlineFailed'))
    if (failure.cause !== '') console.warn('[bkash-create-payment]', failure)
    error.value = failure.message
  } finally {
    paying.value = false
  }
}

onMounted(async () => {
  try {
    await refresh()
    startPolling()

    // The gateway instructions and evidence schema come from the same RPC.
    // Reading `orders` and `payment_gateways` directly cannot work: neither
    // table is selectable by a customer, so the evidence form came up empty.
    const { data: status } = await (supabase.rpc as any)('my_order_status', {
      p_order_id: orderId.value,
    })

    if (status?.gateway) {
      gateway.value = status.gateway as OrderGateway
      evidenceFields.value = gateway.value.evidence_fields ?? []
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load order'
  } finally {
    loading.value = false
  }
})

/**
 * The form hands back one value per field, and a File for the image ones.
 *
 * The split into two flat maps is `buildEvidencePayload`'s job, and it is tested
 * there: the previous inline version nested each value as `{ value, storage_path }`,
 * which `->>` reads as null, so evidence submission failed on every manual order.
 */
const submitEvidence = async (evidence: Record<string, unknown>): Promise<void> => {
  submitting.value = true
  error.value = null

  try {
    const payload = await buildEvidencePayload(evidence, fileUpload.upload, orderId.value)

    const { error: submitError } = await supabase.rpc('submit_evidence', {
      p_order_id: orderId.value,
      ...payload,
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

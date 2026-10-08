<template>
  <main class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
    <!-- A hidden page is standalone: it is sold by its URL alone, so it shows
         no way back to the index, from the page or the layout header. -->
    <router-link
      v-if="!isStandalone"
      to="/"
      class="mb-6 inline-flex items-center gap-2 text-sm font-medium text-stone-600 hover:text-stone-900"
    >
      <AppIcon name="arrowLeft" :size="16" />
      {{ t('customer.paywall.back') }}
    </router-link>

    <div v-if="loading" class="empty-state">{{ t('customer.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <!-- `get_public_page` returns no row for an unknown or inactive slug, so
           without this branch the page rendered blank. -->
    <div v-else-if="!page" class="card card-pad text-center">
      <AppIcon name="link" :size="28" class="mx-auto mb-3 text-stone-400" />
      <h1 class="text-xl font-semibold text-stone-900">{{ t('customer.notFound.title') }}</h1>
      <MarkdownBody :source="t('customer.notFound.body')" class="mt-2 text-sm text-stone-600" />
      <router-link to="/" class="btn-primary mt-6">{{ t('customer.notFound.cta') }}</router-link>
    </div>

    <template v-else>
      <!-- The template owns everything above the purchase form; the form
           itself is handed over as a slot, because every template ends in the
           same place: one way to pay, and the amount the customer chose. -->
      <component :is="template.renderer" :page="renderPage" :config="templateConfig">
        <template #purchase>
          <!--
        Maintenance replaces the whole form rather than disabling it. A greyed-out
        button still invites the customer to type a phone number, and
        `create_order` would then refuse the order they just filled in -- so the form
        is taken away rather than made inert.
      -->
          <div v-if="maintenance" class="card card-pad mt-8" role="status">
            <div class="flex items-start gap-3">
              <AppIcon name="clock" :size="20" class="mt-0.5 shrink-0 text-amber-600" />
              <div>
                <h2 class="text-base font-semibold text-stone-900">
                  {{ t('customer.paywall.closedTitle') }}
                </h2>
                <p class="mt-1 text-sm text-stone-600">{{ t('customer.paywall.closedBody') }}</p>
                <p v-if="supportContact" class="mt-3 text-sm text-stone-600">
                  {{ t('customer.paywall.closedContact') }}:
                  <a :href="`tel:${supportContact}`" class="font-medium text-brand-800 underline">{{
                    supportContact
                  }}</a>
                </p>
              </div>
            </div>
          </div>

          <p v-if="justPaid && unlockedBody" class="alert-success mt-6" role="status">
            {{ t('customer.order.unlocked') }}
          </p>

          <!-- The deliverable, on the page it was bought from. -->
          <section v-else-if="unlockedBody" class="card card-pad mt-8" role="status">
            <h2 class="text-lg font-semibold text-stone-900">
              {{ t('customer.order.unlocked') }}
            </h2>
            <MarkdownBody :source="unlockedBody" class="mt-4" />
            <a
              v-if="ctaUrl"
              :href="ctaUrl"
              target="_blank"
              rel="noopener noreferrer"
              class="mt-4 inline-flex items-center gap-1.5 text-sm text-brand-700 hover:underline"
            >
              <span class="ltr-value">{{ ctaUrl }}</span>
              <AppIcon name="external" :size="14" />
            </a>
          </section>

          <!-- The customer's own open order, in every state it can be in. This
               section takes the payment form's place and persists across
               refreshes: the session holds the order, and every mount reads it. -->
          <section v-else-if="existingOrder" class="card card-pad mt-8">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-lg font-semibold text-stone-900">
                {{ t('customer.order.title') }}
              </h2>
              <OrderStatusBadge
                :status="existingOrder.status"
                :label="t(`customer.order.status.${existingOrder.status}`)"
              />
            </div>
            <p class="hint mt-1">
              {{ t('customer.order.reference') }}:
              <span class="ltr-value font-medium text-stone-800">
                {{ existingOrder.reference_code }}
              </span>
            </p>

            <p class="mt-3 text-sm text-stone-600">
              {{ t('customer.paywall.summaryAmount') }}:
              <span class="ltr-value font-medium text-stone-900">
                {{ money(Number(existingOrder.amount)) }}
              </span>
            </p>
            <p v-if="existingOrder.expires_at" class="hint mt-1">
              {{ t('customer.order.completeBy') }}:
              <span class="ltr-value">{{ formatExpiry(existingOrder.expires_at) }}</span>
            </p>

            <p v-if="error" class="alert-error mt-4" role="alert">{{ error }}</p>

            <!-- Online: one button, and the customer is at bKash. -->
            <template v-if="orderPaysOnline && existingOrder.status === 'awaiting_proof'">
              <button
                type="button"
                class="btn-primary mt-4 w-full"
                :disabled="paying"
                @click="payExisting"
              >
                {{ paying ? t('customer.paywall.submitting') : t('customer.order.payOnline') }}
              </button>
            </template>

            <!-- Manual: the account to pay, and the proof to attach. -->
            <template
              v-else-if="
                !orderPaysOnline && ['awaiting_proof', 'rejected'].includes(existingOrder.status)
              "
            >
              <p v-if="existingOrder.status === 'rejected'" class="alert-error mt-4" role="alert">
                {{ t('customer.order.rejectReason') }}:
                {{
                  pick({ bn: existingOrder.reject_reason_bn, en: existingOrder.reject_reason_en })
                }}
              </p>

              <div class="mt-4">
                <p class="label">{{ t('customer.paywall.sendTo') }}</p>
                <GatewayAccountDetails
                  class="rounded-lg bg-white px-3 py-2.5"
                  :fields="orderAccountFields"
                  :legacy-number="orderAccountLegacy.number"
                  :legacy-name="orderAccountLegacy.name"
                />
              </div>

              <div class="mt-5">
                <h3 class="text-sm font-semibold text-stone-900">
                  {{ t('customer.order.submitEvidence') }}
                </h3>
                <MarkdownBody :source="t('customer.order.evidenceHint')" class="hint mb-4" />
                <EvidenceForm
                  :evidence-fields="orderEvidenceFields"
                  :submitting="submittingEvidence"
                  @submit="submitEvidence"
                />
              </div>
            </template>

            <p
              v-else-if="existingOrder.status === 'under_review'"
              class="mt-4 text-sm text-stone-600"
            >
              {{ t('customer.order.underReview') }}
            </p>
            <p v-else-if="existingOrder.status === 'locked'" class="alert-error mt-4" role="alert">
              {{ t('customer.order.locked') }}
            </p>
          </section>

          <!-- Selector and amount live outside any form: the manual path's
               submit button belongs to the proof form below, and nesting the
               two forms would make the browser pick one submit for both. -->
          <div v-else class="mt-8 space-y-6">
            <section class="card card-pad">
              <h2 class="text-lg font-semibold text-stone-900">
                {{ t('customer.paywall.chooseMethod') }}
              </h2>
              <MarkdownBody :source="t('customer.paywall.chooseMethodHint')" class="hint mb-4" />

              <GatewaySelector
                v-if="gateways.length > 0"
                v-model:selected="selectedKind"
                :gateways="gateways"
              />
              <p v-else class="empty-state">{{ t('customer.paywall.noMethods') }}</p>
            </section>

            <section v-if="selectedKind" class="card card-pad">
              <label class="label" for="amount">{{ t('customer.paywall.amount') }}</label>

              <!-- Tap a price, or tap Custom and type one. The input stays
                   hidden behind the chips until the customer asks for it. -->
              <div v-if="amountPresets.length > 0" class="mt-3 flex flex-wrap gap-2">
                <button
                  v-for="preset in amountPresets"
                  :key="preset"
                  type="button"
                  class="rounded-full border px-4 py-2 text-sm font-medium transition"
                  :class="
                    amountMode === 'preset' && amount === preset
                      ? 'border-brand-600 bg-brand-50 text-brand-800 ring-1 ring-brand-600'
                      : 'border-stone-200 bg-white text-stone-700 hover:border-stone-300'
                  "
                  @click="selectPreset(preset)"
                >
                  <span class="ltr-value">{{ money(preset) }}</span>
                </button>
                <button
                  type="button"
                  class="rounded-full border px-4 py-2 text-sm font-medium transition"
                  :class="
                    amountMode === 'custom'
                      ? 'border-brand-600 bg-brand-50 text-brand-800 ring-1 ring-brand-600'
                      : 'border-stone-200 bg-white text-stone-700 hover:border-stone-300'
                  "
                  @click="amountMode = 'custom'"
                >
                  {{ t('customer.paywall.custom') }}
                </button>
              </div>

              <input
                v-if="amountPresets.length === 0 || amountMode === 'custom'"
                id="amount"
                v-model.number="amount"
                type="number"
                min="0"
                step="1"
                inputmode="decimal"
                class="field ltr-value mt-3"
                :placeholder="t('customer.paywall.amountAny')"
                :aria-describedby="amountHintId"
              />
              <p :id="amountHintId" class="hint" :class="amountError ? 'text-red-600' : ''">
                {{ amountError || amountHint }}
              </p>
            </section>

            <!--
              A manual method shows everything the customer needs on this page:
              where to send the money, and the proof form, under one submit.
              An automatic method has no details to show - the payment IS the
              button - so it keeps the summary and its own form.
            -->
            <!-- The summary is the same for both paths: what is being bought,
                 and for how much. The method-specific bodies follow it. -->
            <section v-if="selectedKind" class="card card-pad">
              <h2 class="text-sm font-semibold text-stone-900">
                {{ t('customer.paywall.summary') }}
              </h2>
              <dl class="mt-3 space-y-2 text-sm">
                <div class="flex justify-between gap-4">
                  <dt class="text-stone-500">{{ t('customer.paywall.summaryPage') }}</dt>
                  <dd class="text-right font-medium text-stone-900">{{ pageTitle }}</dd>
                </div>
                <div class="flex justify-between gap-4">
                  <dt class="text-stone-500">{{ t('customer.paywall.summaryAmount') }}</dt>
                  <dd class="ltr-value font-medium text-stone-900">{{ money(amount) }}</dd>
                </div>
              </dl>

              <div v-if="pageCta || ctaUrl" class="mt-5 border-t border-stone-100 pt-4">
                <p class="text-sm font-medium text-stone-700">
                  {{ t('customer.paywall.deliverable') }}
                </p>
                <p class="mt-1 text-sm text-stone-600">{{ pageCta }}</p>
                <a
                  v-if="ctaUrl"
                  :href="ctaUrl"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="mt-2 inline-flex items-center gap-1.5 text-sm text-brand-700 hover:underline"
                >
                  <span class="ltr-value">{{ ctaUrl }}</span>
                  <AppIcon name="external" :size="14" />
                </a>
              </div>
            </section>

            <section
              v-if="selectedGateway && selectedGateway.provider === null"
              class="card card-pad"
            >
              <h2 class="text-lg font-semibold text-stone-900">
                {{ pickedGatewayName }}
              </h2>
              <p class="label mt-4">{{ t('customer.paywall.sendTo') }}</p>
              <GatewayAccountDetails
                class="rounded-lg bg-white px-3 py-2.5"
                :fields="selectedAccountFields"
                :legacy-number="selectedGateway.account_number"
                :legacy-name="selectedGateway.account_name"
              />
              <p v-if="selectedInstructions" class="mt-4">
                <MarkdownBody :source="selectedInstructions" />
              </p>

              <EvidenceForm
                class="mt-5"
                :evidence-fields="selectedGateway.evidence_fields ?? []"
                :submitting="creating"
                @submit="createManualOrder"
              />
            </section>

            <form
              v-if="selectedKind && kindPaysOnline"
              class="card card-pad"
              @submit.prevent="createOrder"
            >
              <button
                type="submit"
                class="btn-primary mt-6 w-full"
                :disabled="creating || !isAmountValid"
              >
                {{ creating ? t('customer.paywall.submitting') : t('customer.paywall.submit') }}
              </button>
            </form>
          </div>
        </template>
      </component>
    </template>
  </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import { formatMoney } from '@/lib/money'
import { useContent } from '@/composables/useContent'
import type { LocalizedPair } from '@/lib/content'
import { watch } from 'vue'
import { describeEdgeFailure, invokeWithRetry } from '@/lib/edgeError'
import { rpc, rpcList } from '@/lib/rpc'
import type { MyOrder, MyOrderStatus } from '@/lib/rpc'
import EvidenceForm, { type EvidenceField } from '@/components/customer/EvidenceForm.vue'
import type { AccountField } from '@/components/customer/GatewayAccountDetails.vue'
import GatewayAccountDetails from '@/components/customer/GatewayAccountDetails.vue'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import { useFileUpload } from '@/composables/useFileUpload'
import { buildEvidencePayload } from '@/lib/evidencePayload'
import { useOrderPolling } from '@/composables/useOrderPolling'
import { usePageStandalone } from '@/composables/usePageStandalone'
import { normalizeConfig, templateFor } from '@/pages/templates/registry'
import { useSiteSettings } from '@/composables/useSiteSettings'
import AppIcon from '@/components/AppIcon.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import GatewaySelector from '@/components/customer/GatewaySelector.vue'
import type { OrderResult, PublicPageDetail } from '@/lib/rpc'

const route = useRoute()
const supabase = getSupabase()
const { pick } = useContent()
const { t } = useI18n()
const { settings } = useSiteSettings()

// Decides what is rendered. `create_order()` refuses independently, so if this is
// stale or the settings fetch failed, the worst case is a form that fails on submit
// rather than an order that slips through.
const maintenance = computed(() => settings.value.maintenance_mode)
const supportContact = computed(() => settings.value.contact)

/**
 * A gateway as the paywall publishes it: an id, a kind, a name, the provider slug and a
 * sort order. The account number, instructions, reference prompt and evidence fields that
 * used to be here are not withheld for lack of translation but because they describe an
 * order, not a link - they come back from `my_order_status` once there is one. (Wording
 * predates the rename; the fields describe an order, which is still true.)
 */
interface Gateway {
  id: string
  kind: string
  name_bn: string | null
  name_en: string | null
  provider: string | null
  sort_order: number | null
  account_number: string | null
  account_name: string | null
  account_fields: AccountField[] | null
  instructions_md_en: string | null
  instructions_md_bn: string | null
  reference_prompt_en: string | null
  reference_prompt_bn: string | null
  supports_reference: boolean
  evidence_fields: EvidenceField[]
}

interface Page {
  id: string
  slug: string
  title_bn: string | null
  title_en: string | null
  teaser_md_bn: string | null
  teaser_md_en: string | null
  unlock_cta_label_bn: string | null
  unlock_cta_label_en: string | null
  unlock_cta_url: string | null
  /**
   * Which code-side layout draws this page, and that layout's config. The
   * config is normalized on read so the renderer never meets a missing field.
   */
  template: string
  template_config: unknown
  /**
   * Already resolved for the page's override and the global default, and
   * forced to null when the minimum is hidden, so there is no second path by
   * which a client could learn it.
   */
  is_listed: boolean
  min_amount: number | null
  min_hidden: boolean
  amount_presets: number[] | null
  gateways: Gateway[]
}

const amountHintId = 'amount-hint'

const page = ref<Page | null>(null)
const gateways = ref<Gateway[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const selectedKind = ref<string | null>(null)
const amount = ref<number>(0)
const creating = ref(false)

const slug = computed(() => route.params.slug as string)
const { setStandalone, isStandalone } = usePageStandalone()

/**
 * The template the page renders with, resolved from the registry. Everything
 * template-shaped about the render — which layout, which config, which
 * component — comes from this one lookup.
 */
const template = computed(() => templateFor(page.value?.template))
const templateConfig = computed(() =>
  normalizeConfig(template.value.id, page.value?.template_config),
)
// The v-else branch guarantees a page at render time; this alias records that
// guarantee in one place instead of a non-null assertion in the markup.
const renderPage = computed(() => page.value as Page)

/**
 * bKash lands the customer back here with `?paid=1` after the return leg settled
 * their payment. It says one thing once and disappears: the deliverable below is
 * the news, not the banner.
 */
const justPaid = computed(() => route.query?.paid === '1')

// ---------------------------------------------------------------------------
// The customer's order for this page, rendered on the page itself.
//
// Checkout used to bounce the customer through a separate order page: create
// here, pay there, come back somewhere else. Every state an order can be in is
// actionable on this page - pay it, attach proof to it, read what it bought -
// so the page is the whole flow, and the /:slug/order/:id route survives only
// as a deep-link alias for links people already have.
// ---------------------------------------------------------------------------

const existingOrder = ref<MyOrder | null>(null)
const orderDetails = ref<MyOrderStatus | null>(null)
const unlockedBody = ref<string | null>(null)
const paying = ref(false)
const submittingEvidence = ref(false)
const fileUpload = useFileUpload()

let polling: ReturnType<typeof useOrderPolling> | null = null

/** The open order's gateway, matched against this page's published methods. */
const orderGateway = computed(() =>
  existingOrder.value && page.value
    ? gateways.value.find((g) => g.kind === existingOrder.value!.gateway_kind)
    : undefined,
)

/** An order pays online when its kind has an automatic account behind it. */
const orderPaysOnline = computed(() => orderGateway.value?.provider != null)

/**
 * The gateway behind the method the customer just picked. A kind can have
 * several accounts behind it; the shop picks one at order time, but the
 * account details are per-kind display copy, so showing the first active
 * account of the kind is what the customer needs before the order exists.
 */
const selectedGateway = computed(() => gateways.value.find((g) => g.kind === selectedKind.value))
const pickedGatewayName = computed(() =>
  selectedGateway.value
    ? pick({ bn: selectedGateway.value.name_bn, en: selectedGateway.value.name_en })
    : '',
)
const selectedAccountFields = computed(
  () => (selectedGateway.value?.account_fields ?? []) as unknown as AccountField[],
)
const selectedInstructions = computed(() =>
  selectedGateway.value
    ? pick({
        bn: selectedGateway.value.instructions_md_bn,
        en: selectedGateway.value.instructions_md_en,
      })
    : null,
)

/**
 * `my_order_status` nests the gateway - and with it everything about where the
 * money goes - one level down, under `gateway`. Reading those fields off the
 * top level is the bug that rendered an empty account card on the panel.
 */
const statusGateway = computed(
  () => (orderDetails.value as { gateway?: Record<string, unknown> } | null)?.gateway ?? null,
)

const orderAccountLegacy = computed(() => {
  const g = statusGateway.value
  return {
    number: typeof g?.account_number === 'string' ? g.account_number : null,
    name: typeof g?.account_name === 'string' ? g.account_name : null,
  }
})

const orderAccountFields = computed(
  () => (statusGateway.value?.account_fields ?? []) as unknown as AccountField[],
)

const orderEvidenceFields = computed(
  () => (statusGateway.value?.evidence_fields ?? []) as unknown as EvidenceField[],
)

const fetchUnlocked = async (): Promise<void> => {
  const { data } = await rpc<Record<string, unknown>>('get_unlocked_page', {
    p_slug: slug.value,
  })
  if (data) {
    unlockedBody.value = pick({
      bn: data.unlock_body_md_bn,
      en: data.unlock_body_md_en,
    } as unknown as LocalizedPair)
  }
}

/**
 * Pays the existing order in place: the one-step RPC reuses it (the kind
 * matches by construction - this order belongs to this page) and the customer
 * leaves for bKash from here.
 */
const payExisting = async (): Promise<void> => {
  const order = existingOrder.value
  if (!order || paying.value) return

  paying.value = true
  error.value = null
  try {
    const { data, error: fnError } = await invokeWithRetry(() =>
      supabase.functions.invoke('bkash-create-payment', {
        body: {
          slug: slug.value,
          kind: order.gateway_kind,
          amount: Number(order.amount),
          origin: window.location.origin,
        },
      }),
    )

    if (fnError) {
      const failure = await describeEdgeFailure(fnError, 'The payment could not start.')
      if (failure.cause !== '') console.warn('[bkash-create-payment]', failure)
      error.value = failure.message
      return
    }

    const payload = data as { ok?: boolean; redirectUrl?: string } | null
    if (payload?.ok === true && payload.redirectUrl) {
      window.location.assign(payload.redirectUrl)
      return
    }
    error.value = t('customer.paywall.refused')
  } finally {
    paying.value = false
  }
}

/** Evidence for the open manual order, uploaded and submitted on this page. */
const submitEvidence = async (evidence: Record<string, unknown>): Promise<void> => {
  if (!existingOrder.value) return

  submittingEvidence.value = true
  error.value = null
  try {
    const payload = await buildEvidencePayload(evidence, fileUpload.upload, existingOrder.value.id)

    const { error: submitError } = await supabase.rpc('submit_evidence', {
      p_order_id: existingOrder.value.id,
      ...payload,
    })

    if (submitError) {
      error.value = submitError.message
      return
    }

    if (polling) await polling.refresh()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to submit evidence'
  } finally {
    submittingEvidence.value = false
  }
}

/**
 * Takes ownership of one order on this page: shows its state inline and keeps
 * watching it until it lands somewhere terminal. Used both by the mount-time
 * lookup and by the manual submission, which creates the order right here.
 */
const adoptOrder = async (orderId: string): Promise<void> => {
  const { data: status } = await rpc<MyOrderStatus>('my_order_status', {
    p_order_id: orderId,
  })
  if (status) orderDetails.value = status

  // An approved order has nothing left to act on: what it bought takes the
  // panel's place.
  if (status?.status === 'approved') {
    await fetchUnlocked()
  }

  const { data: orders } = await rpcList<MyOrder>('my_orders')
  const mine = (orders ?? []).find((o) => o.id === orderId)
  if (mine) existingOrder.value = mine

  // An open order moves on its own - the operator reviews it, the cron expires
  // it - so the page keeps watching it until it lands somewhere terminal.
  polling = useOrderPolling(orderId)
  void polling.refresh()
  polling.startPolling()

  watch(polling.status, async (next) => {
    if (next === 'approved') {
      polling?.stopPolling()
      await fetchUnlocked()
    } else if (next === 'expired') {
      // Nothing is in the way any more: the pay form comes back.
      polling?.stopPolling()
      existingOrder.value = null
      orderDetails.value = null
    } else if (next) {
      orderDetails.value = { ...(orderDetails.value ?? {}), status: next } as MyOrderStatus
    }
  })
}

const loadExistingOrder = async (): Promise<void> => {
  // A session is not guaranteed: the customer may be reading before their first
  // order. Nothing here may block the page's own render.
  try {
    const { data: sessionData } = await supabase.auth.getSession()
    if (!sessionData.session) return

    const { data: orders } = await rpcList<MyOrder>('my_orders')

    // `under_review` is deliberately missing from the SQL's open set (a review
    // does not block a second order), but it is exactly the state a customer's
    // order sits in across a refresh after submitting proof - skip it and the
    // payment form reappears over their heads. Approved wins over everything
    // (they already own it); an open order beats one under review, because the
    // open one is the thing they can still act on.
    const priority: Record<string, number> = {
      approved: 0,
      draft: 1,
      awaiting_proof: 1,
      rejected: 1,
      locked: 1,
      under_review: 2,
    }

    const mine = (orders ?? [])
      .filter((o) => o.slug === slug.value && o.status in priority)
      .sort((a, b) => (priority[a.status] ?? 9) - (priority[b.status] ?? 9))[0]
    if (!mine) return

    // Approved needs no status details - the content is the whole panel - so
    // it skips the status fetch entirely.
    if (mine.status === 'approved') {
      existingOrder.value = mine
      await fetchUnlocked()
      return
    }

    await adoptOrder(mine.id)
  } catch (err) {
    console.warn('[order-state]', err)
  }
}

const pageTitle = computed(() =>
  page.value ? pick({ bn: page.value.title_bn, en: page.value.title_en }) : '',
)
const pageCta = computed(() =>
  page.value
    ? pick({ bn: page.value.unlock_cta_label_bn, en: page.value.unlock_cta_label_en })
    : '',
)

const ctaUrl = computed(() => page.value?.unlock_cta_url || '')

// The unlocked body is deliberately absent from `get_public_page`; it is served
// per-order once the order is approved, so it is never rendered from this page.
const effectiveMin = computed(() => page.value?.min_amount ?? 0)

const hideMin = computed(() => page.value?.min_hidden === true)

/**
 * The operator's price chips, ready to tap: whole numbers only, deduped and
 * sorted, and anything below the page's effective minimum is dropped - a chip
 * the customer cannot legally tap is worse than no chip. No presets, or all
 * of them filtered, and the plain input is all there is.
 */
const amountPresets = computed(() => {
  const raw = (page.value?.amount_presets ?? []) as unknown as number[]
  const floor = hideMin.value ? 0 : effectiveMin.value
  return [...new Set(raw.map(Number).filter((n) => Number.isFinite(n) && n >= floor))].sort(
    (a, b) => a - b,
  )
})

/** Which chip the customer tapped; custom reveals the typing field. */
const amountMode = ref<'preset' | 'custom'>('preset')

const selectPreset = (preset: number): void => {
  amountMode.value = 'preset'
  amount.value = preset
}

const isAmountValid = computed(() => {
  if (effectiveMin.value > 0) return amount.value >= effectiveMin.value
  return amount.value >= 0
})

const amountHint = computed(() => {
  if (hideMin.value || effectiveMin.value <= 0) return t('customer.paywall.amountAny')
  return t('customer.paywall.amountMin', { amount: money(effectiveMin.value) })
})

const amountError = computed(() => {
  if (isAmountValid.value || amount.value === 0) return ''
  return t('customer.paywall.amountError', { amount: money(effectiveMin.value) })
})

/**
 * The customer types this figure into bKash, so it stays Latin in both locales
 * — the R1 exception documented in `src/lib/money.ts`.
 *
 * One rendering for the whole page: the number the customer reads, the number
 * in the hint and the number in the error have to agree with the number they
 * transcribe, or the order is refused.
 */
const money = (amt: number): string => formatMoney(amt, 'en', settings.value.currency)

/** The order's deadline, in the customer's own clock format. */
const formatExpiry = (iso: string): string =>
  new Date(iso).toLocaleString(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  })

/**
 * `create_order` refuses in the payload rather than as an error, so the reason
 * has to be surfaced instead of navigating to a nonexistent order.
 */
const describeRefusal = (code?: string): string => {
  switch (code) {
    case 'below_minimum':
      return effectiveMin.value > 0
        ? t('customer.paywall.amountError', { amount: money(effectiveMin.value) })
        : t('customer.paywall.refused')
    case 'locked':
      return t('customer.paywall.refusedLocked')
    default:
      return t('customer.paywall.refused')
  }
}

onMounted(async () => {
  try {
    const { data: pageData, error: pageError } = await rpc<PublicPageDetail>('get_public_page', {
      p_slug: slug.value,
    })

    if (pageError) {
      error.value = pageError.message
      return
    }

    page.value = pageData as unknown as Page

    // A hidden page is standalone: no way back to the index, anywhere.
    setStandalone(page.value.is_listed === false)

    // `get_public_page` already returns the active payment methods nested in the
    // same payload, filtered to `is_active` server side.
    const raw = pageData as unknown as { gateways?: unknown }
    gateways.value = Array.isArray(raw?.gateways) ? (raw.gateways as Gateway[]) : []

    // Preselect when there is only one choice; with several, let the customer
    // choose rather than silently charging them to one.
    //
    // Keyed on distinct kinds, not gateways: weighted routing means a kind can have
    // several accounts behind it, and one row per account in the selector would offer a
    // choice the shop has already reserved the right to make.
    const kinds = [...new Set(gateways.value.map((g) => g.kind))]
    const onlyKind = kinds.length === 1 ? kinds[0] : undefined
    if (onlyKind) {
      selectedKind.value = onlyKind
    }

    // The customer's own state on this page, after the page itself is known.
    void loadExistingOrder()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load page'
  } finally {
    loading.value = false
  }
})

/**
 * `kind_mismatch` means an open order already exists for this report and this customer.
 *
 * The order is pinned to its gateway on purpose, so it cannot be re-pointed at the method
 * they just picked; the only useful response is to show them the order that is already
 * waiting. Every branch below says or shows something the customer can act on, because a
 * raised exception with nothing behind it is a dead end.
 */
/**
 * A `kind_mismatch` raise means an open order for this page is already in the
 * way. The page never navigates to it: the order panel takes the form's place
 * right here, because the page is the whole checkout and a redirect to the
 * deep-link route is exactly the multi-page flow this view exists to retire.
 */
const handOffToOpenOrder = async (): Promise<void> => {
  const { data, error: ordersError } = await supabase.rpc('my_orders')

  if (ordersError || !Array.isArray(data)) {
    error.value = t('customer.paywall.openOrderExists')
    return
  }

  const openStatuses = new Set(['draft', 'awaiting_proof', 'rejected', 'locked'])
  const existing = (data as Array<{ id: string; slug: string; status: string }>).find(
    (order) => order.slug === slug.value && openStatuses.has(order.status),
  )

  if (!existing) {
    // The order expired in the gap. Nothing is in the way any more, so the customer can
    // simply try again - but they must be told to, or they read a dead end as a refusal.
    error.value = t('customer.paywall.openOrderExpired')
    return
  }

  await adoptOrder(existing.id)
}

/**
 * Whether the chosen kind pays online.
 *
 * The shop decides which account of a kind takes the money, so the client asks
 * "is any account of this kind automatic?" rather than picking one itself. A
 * manual kind answers false and takes the evidence path instead.
 */
const kindPaysOnline = computed(() =>
  gateways.value.some((g) => g.kind === selectedKind.value && g.provider !== null),
)

/**
 * Orders belong to a user, so an anonymous sign-in is the floor of every
 * submission path. Checking the stored session is cheaper and safer than
 * calling getUser(), which also rejects for an expired session and would
 * silently orphan the old user.
 */
const ensureSession = async (): Promise<boolean> => {
  const { data: sessionData } = await supabase.auth.getSession()
  if (sessionData.session) return true

  const { error: anonError } = await supabase.auth.signInAnonymously()
  if (anonError) {
    // This one is an operator problem, not a customer problem: the project
    // has anonymous sign-ins switched off, so nobody can order at all.
    error.value = anonError.message.includes('Anonymous sign-ins are disabled')
      ? 'Checkout is not available yet: anonymous sign-ins are disabled for this store.'
      : anonError.message
    return false
  }
  return true
}

const createOrder = async (): Promise<void> => {
  if (!page.value || !selectedKind.value || !isAmountValid.value) {
    return
  }

  creating.value = true
  error.value = null
  try {
    if (!(await ensureSession())) return

    // The online kinds skip the order page entirely: the function creates the
    // order and opens the bKash session in one SQL call, and the customer's
    // next screen is bKash's. `creating` stays true through the redirect so a
    // slow function cannot be double-submitted into two sessions.
    if (kindPaysOnline.value) {
      const { data, error: fnError } = await supabase.functions.invoke('bkash-create-payment', {
        // bKash needs to know where to send the browser back to; the function
        // builds the callback from this origin and bKash's own whitelist is
        // what makes a spoofed value harmless.
        body: {
          slug: slug.value,
          kind: selectedKind.value,
          amount: amount.value,
          origin: window.location.origin,
        },
      })

      if (fnError) {
        const failure = await describeEdgeFailure(fnError, 'The payment could not start.')
        if (failure.cause !== '') console.warn('[bkash-create-payment]', failure)
        // `kind_mismatch` needs a state change, not a sentence: take the
        // customer to the order that is already waiting.
        if (failure.message.startsWith('kind_mismatch:')) {
          await handOffToOpenOrder()
          return
        }
        error.value = failure.message
        return
      }

      const payload = data as
        { ok: true; redirectUrl: string } | { ok: false; refusal: { code?: string } } | null

      if (payload && payload.ok === false) {
        error.value = describeRefusal(payload.refusal?.code)
        return
      }
      if (!payload || payload.ok !== true || !payload.redirectUrl) {
        error.value = t('customer.paywall.refused')
        return
      }

      window.location.assign(payload.redirectUrl)
      return
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to create order'
  } finally {
    creating.value = false
  }
}

/**
 * The manual path, in one click: the order is created, the proof is uploaded
 * against it and submitted, and the page itself turns into the order status.
 * There is no separate order page to walk through any more - the form the
 * customer just filled in is on this page, and so is what replaces it.
 */
const createManualOrder = async (evidence: Record<string, unknown>): Promise<void> => {
  if (!page.value || !selectedKind.value || !isAmountValid.value) {
    return
  }

  creating.value = true
  error.value = null
  try {
    if (!(await ensureSession())) return

    // Signature is `create_order(p_slug, p_kind, p_amount)`, with the amount in whole
    // taka. A *kind*, not a gateway id: the shop decides which account of that kind the
    // money goes to, weighted, and the client no longer gets a say in that.
    const { data, error: createError } = await rpc<OrderResult>('create_order', {
      p_slug: slug.value,
      p_kind: selectedKind.value,
      p_amount: amount.value,
    })

    if (createError) {
      // `kind_mismatch` is raised, not returned as a refusal code, and the migration's own
      // comment says what the client owes here: change state, not show a message. The
      // customer already has an open order for this report, pinned to one gateway so a
      // transfer receipt cannot end up aimed at an account nobody watches. Telling them
      // "kind_mismatch: open order already uses payment kind bkash Payment" answers a
      // question they did not ask and cannot act on - they do not know what a "kind" is or
      // which order is in the way. Taking them to it is the only thing that helps.
      if (
        typeof createError.message === 'string' &&
        createError.message.startsWith('kind_mismatch:')
      ) {
        await handOffToOpenOrder()
        return
      }

      error.value = createError.message
      return
    }

    // The function reports refusals in the payload rather than as an error.
    if (!data?.ok || !data.order_id) {
      error.value = describeRefusal(data?.code)
      return
    }

    // The uploads need the order id - that is half of every storage path - so
    // the proof can only be sent now that the order exists. If this half fails,
    // the order stands and the page's own order card offers the proof form
    // again; nothing is lost and nothing is asked twice.
    const payload = await buildEvidencePayload(evidence, fileUpload.upload, data.order_id)

    const { error: submitError } = await supabase.rpc('submit_evidence', {
      p_order_id: data.order_id,
      ...payload,
    })

    if (submitError) {
      error.value = submitError.message
      // The order exists; adopt it so the inline card takes over from the form.
      await adoptOrder(data.order_id)
      return
    }

    await adoptOrder(data.order_id)
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to create order'
  } finally {
    creating.value = false
  }
}
</script>

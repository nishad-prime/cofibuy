<template>
  <Teleport to="body">
    <div
      v-if="open"
      class="fixed inset-0 z-50 flex items-stretch justify-center sm:items-center sm:p-4"
      role="dialog"
      aria-modal="true"
      :aria-label="dialogTitle"
    >
      <!-- The backdrop closes too, but never while a submission is in flight. -->
      <div class="absolute inset-0 bg-stone-900/60" @click="requestClose" />

      <!--
        Full screen at phone width - the primary audience - and a centered
        card from `sm` up. One shell for every phase, so nothing jumps. Dark
        themed: it floats over a dark sales page, and the flow is part of it.
      -->
      <div
        class="payment-dark relative z-10 flex h-full w-full flex-col bg-stone-900 text-stone-100 shadow-2xl shadow-black/50 sm:h-auto sm:max-h-[90vh] sm:max-w-md sm:rounded-2xl"
      >
        <header
          class="flex items-center justify-between gap-3 border-b border-white/10 bg-stone-900 px-4 py-3 sm:rounded-t-2xl"
        >
          <div class="flex min-w-0 items-center gap-1">
            <button
              v-if="phase === 'send' && !orderInFlight"
              type="button"
              class="rounded-full p-1.5 text-stone-300 hover:bg-white/10 hover:text-white"
              :aria-label="t('customer.common.back')"
              @click="phase = 'gateway'"
            >
              <AppIcon name="arrowLeft" :size="18" />
            </button>
            <h2 class="truncate text-base font-semibold text-white">{{ dialogTitle }}</h2>
          </div>
          <button
            type="button"
            class="rounded-full p-1.5 text-stone-400 hover:bg-white/10 hover:text-white"
            :disabled="busy"
            :aria-label="t('customer.common.close')"
            @click="requestClose"
          >
            <AppIcon name="close" :size="20" />
          </button>
        </header>

        <!--
          Where the customer is in the flow, as three segments. It is the
          answer to the question a full-screen step owes an answer to: how
          much is left.
        -->
        <div
          class="flex gap-1 border-b border-white/10 bg-stone-900 px-4 pb-2.5"
          role="progressbar"
          :aria-valuenow="phaseIndex + 1"
          aria-valuemin="1"
          aria-valuemax="3"
          :aria-label="dialogTitle"
        >
          <div
            v-for="segment in 3"
            :key="segment"
            class="h-1 flex-1 rounded-full transition-colors"
            :class="segment - 1 <= phaseIndex ? 'bg-brand-400' : 'bg-white/10'"
          />
        </div>

        <div ref="modalBody" class="flex-1 overflow-y-auto p-4 sm:p-5">
          <!--
            Phase 1: gateway. Banners, not a list: the customer's country
            decides which one is big, which is preferred, and which is scaled
            down - and tapping a banner IS the choice, so there is no
            Continue between picking a method and paying.
          -->
          <div v-if="phase === 'gateway'" class="space-y-4">
            <p v-if="checkout.gatewayBanners.value.length > 0" class="hint">
              {{ t('customer.paywall.chooseMethodHint') }}
            </p>
            <template v-if="checkout.gatewayBanners.value.length > 0">
              <!--
                A size grid, not a stack, at every width: the primary takes the
                full row, the preferred methods flow two per row, and the
                foreign ones iterate the same rows, dimmed.
              -->
              <div class="grid grid-cols-2 gap-2 sm:gap-3">
                <GatewayBanner
                  v-for="entry in checkout.gatewayBanners.value"
                  :key="entry.kind"
                  :entry="entry"
                  :class="entry.size === 'big' ? 'col-span-2' : ''"
                  @select="chooseKind(entry.kind)"
                />
              </div>
            </template>
            <p v-else class="empty-state">{{ t('customer.paywall.noMethods') }}</p>

            <p v-if="checkout.error.value" class="alert-error" role="alert">
              {{ checkout.error.value }}
            </p>
          </div>

          <!--
            Phase 2: send and confirm. Two cards, nothing else: what the
            customer sends (amount, account) and the proof that it happened.
            Everything else - the page, the deliverable, the method - was
            decided before this screen opened.
          -->
          <div v-else-if="phase === 'send'" class="space-y-5">
            <p v-if="checkout.error.value" class="alert-error" role="alert">
              {{ checkout.error.value }}
            </p>

            <!--
              An order already in flight is finished goods: its amount and its
              gateway are fixed, so the customer re-sends against what exists
              rather than picking again. The reference is the hero: it is the
              one thing that ties their transfer to this order.
            -->
            <template v-if="orderInFlight">
              <section
                v-if="!checkout.orderPaysOnline.value"
                class="card card-pad"
                aria-live="polite"
              >
                <div class="flex items-center justify-between gap-3">
                  <h3 class="text-sm font-semibold text-stone-900">
                    {{ t('customer.paywall.sendStep') }}
                  </h3>
                  <span class="badge-muted">{{ orderGatewayName }}</span>
                </div>

                <div class="mt-4 flex items-baseline justify-between gap-3">
                  <p class="label">{{ t('customer.paywall.summaryAmount') }}</p>
                  <p class="ltr-value text-lg font-semibold text-stone-900">
                    {{ checkout.money(sendAmount) }}
                  </p>
                </div>

                <p class="label mt-4">{{ t('customer.order.reference') }}</p>
                <p class="ltr-value font-mono text-xl font-semibold tracking-wide text-stone-900">
                  {{ checkout.existingOrder.value?.reference_code }}
                </p>
                <p v-if="checkout.existingOrder.value?.expires_at" class="hint mt-1">
                  {{ t('customer.order.completeBy') }}:
                  <span class="ltr-value">{{
                    checkout.formatExpiry(checkout.existingOrder.value.expires_at)
                  }}</span>
                </p>

                <p class="label mt-4">{{ t('customer.paywall.sendTo') }}</p>
                <GatewayAccountDetails
                  class="rounded-lg bg-white px-3 py-2.5"
                  :fields="checkout.orderAccountFields.value"
                  :legacy-number="checkout.orderAccountLegacy.value.number"
                  :legacy-name="checkout.orderAccountLegacy.value.name"
                />
                <p class="hint mt-3">
                  {{
                    t('customer.paywall.sendExactReference', {
                      amount: checkout.money(sendAmount),
                    })
                  }}
                </p>
              </section>

              <section
                v-if="!checkout.orderPaysOnline.value && orderAcceptsEvidence"
                class="card card-pad"
              >
                <h3 class="text-sm font-semibold text-stone-900">
                  {{ t('customer.paywall.stepConfirm') }}
                </h3>
                <MarkdownBody :source="t('customer.order.evidenceHint')" class="hint mb-4" />
                <EvidenceForm
                  :evidence-fields="checkout.orderEvidenceFields.value"
                  :submitting="checkout.submittingEvidence.value"
                  @submit="submitExistingEvidence"
                />
              </section>

              <section v-else class="card card-pad">
                <button
                  type="button"
                  class="btn-primary w-full"
                  :disabled="checkout.paying.value"
                  @click="checkout.payExisting"
                >
                  {{
                    checkout.paying.value
                      ? t('customer.order.payOnlinePending')
                      : t('customer.order.payOnline')
                  }}
                </button>
              </section>
            </template>

            <!-- New order: the customer is still choosing. -->
            <template v-else>
              <!--
                One card decides and shows the whole transfer: the amount, the
                account, the exact-amount rule. The method was picked one step
                ago; its name is a badge, not a section.
              -->
              <section
                v-if="checkout.selectedGateway.value?.provider === null"
                class="card card-pad"
              >
                <div class="flex items-center justify-between gap-3">
                  <h3 class="text-sm font-semibold text-stone-900">
                    {{ t('customer.paywall.sendStep') }}
                  </h3>
                  <span class="badge-muted">{{ checkout.pickedGatewayName.value }}</span>
                </div>

                <label class="label mt-4" for="amount">{{ t('customer.paywall.amount') }}</label>
                <!--
                  A fixed-amount page shows the price, not a choice: the
                  selector collapses to the figure itself.
                -->
                <template v-if="checkout.fixedAmount.value !== null">
                  <p class="ltr-value mt-2 text-2xl font-bold text-stone-100">
                    {{ checkout.money(checkout.fixedAmount.value) }}
                  </p>
                </template>
                <template v-else>
                  <!--
                    Chips fill the input; the input is always there, so a custom
                    figure never hides behind a mode.
                  -->
                  <div
                    v-if="checkout.amountPresets.value.length > 0"
                    class="mt-2 flex flex-wrap gap-2"
                  >
                    <button
                      v-for="preset in checkout.amountPresets.value"
                      :key="preset"
                      type="button"
                      class="rounded-full border px-4 py-2 text-sm font-medium transition"
                      :class="
                        checkout.amount.value === preset
                          ? 'border-brand-600 bg-brand-50 text-brand-800 ring-1 ring-brand-600'
                          : 'border-stone-200 bg-white text-stone-700 hover:border-stone-300'
                      "
                      @click="checkout.selectPreset(preset)"
                    >
                      <span class="ltr-value">{{ checkout.money(preset) }}</span>
                    </button>
                  </div>
                  <input
                    id="amount"
                    v-model.number="checkout.amount.value"
                    type="number"
                    min="0"
                    step="1"
                    inputmode="decimal"
                    class="field ltr-value mt-3"
                    :placeholder="t('customer.paywall.amountAny')"
                    :aria-describedby="amountHintId"
                  />
                  <p
                    :id="amountHintId"
                    class="hint"
                    :class="checkout.amountError.value ? 'text-red-600' : ''"
                  >
                    {{ checkout.amountError.value || checkout.amountHint.value }}
                  </p>
                </template>

                <p class="label mt-5">{{ t('customer.paywall.sendTo') }}</p>
                <GatewayAccountDetails
                  class="rounded-lg bg-white px-3 py-2.5"
                  :fields="checkout.selectedAccountFields.value"
                  :legacy-number="checkout.selectedGateway.value.account_number"
                  :legacy-name="checkout.selectedGateway.value.account_name"
                />
                <p class="hint mt-3">{{ t('customer.paywall.sendExact') }}</p>
                <p v-if="checkout.selectedInstructions.value" class="mt-4">
                  <MarkdownBody :source="checkout.selectedInstructions.value" />
                </p>
              </section>

              <section
                v-if="checkout.selectedGateway.value?.provider === null"
                class="card card-pad"
              >
                <h3 class="text-sm font-semibold text-stone-900">
                  {{ t('customer.paywall.stepConfirm') }}
                </h3>
                <MarkdownBody :source="t('customer.order.evidenceHint')" class="hint mb-4" />
                <EvidenceForm
                  :evidence-fields="checkout.selectedGateway.value.evidence_fields ?? []"
                  :submitting="checkout.creating.value"
                  @submit="submitNewManualOrder"
                />
              </section>

              <!-- An automatic method: the payment IS the button. -->
              <form
                v-else-if="checkout.kindPaysOnline.value"
                class="card card-pad"
                @submit.prevent="checkout.createOrder"
              >
                <button
                  type="submit"
                  class="btn-primary w-full"
                  :disabled="checkout.creating.value || !checkout.isAmountValid.value"
                >
                  {{
                    checkout.creating.value
                      ? t('customer.paywall.submitting')
                      : t('customer.paywall.payNow')
                  }}
                </button>
              </form>
            </template>

            <button
              v-if="!orderInFlight"
              type="button"
              class="w-full text-center text-sm text-stone-500 hover:text-stone-700"
              :disabled="busy"
              @click="phase = 'gateway'"
            >
              {{ t('customer.paywall.changeMethod') }}
            </button>
          </div>

          <!-- Phase 3: status. -->
          <div v-else class="space-y-4">
            <p
              v-if="checkout.justPaid.value && checkout.unlockedBody.value"
              class="alert-success"
              role="status"
            >
              {{ t('customer.order.unlocked') }}
            </p>

            <template v-if="checkout.existingOrder.value">
              <section class="card card-pad">
                <div class="flex items-center justify-between gap-3">
                  <h3 class="text-lg font-semibold text-stone-900">
                    {{ t('customer.order.title') }}
                  </h3>
                  <OrderStatusBadge
                    :status="displayStatus"
                    :label="t(`customer.order.status.${displayStatus}`)"
                  />
                </div>
                <p class="hint mt-1">
                  {{ t('customer.order.reference') }}:
                  <span class="ltr-value font-medium text-stone-800">
                    {{ checkout.existingOrder.value.reference_code }}
                  </span>
                </p>
                <p class="mt-3 text-sm text-stone-600">
                  {{ t('customer.paywall.summaryAmount') }}:
                  <span class="ltr-value font-medium text-stone-900">
                    {{ checkout.money(Number(checkout.existingOrder.value.amount)) }}
                  </span>
                </p>
                <p v-if="checkout.existingOrder.value.expires_at" class="hint mt-1">
                  {{ t('customer.order.completeBy') }}:
                  <span class="ltr-value">{{
                    checkout.formatExpiry(checkout.existingOrder.value.expires_at)
                  }}</span>
                </p>

                <p v-if="checkout.error.value" class="alert-error mt-4" role="alert">
                  {{ checkout.error.value }}
                </p>

                <!-- Rejected: the reason, and the form to try again with. -->
                <template
                  v-if="
                    !checkout.orderPaysOnline.value &&
                    checkout.existingOrder.value.status === 'rejected'
                  "
                >
                  <p class="alert-error mt-4" role="alert">
                    {{ t('customer.order.rejectReason') }}:
                    {{
                      checkout.pick({
                        bn: checkout.existingOrder.value.reject_reason_bn,
                        en: checkout.existingOrder.value.reject_reason_en,
                      })
                    }}
                  </p>
                  <div class="mt-4">
                    <h3 class="text-sm font-semibold text-stone-900">
                      {{ t('customer.order.submitEvidence') }}
                    </h3>
                    <MarkdownBody :source="t('customer.order.evidenceHint')" class="hint mb-4" />
                    <EvidenceForm
                      :evidence-fields="checkout.orderEvidenceFields.value"
                      :submitting="checkout.submittingEvidence.value"
                      @submit="submitExistingEvidence"
                    />
                  </div>
                </template>

                <!-- Under review is a manual-payment state: an automatic payment
                     settles straight to approved, and the transient DB hop
                     through under_review must never read as proof language. -->
                <p
                  v-else-if="
                    !checkout.orderPaysOnline.value &&
                    checkout.existingOrder.value.status === 'under_review'
                  "
                  class="mt-4 text-sm text-stone-600"
                >
                  {{ t('customer.order.underReview') }}
                </p>
                <p v-else-if="displayStatus === 'approved'" class="mt-4 text-sm text-stone-600">
                  {{ t('customer.order.unlocked') }}
                </p>
                <p
                  v-else-if="checkout.existingOrder.value.status === 'locked'"
                  class="alert-error mt-4"
                  role="alert"
                >
                  {{ t('customer.order.locked') }}
                </p>
              </section>

              <!-- What an approved order bought, right under its status. -->
              <section v-if="checkout.unlockedBody.value" class="card card-pad">
                <MarkdownBody :source="checkout.unlockedBody.value" />

                <!--
                  Telegram invite: the CTA becomes a join link when the page
                  targets a Telegram chat and the bot has created the invite.
                -->
                <a
                  v-if="checkout.telegramInvite.value && !checkout.telegramInvite.value.revoked"
                  :href="checkout.telegramInvite.value.url"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn-primary cta-glow group mt-5 w-full py-3.5 text-base"
                >
                  {{ t('customer.order.joinTelegram') }}
                  <ArrowRight
                    :size="18"
                    aria-hidden="true"
                    class="transition-transform group-hover:translate-x-0.5"
                  />
                </a>
                <p
                  v-else-if="checkout.telegramInvite.value?.revoked"
                  class="alert-error mt-4"
                  role="alert"
                >
                  {{ t('customer.order.inviteRevoked') }}
                </p>
                <p
                  v-else-if="!checkout.ctaUrl.value"
                  class="mt-5 flex items-center gap-2 text-sm text-stone-400"
                >
                  <span class="inline-block size-2 animate-pulse rounded-full bg-brand-400" />
                  {{ t('customer.order.invitePreparing') }}
                </p>

                <a
                  v-if="checkout.ctaUrl.value && !checkout.telegramInvite.value"
                  :href="checkout.ctaUrl.value"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="mt-4 inline-flex items-center gap-1.5 text-sm text-brand-700 hover:underline"
                >
                  <span class="ltr-value">{{ checkout.ctaUrl.value }}</span>
                  <AppIcon name="external" :size="14" />
                </a>
              </section>
            </template>

            <button
              v-else-if="checkout.justPaid.value"
              type="button"
              class="btn-primary w-full"
              @click="close"
            >
              {{ t('customer.common.close') }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import AppIcon from '@/components/AppIcon.vue'
import { ArrowRight } from 'lucide-vue-next'
import MarkdownBody from '@/components/MarkdownBody.vue'
import GatewayBanner from '@/components/customer/GatewayBanner.vue'
import GatewayAccountDetails from '@/components/customer/GatewayAccountDetails.vue'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import EvidenceForm from '@/components/customer/EvidenceForm.vue'
import type { PageCheckout } from '@/composables/usePageCheckout'

const amountHintId = 'amount-hint'

const props = defineProps<{
  /** The page's one checkout instance, owned by PageCheckoutSection. */
  checkout: PageCheckout
}>()

const open = defineModel<boolean>('open', { default: false })

const { t } = useI18n()

/**
 * The three screens the customer walks through. Which one a fresh open lands
 * on is decided once per open, from the checkout's own state - never from a
 * query string.
 */
type Phase = 'gateway' | 'send' | 'status'
const phase = ref<Phase>('gateway')

/** A submission in flight may not be closed away; the browser might be leaving for bKash. */
const busy = computed(
  () =>
    checkout.value.creating.value ||
    checkout.value.submittingEvidence.value ||
    checkout.value.paying.value,
)

const checkout = computed(() => props.checkout)

/** The amount shown in the summary: the order's own, or the one being chosen. */
const sendAmount = computed(() =>
  orderInFlight.value
    ? Number(checkout.value.existingOrder.value?.amount ?? 0)
    : checkout.value.amount.value,
)

/** The in-flight order's method, as a badge: a label, not a section. */
const orderGatewayName = computed(() => {
  const gateway = checkout.value.orderGateway.value
  return gateway
    ? checkout.value.pick({ bn: gateway.name_bn, en: gateway.name_en }) || gateway.kind
    : (checkout.value.existingOrder.value?.gateway_kind ?? '')
})

/** An order that exists and has not landed anywhere final. */
const orderInFlight = computed(() => {
  const order = checkout.value.existingOrder.value
  return order !== null && ['draft', 'awaiting_proof', 'rejected'].includes(order.status)
})

/**
 * What the status page shows, as opposed to what the database row says. An
 * automatic payment has no review phase: bKash confirmed it or it did not
 * happen, so the moment it is past `awaiting_proof` it reads as success -
 * including the transient `under_review` hop the settlement RPC walks to
 * satisfy the status guard.
 */
const displayStatus = computed(() => {
  const status = checkout.value.existingOrder.value?.status
  if (checkout.value.orderPaysOnline.value && status === 'under_review') return 'approved'
  return status ?? 'draft'
})

const dialogTitle = computed(() => {
  if (phase.value === 'gateway') return t('customer.paywall.chooseMethod')
  if (phase.value === 'send') return t('customer.paywall.sendStep')
  return t('customer.order.title')
})

/** The segment the progress bar fills up to, per phase. */
const phaseIndex = computed(() => (phase.value === 'gateway' ? 0 : phase.value === 'send' ? 1 : 2))

const modalBody = ref<HTMLElement | null>(null)

// Each phase starts at its own top: landing mid-scroll on a new step reads
// as a broken page.
watch(phase, () => {
  if (modalBody.value) modalBody.value.scrollTop = 0
})

/**
 * Where a fresh open starts. A customer with nothing in flight chooses the
 * gateway; a manual order still waiting for proof goes back to the send step
 * so they can finish it; proof submitted, rejected or paid, the status page
 * is the whole story.
 */
function phaseForOpen(): Phase {
  const c = checkout.value
  if (c.justPaid.value) return 'status'
  const order = c.existingOrder.value
  if (!order) return 'gateway'
  if (order.status === 'awaiting_proof') return 'send'
  return 'status'
}

watch(
  open,
  (isOpen) => {
    if (isOpen) {
      phase.value = phaseForOpen()
      document.body.style.overflow = 'hidden'
      window.addEventListener('keydown', onEscape)
      // The invite poll runs while the modal is open on an approved order
      // whose Telegram invite hasn't arrived yet (cron lag on manual approvals).
      const order = checkout.value.existingOrder.value
      if (order?.status === 'approved' && !checkout.value.telegramInvite.value) {
        checkout.value.startInvitePolling()
      }
      void nextTick(() => {
        if (modalBody.value) modalBody.value.scrollTop = 0
      })
      return
    }
    checkout.value.stopInvitePolling()
    document.body.style.overflow = ''
    window.removeEventListener('keydown', onEscape)
  },
  { immediate: true },
)

function onEscape(event: KeyboardEvent): void {
  if (event.key === 'Escape') requestClose()
}

function requestClose(): void {
  if (busy.value) return
  open.value = false
}

function close(): void {
  open.value = false
}

/** Tapping a banner is the whole choice: pick the kind, walk straight in. */
function chooseKind(kind: string): void {
  checkout.value.selectedKind.value = kind
  startSend()
}

/** The send step always opens with an amount in place. */
function startSend(): void {
  checkout.value.applyDefaultAmount()
  checkout.value.error.value = null
  phase.value = 'send'
}

/**
 * Whether the in-flight order can still take proof. Only `awaiting_proof` and
 * `rejected` do - `under_review` is already someone's reading queue, and
 * submitting against it is how "this order is not accepting evidence"
 * happened: the send step outlived the state it was rendered for.
 */
const orderAcceptsEvidence = computed(() => {
  const order = checkout.value.existingOrder.value
  return order !== null && ['awaiting_proof', 'rejected'].includes(order.status)
})

async function submitExistingEvidence(evidence: Record<string, unknown>): Promise<void> {
  // A poll can move the order while this screen sits open; the form cannot
  // know that. Guard here rather than letting the database say no.
  if (checkout.value.existingOrder.value && !orderAcceptsEvidence.value) {
    checkout.value.error.value = null
    phase.value = 'status'
    return
  }
  await checkout.value.submitEvidence(evidence)
  // The database can also refuse what the client believed: its
  // "not accepting evidence" means the order moved on, and the status page
  // is where that story is.
  if (/not accepting evidence/i.test(checkout.value.error.value ?? '')) {
    checkout.value.error.value = null
    phase.value = 'status'
    return
  }
  phaseAfterSubmission()
}

/** A fresh manual submission becomes the order: the status page is the answer. */
async function submitNewManualOrder(evidence: Record<string, unknown>): Promise<void> {
  await checkout.value.createManualOrder(evidence)
  if (/not accepting evidence/i.test(checkout.value.error.value ?? '')) {
    checkout.value.error.value = null
    phase.value = 'status'
    return
  }
  phaseAfterSubmission()
}

/**
 * Where a finished submission leaves the customer. "No error" is not the same
 * as "under review": `createManualOrder` can hand off to an order that was
 * already in the way (`kind_mismatch`), and that order's own state - not the
 * absence of a message - decides whether this is the status page or the send
 * step it still needs.
 */
function phaseAfterSubmission(): void {
  if (checkout.value.error.value) return
  const order = checkout.value.existingOrder.value
  if (!order) return
  phase.value = order.status === 'awaiting_proof' ? 'send' : 'status'
}

// A proof that lands, or a fresh submission that is accepted, moves the order
// to under review; the status page is the answer, so the modal walks itself
// there without another click - from either the send step or a first
// adoption, where there was no previous status to compare against.
watch(
  () => checkout.value.existingOrder.value?.status,
  (status) => {
    if (!open.value) return
    // Expiry removes the order outright (the composable clears it), so the
    // modal sees the status vanish rather than read 'expired'. Either way,
    // nothing is in the way any more: start over.
    if (status === 'expired' || (status === undefined && !checkout.value.existingOrder.value)) {
      if (phase.value !== 'gateway') phase.value = 'gateway'
      return
    }
    if (status === 'under_review' && phase.value === 'send') {
      phase.value = 'status'
    }
  },
)
</script>

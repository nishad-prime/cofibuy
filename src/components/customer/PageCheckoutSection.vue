<template>
  <section id="page-checkout" class="scroll-mt-20">
    <!--
      The checkout takes the payment form's place in every state it can be
      in, and persists across refreshes: the session holds the order, and
      every mount reads it back.
    -->
    <div v-if="checkout.maintenance.value" class="card card-pad" role="status">
      <div class="flex items-start gap-3">
        <AppIcon name="clock" :size="20" class="mt-0.5 shrink-0 text-amber-600" />
        <div>
          <h2 class="text-base font-semibold text-stone-900">
            {{ t('customer.paywall.closedTitle') }}
          </h2>
          <p class="mt-1 text-sm text-stone-600">{{ t('customer.paywall.closedBody') }}</p>
          <p v-if="checkout.supportContact.value" class="mt-3 text-sm text-stone-600">
            {{ t('customer.paywall.closedContact') }}:
            <a
              :href="`tel:${checkout.supportContact.value}`"
              class="font-medium text-brand-800 underline"
              >{{ checkout.supportContact.value }}</a
            >
          </p>
        </div>
      </div>
    </div>

    <template v-else>
      <p
        v-if="checkout.justPaid.value && checkout.unlockedBody.value"
        class="alert-success"
        role="status"
      >
        {{ t('customer.order.unlocked') }}
      </p>

      <!-- The deliverable, on the page it was bought from. -->
      <section v-else-if="checkout.unlockedBody.value" class="card card-pad" role="status">
        <h2 class="text-lg font-semibold text-stone-900">
          {{ t('customer.order.unlocked') }}
        </h2>
        <MarkdownBody :source="checkout.unlockedBody.value" class="mt-4" />
        <a
          v-if="checkout.ctaUrl.value"
          :href="checkout.ctaUrl.value"
          target="_blank"
          rel="noopener noreferrer"
          class="mt-4 inline-flex items-center gap-1.5 text-sm text-brand-700 hover:underline"
        >
          <span class="ltr-value">{{ checkout.ctaUrl.value }}</span>
          <AppIcon name="external" :size="14" />
        </a>
      </section>

      <!-- The customer's own open order, in every state it can be in. -->
      <section v-else-if="checkout.existingOrder.value" class="card card-pad">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-lg font-semibold text-stone-900">
            {{ t('customer.order.title') }}
          </h2>
          <OrderStatusBadge
            :status="checkout.existingOrder.value.status"
            :label="t(`customer.order.status.${checkout.existingOrder.value.status}`)"
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

        <!-- Online: one button, and the customer is at bKash. -->
        <template
          v-if="
            checkout.orderPaysOnline.value &&
            checkout.existingOrder.value.status === 'awaiting_proof'
          "
        >
          <button
            type="button"
            class="btn-primary mt-4 w-full"
            :disabled="checkout.paying.value"
            @click="checkout.payExisting"
          >
            {{
              checkout.paying.value
                ? t('customer.paywall.submitting')
                : t('customer.order.payOnline')
            }}
          </button>
        </template>

        <!-- Manual: the account to pay, and the proof to attach. -->
        <template
          v-else-if="
            !checkout.orderPaysOnline.value &&
            ['awaiting_proof', 'rejected'].includes(checkout.existingOrder.value.status)
          "
        >
          <p
            v-if="checkout.existingOrder.value.status === 'rejected'"
            class="alert-error mt-4"
            role="alert"
          >
            {{ t('customer.order.rejectReason') }}:
            {{
              checkout.pick({
                bn: checkout.existingOrder.value.reject_reason_bn,
                en: checkout.existingOrder.value.reject_reason_en,
              })
            }}
          </p>

          <div class="mt-4">
            <p class="label">{{ t('customer.paywall.sendTo') }}</p>
            <GatewayAccountDetails
              class="rounded-lg bg-white px-3 py-2.5"
              :fields="checkout.orderAccountFields.value"
              :legacy-number="checkout.orderAccountLegacy.value.number"
              :legacy-name="checkout.orderAccountLegacy.value.name"
            />
          </div>

          <div class="mt-5">
            <h3 class="text-sm font-semibold text-stone-900">
              {{ t('customer.order.submitEvidence') }}
            </h3>
            <MarkdownBody :source="t('customer.order.evidenceHint')" class="hint mb-4" />
            <EvidenceForm
              :evidence-fields="checkout.orderEvidenceFields.value"
              :submitting="checkout.submittingEvidence.value"
              @submit="checkout.submitEvidence"
            />
          </div>
        </template>

        <p
          v-else-if="checkout.existingOrder.value.status === 'under_review'"
          class="mt-4 text-sm text-stone-600"
        >
          {{ t('customer.order.underReview') }}
        </p>
        <p
          v-else-if="checkout.existingOrder.value.status === 'locked'"
          class="alert-error mt-4"
          role="alert"
        >
          {{ t('customer.order.locked') }}
        </p>
      </section>

      <!--
        The checkout itself. Selector and amount live outside any form: the
        manual path's submit button belongs to the proof form below, and
        nesting the two forms would make the browser pick one submit for both.
      -->
      <div v-else class="space-y-6">
        <section class="card card-pad">
          <h2 class="text-lg font-semibold text-stone-900">
            {{ t('customer.paywall.chooseMethod') }}
          </h2>
          <MarkdownBody :source="t('customer.paywall.chooseMethodHint')" class="hint mb-4" />

          <GatewaySelector
            v-if="checkout.gateways.value.length > 0"
            v-model:selected="checkout.selectedKind.value"
            :gateways="checkout.gateways.value"
          />
          <p v-else class="empty-state">{{ t('customer.paywall.noMethods') }}</p>
        </section>

        <section v-if="checkout.selectedKind.value" class="card card-pad">
          <label class="label" for="amount">{{ t('customer.paywall.amount') }}</label>

          <!-- Tap a price, or tap Custom and type one. The input stays
               hidden behind the chips until the customer asks for it. -->
          <div v-if="checkout.amountPresets.value.length > 0" class="mt-3 flex flex-wrap gap-2">
            <button
              v-for="preset in checkout.amountPresets.value"
              :key="preset"
              type="button"
              class="rounded-full border px-4 py-2 text-sm font-medium transition"
              :class="
                checkout.amountMode.value === 'preset' && checkout.amount.value === preset
                  ? 'border-brand-600 bg-brand-50 text-brand-800 ring-1 ring-brand-600'
                  : 'border-stone-200 bg-white text-stone-700 hover:border-stone-300'
              "
              @click="checkout.selectPreset(preset)"
            >
              <span class="ltr-value">{{ checkout.money(preset) }}</span>
            </button>
            <button
              type="button"
              class="rounded-full border px-4 py-2 text-sm font-medium transition"
              :class="
                checkout.amountMode.value === 'custom'
                  ? 'border-brand-600 bg-brand-50 text-brand-800 ring-1 ring-brand-600'
                  : 'border-stone-200 bg-white text-stone-700 hover:border-stone-300'
              "
              @click="checkout.amountMode.value = 'custom'"
            >
              {{ t('customer.paywall.custom') }}
            </button>
          </div>

          <input
            v-if="
              checkout.amountPresets.value.length === 0 || checkout.amountMode.value === 'custom'
            "
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
        </section>

        <!-- The summary is the same for both paths: what is being bought,
             and for how much. The method-specific bodies follow it. -->
        <section v-if="checkout.selectedKind.value" class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">
            {{ t('customer.paywall.summary') }}
          </h2>
          <dl class="mt-3 space-y-2 text-sm">
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('customer.paywall.summaryPage') }}</dt>
              <dd class="text-right font-medium text-stone-900">{{ checkout.pageTitle.value }}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('customer.paywall.summaryAmount') }}</dt>
              <dd class="ltr-value font-medium text-stone-900">
                {{ checkout.money(checkout.amount.value) }}
              </dd>
            </div>
          </dl>

          <div
            v-if="checkout.pageCta.value || checkout.ctaUrl.value"
            class="mt-5 border-t border-stone-100 pt-4"
          >
            <p class="text-sm font-medium text-stone-700">
              {{ t('customer.paywall.deliverable') }}
            </p>
            <p class="mt-1 text-sm text-stone-600">{{ checkout.pageCta.value }}</p>
            <a
              v-if="checkout.ctaUrl.value"
              :href="checkout.ctaUrl.value"
              target="_blank"
              rel="noopener noreferrer"
              class="mt-2 inline-flex items-center gap-1.5 text-sm text-brand-700 hover:underline"
            >
              <span class="ltr-value">{{ checkout.ctaUrl.value }}</span>
              <AppIcon name="external" :size="14" />
            </a>
          </div>
        </section>

        <!--
          A manual method shows everything the customer needs on this page:
          where to send the money, and the proof form, under one submit. An
          automatic method has no details to show - the payment IS the button.
        -->
        <section
          v-if="checkout.selectedGateway.value && checkout.selectedGateway.value.provider === null"
          class="card card-pad"
        >
          <h2 class="text-lg font-semibold text-stone-900">
            {{ checkout.pickedGatewayName.value }}
          </h2>
          <p class="label mt-4">{{ t('customer.paywall.sendTo') }}</p>
          <GatewayAccountDetails
            class="rounded-lg bg-white px-3 py-2.5"
            :fields="checkout.selectedAccountFields.value"
            :legacy-number="checkout.selectedGateway.value.account_number"
            :legacy-name="checkout.selectedGateway.value.account_name"
          />
          <p v-if="checkout.selectedInstructions.value" class="mt-4">
            <MarkdownBody :source="checkout.selectedInstructions.value" />
          </p>

          <EvidenceForm
            class="mt-5"
            :evidence-fields="checkout.selectedGateway.value.evidence_fields ?? []"
            :submitting="checkout.creating.value"
            @submit="checkout.createManualOrder"
          />
        </section>

        <form
          v-if="checkout.selectedKind.value && checkout.kindPaysOnline.value"
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
                : t('customer.paywall.submit')
            }}
          </button>
        </form>
      </div>
    </template>
  </section>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import AppIcon from '@/components/AppIcon.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import GatewaySelector from '@/components/customer/GatewaySelector.vue'
import GatewayAccountDetails from '@/components/customer/GatewayAccountDetails.vue'
import OrderStatusBadge from '@/components/customer/OrderStatusBadge.vue'
import EvidenceForm from '@/components/customer/EvidenceForm.vue'
import { usePageCheckout, type CheckoutPage } from '@/composables/usePageCheckout'

const amountHintId = 'amount-hint'

const props = defineProps<{
  /** The loaded page, with its gateways and pricing already resolved. */
  page: CheckoutPage
}>()

const { t } = useI18n()

/**
 * One checkout instance per page. Everything the section renders and every
 * action it offers comes from this single composable, so templates place the
 * checkout without knowing how any of it works.
 */
const checkout = usePageCheckout(
  computed(() => props.page),
  computed(() => props.page.slug),
)

checkout.init()
</script>

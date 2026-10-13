<template>
  <!--
    Bare mode (full-bleed sales pages): the section is invisible - the CTAs
    live in the template, the flow lives in the modal. What renders here is
    only the modal host, so the page carries no checkout card and reserves no
    space for one.
  -->
  <section v-if="!bare" id="page-checkout" class="scroll-mt-20">
    <!--
      The checkout section is a trigger, not a form: every pay CTA on it opens
      the payment modal, which carries the whole flow - gateway, send and
      confirm, status. The session still holds the order, so the modal knows
      where a returning customer belongs without asking.
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
      <!-- The deliverable, on the page it was bought from. -->
      <section v-if="checkout.unlockedBody.value" class="card card-pad" role="status">
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

      <div v-else class="card card-pad">
        <h2 class="text-lg font-semibold text-stone-900">{{ checkout.pageTitle.value }}</h2>
        <p v-if="checkout.pageCta.value" class="mt-2 text-sm text-stone-600">
          {{ checkout.pageCta.value }}
        </p>
        <p class="mt-3 text-sm text-stone-600">
          {{ t('customer.paywall.summaryAmount') }}:
          <span v-if="checkout.existingOrder.value" class="ltr-value font-medium text-stone-900">
            {{ checkout.money(Number(checkout.existingOrder.value.amount)) }}
          </span>
          <span
            v-else-if="checkout.effectiveMin.value > 0 && !checkout.hideMin.value"
            class="ltr-value font-medium text-stone-900"
          >
            {{
              t('customer.paywall.amountMin', {
                amount: checkout.money(checkout.effectiveMin.value),
              })
            }}
          </span>
          <span v-else class="ltr-value font-medium text-stone-900">
            {{ t('customer.paywall.amountAny') }}
          </span>
        </p>
        <p v-if="checkout.error.value" class="alert-error mt-4" role="alert">
          {{ checkout.error.value }}
        </p>

        <button type="button" class="btn-primary mt-4 w-full" @click="modalOpen = true">
          {{ payCtaLabel }}
        </button>

      </div>
    </template>

    <!-- Template CTAs open this same modal by event; see useCheckoutModal. -->
    <PaymentModal v-model:open="modalOpen" :checkout="checkout" />
  </section>

  <!-- Bare mode: the modal host alone. -->
  <PaymentModal v-else v-model:open="modalOpen" :checkout="checkout" />
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import AppIcon from '@/components/AppIcon.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import PaymentModal from '@/components/customer/PaymentModal.vue'
import { usePageCheckout, type CheckoutPage } from '@/composables/usePageCheckout'
import { useCheckoutModal } from '@/composables/useCheckoutModal'

const props = defineProps<{
  /** The loaded page, with its gateways and pricing already resolved. */
  page: CheckoutPage
  /**
   * Invisible host: render only the payment modal, no section, no CTA card.
   * For full-bleed sales pages whose CTAs are the template's own.
   */
  bare?: boolean
}>()

const { t } = useI18n()

/**
 * One checkout instance per page. Everything the modal renders and every
 * action it offers comes from this single composable, so templates place the
 * checkout without knowing how any of it works.
 */
const checkout = usePageCheckout(
  computed(() => props.page),
  computed(() => props.page.slug),
)

checkout.init()

// The modal's open state is local to this section; template CTAs open it by
// firing the event this listens for, so every pay CTA on the page - in the
// section or in a hero - opens the same modal without a scroll and a second
// tap in between.
const modalOpen = ref(false)
const { onOpenCheckout } = useCheckoutModal()
onOpenCheckout(() => {
  modalOpen.value = true
})

/** The operator's own CTA label if they wrote one, else the store's generic pay wording. */
const payCtaLabel = computed(
  () => checkout.pageCta.value || (t('customer.page.getStarted') as string),
)
</script>

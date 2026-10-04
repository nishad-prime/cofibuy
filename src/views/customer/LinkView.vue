<template>
  <main class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
    <router-link
      to="/"
      class="mb-6 inline-flex items-center gap-2 text-sm font-medium text-stone-600 hover:text-stone-900"
    >
      <AppIcon name="arrowLeft" :size="16" />
      {{ t('customer.paywall.back') }}
    </router-link>

    <div v-if="loading" class="empty-state">{{ t('customer.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <!-- `get_public_link` returns no row for an unknown or inactive slug, so
           without this branch the page rendered blank. -->
    <div v-else-if="!link" class="card card-pad text-center">
      <AppIcon name="link" :size="28" class="mx-auto mb-3 text-stone-400" />
      <h1 class="text-xl font-semibold text-stone-900">{{ t('customer.notFound.title') }}</h1>
      <CopyText copy-key="notFound.body" tag="p" class="mt-2 text-sm text-stone-600" />
      <router-link to="/" class="btn-primary mt-6">{{ t('customer.notFound.cta') }}</router-link>
    </div>

    <template v-else>
      <h1 class="text-3xl font-bold tracking-tight text-stone-900 sm:text-4xl">
        {{ linkTitle }}
      </h1>

      <section v-if="linkTeaser" class="card card-pad mt-6">
        <MarkdownBody :source="linkTeaser" />
      </section>

      <form class="mt-8 space-y-6" @submit.prevent="createOrder">
        <section class="card card-pad">
          <h2 class="text-lg font-semibold text-stone-900">
            {{ t('customer.paywall.chooseMethod') }}
          </h2>
          <CopyText copy-key="paywall.chooseMethodHint" tag="p" class="hint mb-4" />

          <GatewaySelector
            v-if="gateways.length > 0"
            v-model:selected="selectedGatewayId"
            :gateways="gateways"
          />
          <p v-else class="empty-state">{{ t('customer.paywall.noMethods') }}</p>
        </section>

        <section v-if="selectedGateway" class="card card-pad">
          <div class="grid gap-5 sm:grid-cols-2">
            <div>
              <p class="label">{{ t('customer.paywall.sendTo') }}</p>
              <p
                class="ltr-value rounded-lg bg-stone-50 px-3 py-2.5 text-sm font-semibold text-stone-900"
              >
                {{ selectedGateway.account_number || '—' }}
              </p>
              <p v-if="selectedGateway.account_name" class="hint">
                {{ selectedGateway.account_name }}
              </p>
            </div>

            <div>
              <label class="label" for="amount">{{ t('customer.paywall.amount') }}</label>
              <input
                id="amount"
                v-model.number="amount"
                type="number"
                min="0"
                step="1"
                inputmode="decimal"
                class="field ltr-value"
                :placeholder="t('customer.paywall.amountAny')"
                :aria-describedby="amountHintId"
              />
              <p :id="amountHintId" class="hint" :class="amountError ? 'text-red-600' : ''">
                {{ amountError || amountHint }}
              </p>
            </div>
          </div>

          <div v-if="selectedGatewayInstructions" class="mt-5 border-t border-stone-100 pt-4">
            <MarkdownBody :source="selectedGatewayInstructions" />
          </div>
        </section>

        <section v-if="selectedGateway" class="card card-pad">
          <h2 class="text-sm font-semibold text-stone-900">{{ t('customer.paywall.summary') }}</h2>
          <dl class="mt-3 space-y-2 text-sm">
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('customer.paywall.summaryLink') }}</dt>
              <dd class="text-right font-medium text-stone-900">{{ linkTitle }}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-stone-500">{{ t('customer.paywall.summaryAmount') }}</dt>
              <dd class="ltr-value font-medium text-stone-900">{{ money(amount) }}</dd>
            </div>
          </dl>

          <div v-if="linkCta || ctaUrl" class="mt-5 border-t border-stone-100 pt-4">
            <CopyText
              copy-key="paywall.deliverable"
              tag="p"
              class="text-sm font-medium text-stone-700"
            />
            <p class="mt-1 text-sm text-stone-600">{{ linkCta }}</p>
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

          <button
            type="submit"
            class="btn-primary mt-6 w-full"
            :disabled="creating || !isAmountValid"
          >
            {{ creating ? t('customer.paywall.submitting') : t('customer.paywall.submit') }}
          </button>
        </section>
      </form>
    </template>
  </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute, useRouter } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import { formatMoney } from '@/lib/money'
import { useContent } from '@/composables/useContent'
import AppIcon from '@/components/AppIcon.vue'
import CopyText from '@/components/CopyText.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import GatewaySelector from '@/components/customer/GatewaySelector.vue'

const route = useRoute()
const router = useRouter()
const supabase = getSupabase()
const { pick } = useContent()
const { t } = useI18n()

interface Gateway {
  id: string
  kind: string
  name_bn: string | null
  name_en: string | null
  instructions_md_bn: string | null
  instructions_md_en: string | null
  reference_prompt_bn: string | null
  reference_prompt_en: string | null
  account_number: string | null
  account_name: string | null
  supports_reference: boolean
  evidence_fields: unknown
}

interface Link {
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
   * Already resolved for the link's override and the global default, and
   * forced to null when the minimum is hidden, so there is no second path by
   * which a client could learn it.
   */
  min_amount: number | null
  min_hidden: boolean
  gateways: Gateway[]
}

const amountHintId = 'amount-hint'

const link = ref<Link | null>(null)
const gateways = ref<Gateway[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const selectedGatewayId = ref<string | null>(null)
const amount = ref<number>(0)
const creating = ref(false)

const slug = computed(() => route.params.slug as string)

const linkTitle = computed(() =>
  link.value ? pick({ bn: link.value.title_bn, en: link.value.title_en } as any) : '',
)
const linkTeaser = computed(() =>
  link.value ? pick({ bn: link.value.teaser_md_bn, en: link.value.teaser_md_en } as any) : '',
)
const linkCta = computed(() =>
  link.value
    ? pick({ bn: link.value.unlock_cta_label_bn, en: link.value.unlock_cta_label_en } as any)
    : '',
)

const ctaUrl = computed(() => link.value?.unlock_cta_url || '')

// The unlocked body is deliberately absent from `get_public_link`; it is served
// per-order once the order is approved, so it is never rendered from this page.
const effectiveMin = computed(() => link.value?.min_amount ?? 0)

const hideMin = computed(() => link.value?.min_hidden === true)

const selectedGateway = computed(
  () => gateways.value.find((g) => g.id === selectedGatewayId.value) || null,
)

const selectedGatewayInstructions = computed(() =>
  selectedGateway.value
    ? pick({
        bn: selectedGateway.value.instructions_md_bn,
        en: selectedGateway.value.instructions_md_en,
      } as any)
    : '',
)

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
const money = (amt: number): string => formatMoney(amt, 'en')

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
    const { data: linkData, error: linkError } = await (supabase.rpc as any)('get_public_link', {
      p_slug: slug.value,
    })

    if (linkError) {
      error.value = linkError.message
      return
    }

    link.value = linkData as Link

    // `get_public_link` already returns the active payment methods nested in the
    // same payload, filtered to `is_active` server side.
    gateways.value = Array.isArray((linkData as any)?.gateways)
      ? ((linkData as any).gateways as Gateway[])
      : []

    // Preselect when there is only one choice; with several, let the customer
    // choose rather than silently charging them to one.
    const onlyGateway = gateways.value.length === 1 ? gateways.value[0] : undefined
    if (onlyGateway) {
      selectedGatewayId.value = onlyGateway.id
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load link'
  } finally {
    loading.value = false
  }
})

const createOrder = async (): Promise<void> => {
  if (!link.value || !selectedGatewayId.value || !isAmountValid.value) {
    return
  }

  creating.value = true
  error.value = null
  try {
    // Orders belong to a user, so an anonymous sign-in is the floor. Checking the
    // stored session is cheaper and safer than calling getUser(), which also
    // rejects for an expired session and would silently orphan the old user.
    const { data: sessionData } = await supabase.auth.getSession()
    if (!sessionData.session) {
      const { error: anonError } = await supabase.auth.signInAnonymously()
      if (anonError) {
        // This one is an operator problem, not a customer problem: the project
        // has anonymous sign-ins switched off, so nobody can order at all.
        error.value = anonError.message.includes('Anonymous sign-ins are disabled')
          ? 'Checkout is not available yet: anonymous sign-ins are disabled for this store.'
          : anonError.message
        return
      }
    }

    // Signature is `create_order(p_slug, p_gateway_id, p_amount)`, with the
    // amount in whole taka.
    const { data, error: createError } = await (supabase.rpc as any)('create_order', {
      p_slug: slug.value,
      p_gateway_id: selectedGatewayId.value,
      p_amount: amount.value,
    })

    if (createError) {
      error.value = createError.message
      return
    }

    // The function reports refusals in the payload rather than as an error.
    if (!data?.ok) {
      error.value = describeRefusal(data?.code)
      return
    }

    if (data.order_id) {
      router.push(`/${slug.value}/order/${data.order_id}`)
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to create order'
  } finally {
    creating.value = false
  }
}
</script>

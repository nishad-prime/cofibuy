<template>
  <main class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
    <h1 class="page-title">{{ t('customer.order.payOnlineReturnTitle') }}</h1>

    <p v-if="working" class="mt-4 text-stone-600">
      {{ t('customer.order.payOnlineReturnBody') }}
    </p>

    <!--
        Shown while the request is in flight and after it succeeds. A bKash round trip is
        two HTTP calls and most of a second, so without something here the page is a blank
        heading and the customer assumes it failed and starts again.
      -->
    <div v-if="working" class="mt-4" aria-live="polite">
      <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-stone-400" />
    </div>

    <!--
        The database's own words, shown verbatim.

        Two of these are worth reading closely. `payment_not_settled` means bKash took the
        money and the shop could not release the content - a human has to reconcile it, so
        the customer is told what happened rather than a reassuring nothing-to-see-here.
        And a sandbox refusal arrives here too, which is why `sandboxResult` exists: the
        shop ran a test method, so no money moved, and pretending otherwise would be worse
        than saying it.
      -->
    <div v-else class="mt-4 space-y-4">
      <div v-if="sandboxResult" class="alert-info">
        {{ t('customer.order.payOnlineTestDone') }}
      </div>

      <p v-if="detail" class="alert-error" role="alert">
        <span class="font-medium">{{ t('customer.order.payOnlineFailed') }}</span>
        {{ detail }}
      </p>

      <p v-else-if="failed && !sandboxResult" class="alert-error" role="alert">
        {{ t('customer.order.payOnlineFailed') }}
      </p>

      <div class="flex flex-wrap gap-3">
        <router-link v-if="slug && orderId" :to="`/${slug}/order/${orderId}`" class="btn-primary">
          {{ t('customer.order.payOnlineRetry') }}
        </router-link>
        <router-link v-if="slug" :to="`/${slug}`" class="btn-secondary">
          {{ t('customer.common.back') }}
        </router-link>
      </div>
    </div>
  </main>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { getSupabase } from '@/lib/supabase'

/**
 * The bKash return leg.
 *
 * bKash redirects here with `?paymentID=...&status=...`, and that URL is configured once in
 * the merchant dashboard - it cannot carry an order id, so this page has to find the order
 * from the payment id alone.
 *
 * `status` from the query string is never read, and that is the whole point of the design.
 * It arrives from the customer's own browser, so `status=success` proves nothing: it is a
 * value a person could type. Nothing here is decided by it. The order is settled only if
 * bKash tells the server the payment completed, which is what `bkash-execute` does by
 * calling Execute Payment with the merchant's own credentials.
 */
const route = useRoute()
const router = useRouter()
const supabase = getSupabase()
const { t } = useI18n()

const working = ref(true)
const failed = ref(false)
const detail = ref('')
const sandboxResult = ref(false)
const slug = ref<string | null>(null)
const orderId = ref<string | null>(null)

/**
 * What `bkash_payment_lookup` answers with.
 *
 * The generated type for a `jsonb`-returning function is `Json`, which is accurate and
 * useless - it cannot say which keys exist. Narrowing here rather than at each use means the
 * one unchecked cast is visible and has one place to be wrong, instead of the property
 * access being untyped at four separate call sites.
 */
interface PaymentLookup {
  ok: boolean
  order_id: string
  slug: string
  status: string
  already_settled: boolean
}

/** Reads the `detail` the Edge Function returns on failure, if there is one. */
const readError = (payload: unknown): string => {
  if (payload && typeof payload === 'object') {
    const detail = (payload as Record<string, unknown>).detail
    return typeof detail === 'string' ? detail : ''
  }
  return ''
}

onMounted(async () => {
  const paymentId = route.query.paymentID

  if (typeof paymentId !== 'string' || paymentId === '') {
    // Reached by hand. There is nothing to check, and pretending otherwise would show a
    // failure for a payment that may never have been attempted.
    working.value = false
    failed.value = true
    return
  }

  try {
    const { data, error: lookupError } = await supabase.rpc('bkash_payment_lookup', {
      p_payment_id: paymentId,
    })
    const found = data as unknown as PaymentLookup | null

    if (lookupError || !found) {
      failed.value = true
      detail.value = lookupError?.message ?? ''
      working.value = false
      return
    }

    orderId.value = found.order_id
    slug.value = found.slug

    // Already settled means the customer reloaded, or came back later. Executing a
    // payment id a second time is not a retry - bKash allows one - so this is skipped
    // rather than attempted and reported as a failure.
    if (found.already_settled) {
      working.value = false
      return
    }

    const { data: settled, error: settleError } = await supabase.functions.invoke('bkash-execute', {
      body: { orderId: found.order_id, paymentId },
    })

    if (settleError) {
      // A network failure, a cold start, or a non-JSON error from the gateway. The detail
      // is empty in that case, which is why the message above stands on its own.
      failed.value = true
      detail.value = readError(settled)
      working.value = false
      return
    }

    if (settled?.error) {
      failed.value = true
      detail.value = readError(settled)
      sandboxResult.value = settled.sandbox === true
      working.value = false
      return
    }

    sandboxResult.value = settled?.sandbox === true
    working.value = false

    // An approved order has something to show, so go straight there. A sandbox or a
    // refused payment stays put: the order page is where the reason is explained and the
    // customer can try again.
    if (settled?.status === 'approved') {
      await router.replace(`/${slug.value}/order/${orderId.value}`)
    }
  } catch {
    failed.value = true
    working.value = false
  }
})
</script>

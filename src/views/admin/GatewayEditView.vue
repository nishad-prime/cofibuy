<template>
  <div v-if="loading" class="mx-auto max-w-3xl">
    <div class="card empty-state">Loading…</div>
  </div>

  <p v-else-if="loadError" class="mx-auto max-w-3xl alert-error" role="alert">
    {{ loadError }}
  </p>

  <!-- The child forms bring their own page shell, so they are rendered bare rather than
       inside the chooser's container. `gateway-id` is the whole point of this view and
       is not optional: without it both forms read as "creating", send an empty `id`,
       and `admin_upsert_gateway` inserts a second row instead of updating the one being
       edited. -->
  <GatewayFormView v-else-if="isManual" :gateway-id="gatewayId" />

  <AutoGatewayFormView
    v-else-if="isAutomatic"
    :gateway-id="gatewayId"
    :preset-provider="presetProvider"
  />

  <!-- Creating with no mode chosen: the choice itself is two cards. The two forms are
       genuinely different screens - one collects account details and evidence, the other
       collects API credentials - so this is a link to a mode rather than a radio that
       swaps panels in place. -->
  <div v-else class="mx-auto max-w-3xl">
    <router-link to="/admin/gateways" class="btn-secondary mb-4 !px-3 !py-1.5 text-xs">
      ← Payment methods
    </router-link>

    <header class="mb-6">
      <h1 class="text-2xl font-bold tracking-tight text-stone-900">New payment method</h1>
      <p class="mt-1 text-sm text-stone-500">How do you want customers to pay you?</p>
    </header>

    <div class="grid gap-4 sm:grid-cols-2">
      <router-link
        to="/admin/gateways/new/manual"
        class="card block p-5 transition hover:border-brand-400"
      >
        <span class="block text-sm font-semibold text-stone-900">They send it, then prove it</span>
        <span class="mt-1 block text-xs text-stone-500">
          You publish an account number or IBAN, they transfer the money and send a TrxID and a
          screenshot. A staff member approves each payment. Works with any provider — bKash, Nagad,
          a bank, anything.
        </span>
      </router-link>

      <router-link
        to="/admin/gateways/new/automatic"
        class="card block p-5 transition hover:border-brand-400"
      >
        <span class="block text-sm font-semibold text-stone-900">It is taken automatically</span>
        <span class="mt-1 block text-xs text-stone-500">
          The customer presses Pay and is handed to the provider, which collects the money and
          confirms the payment. The order then approves itself with no staff member involved. Needs
          API credentials.
        </span>
      </router-link>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import GatewayFormView from '@/views/admin/GatewayFormView.vue'
import AutoGatewayFormView from '@/views/admin/AutoGatewayFormView.vue'

/**
 * The one column needed to decide which form to render. The full row is deliberately not
 * read here: the child forms load it themselves, and reading a row only to test `provider`
 * nullness would pull every evidence field and account field into memory a second time.
 */
interface Gateway {
  id: string
  provider: string | null
}

const route = useRoute()
const supabase = getSupabase()

const gatewayId = computed(() => (route.params.id as string | undefined) ?? '')
const mode = computed(() => (route.params.mode as string | undefined) ?? '')

const gateway = ref<Gateway | null>(null)
// A plain ref rather than a computed: the edit load has three end states, and deriving
// "loading" from `gateway === null` cannot tell "still fetching" from "the id was bogus".
const loading = ref(false)
const loadError = ref<string | null>(null)

/** Editing picks the form from the stored provider; creating picks it from the URL. */
const isManual = computed(() =>
  gatewayId.value ? !gateway.value?.provider : mode.value === 'manual',
)
const isAutomatic = computed(() =>
  gatewayId.value ? !!gateway.value?.provider : mode.value === 'automatic',
)
const presetProvider = computed(() => gateway.value?.provider ?? undefined)

onMounted(async () => {
  if (!gatewayId.value) return

  loading.value = true
  const { data, error: rpcError } = await supabase.rpc('admin_gateways')
  if (rpcError) {
    loadError.value = rpcError.message
    loading.value = false
    return
  }

  const row = (data ?? []).find((r: { id: string }) => r.id === gatewayId.value) as
    Gateway | undefined
  if (!row) {
    loadError.value = 'That payment method no longer exists.'
    loading.value = false
    return
  }
  gateway.value = row
  loading.value = false
})
</script>

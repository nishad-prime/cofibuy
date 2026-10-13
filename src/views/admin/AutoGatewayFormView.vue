<template>
  <div class="mx-auto max-w-3xl">
    <router-link to="/admin/gateways" class="btn-secondary mb-4 !px-3 !py-1.5 text-xs">
      ← Payment methods
    </router-link>

    <header class="mb-6">
      <h1 class="text-2xl font-bold tracking-tight text-stone-900">
        {{ isEdit ? 'Edit automatic method' : 'New automatic method' }}
      </h1>
      <p class="mt-1 text-sm text-stone-500">
        The customer presses Pay and is handed to the provider. When the provider confirms the
        payment, the order approves itself — no screenshot, no TrxID, no staff member in the loop.
      </p>
    </header>

    <div v-if="loadingRegistry" class="card empty-state">Loading providers…</div>

    <p v-else-if="registryError" class="alert-error" role="alert">{{ registryError }}</p>

    <form v-else class="space-y-4" @submit.prevent="save">
      <CollapsibleSection
        panel-id="provider"
        title="Provider"
        :open="openSection === 'provider'"
        :has-error="!!error && !provider"
        @update:open="toggleSection('provider')"
      >
        <fieldset class="space-y-3">
          <legend class="sr-only">Provider</legend>

          <label
            v-for="option in providers"
            :key="option.slug"
            class="flex cursor-pointer items-start gap-3 rounded-lg border p-4"
            :class="
              form.provider === option.slug ? 'border-brand-400 bg-brand-50/40' : 'border-stone-200'
            "
          >
            <input
              v-model="form.provider"
              type="radio"
              :value="option.slug"
              class="mt-1"
              @change="onProviderChange"
            />
            <span>
              <span class="block text-sm font-medium text-stone-800">
                {{ option.name_en || option.slug }}
              </span>
              <span v-if="option.name_bn" class="block text-xs text-stone-500" lang="bn">
                {{ option.name_bn }}
              </span>
              <span class="mt-1 block text-xs text-stone-500">
                {{ option.fields.length }} credential{{ option.fields.length === 1 ? '' : 's' }}
              </span>
            </span>
          </label>
        </fieldset>
      </CollapsibleSection>

      <CollapsibleSection
        panel-id="environment"
        title="Which bKash do these credentials belong to?"
        :open="openSection === 'environment'"
        @update:open="toggleSection('environment')"
      >
        <fieldset class="space-y-3">
          <legend class="sr-only">Environment</legend>

          <label
            class="flex cursor-pointer items-start gap-3 rounded-lg border p-4"
            :class="
              form.environment === 'sandbox'
                ? 'border-brand-400 bg-brand-50/40'
                : 'border-stone-200'
            "
          >
            <input v-model="form.environment" type="radio" value="sandbox" class="mt-1" />
            <span>
              <span class="block text-sm font-medium text-stone-800">Sandbox (testing)</span>
              <span class="block text-xs text-stone-500">
                Test money. No real customer is ever charged.
              </span>
            </span>
          </label>

          <label
            class="flex cursor-pointer items-start gap-3 rounded-lg border p-4"
            :class="
              form.environment === 'live' ? 'border-brand-400 bg-brand-50/40' : 'border-stone-200'
            "
          >
            <input v-model="form.environment" type="radio" value="live" class="mt-1" />
            <span>
              <span class="block text-sm font-medium text-stone-800">Live (production)</span>
              <span class="block text-xs text-stone-500">
                Real money, from the merchant account these credentials belong to.
              </span>
            </span>
          </label>
        </fieldset>

        <div
          v-if="form.environment === 'sandbox'"
          class="mt-4 rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900"
        >
          <p class="font-medium">A sandbox method will never hand out the content.</p>
          <p class="mt-1 text-xs">
            Sandbox payments run all the way through bKash and can be watched, but settlement is
            refused for a sandbox gateway — so no order is ever approved and no download access is
            ever granted. That is deliberate: it makes a sandbox configuration impossible to mistake
            for a working one. Use it to prove the flow, then switch this method to live with real
            merchant credentials before taking money.
          </p>
        </div>

        <div
          v-else
          class="mt-4 rounded-lg border border-red-300 bg-red-50 p-4 text-sm text-red-900"
        >
          <p class="font-medium">Live credentials charge real money and grant real access.</p>
          <p class="mt-1 text-xs">
            Save live merchant credentials here and the confirmation step runs against the live
            provider. If these credentials are the public bKash sandbox set, nothing will ever
            settle — the credentials and this setting have to agree.
          </p>
        </div>
      </CollapsibleSection>

      <CollapsibleSection
        panel-id="credentials"
        title="API credentials"
        :open="openSection === 'credentials'"
        :has-error="!!error && !credentialsComplete"
        :note="credentialDraftCount ? `${credentialDraftCount} to update` : undefined"
        @update:open="toggleSection('credentials')"
      >
        <CredentialFieldEditor
          v-if="provider"
          v-model="credentialDraft"
          :fields="provider.fields"
          :has-stored="hasStoredCredentials"
        />
        <p v-else class="text-sm text-stone-500">Choose a provider above first.</p>
      </CollapsibleSection>

      <CollapsibleSection
        panel-id="basics"
        title="Basics"
        :open="openSection === 'basics'"
        @update:open="toggleSection('basics')"
      >
        <div class="grid gap-4 sm:grid-cols-2">
          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Kind *</span>
            <input v-model="form.kind" required maxlength="48" class="field" lang="en" />
            <span class="mt-1 block text-xs text-stone-500">
              How this method appears to customers, e.g. bKash. This also selects it at checkout.
            </span>
          </label>

          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Weight</span>
            <input v-model.number="form.weight" type="number" min="1" step="1" class="field" />
            <span class="mt-1 block text-xs text-stone-500">
              How much of this kind's traffic this account takes, in proportion. 1 is an even share.
              Only matters when a kind has more than one account, and it is decided by the database
              at order time - not by the customer.
            </span>
          </label>

          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Sort order</span>
            <input v-model.number="form.sort_order" type="number" class="field" />
            <span class="mt-1 block text-xs text-stone-500">Lower numbers appear first.</span>
          </label>

          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Name (EN) *</span>
            <input v-model="form.name_en" required class="field" />
          </label>

          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Name (BN)</span>
            <input v-model="form.name_bn" class="field" lang="bn" />
          </label>
        </div>

        <label class="mt-4 flex items-start gap-2">
          <input v-model="form.is_active" type="checkbox" class="mt-0.5 rounded border-stone-300" />
          <span>
            <span class="block text-sm font-medium text-stone-800">Active</span>
            <span class="block text-xs text-stone-500">
              Inactive methods stay saved but disappear from every customer checkout.
            </span>
          </span>
        </label>
      </CollapsibleSection>

      <CollapsibleSection
        panel-id="region"
        title="Country & banners"
        :open="openSection === 'region'"
        @update:open="toggleSection('region')"
      >
        <GatewayRegionBanners
          v-model:country="form.country"
          v-model:primary="form.is_primary_for_country"
          v-model:banner-url="form.banner_url"
          v-model:banner-small-url="form.banner_small_url"
          :gateway-id="gatewayId"
        />
      </CollapsibleSection>

      <div v-if="error" class="card border-red-200 bg-red-50 p-4 text-sm text-red-800">
        {{ error }}
      </div>

      <div class="flex items-center gap-3">
        <button type="submit" class="btn-primary" :disabled="saving">
          {{ saving ? 'Saving…' : 'Save automatic method' }}
        </button>
        <router-link to="/admin/gateways" class="btn-secondary">Cancel</router-link>
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import CollapsibleSection from '@/components/admin/CollapsibleSection.vue'
import CredentialFieldEditor, {
  type ProviderField,
} from '@/components/admin/CredentialFieldEditor.vue'
import GatewayRegionBanners from '@/components/admin/GatewayRegionBanners.vue'

/** A row of `api.admin_auto_providers()`. */
interface AutoProvider {
  slug: string
  name_en: string | null
  name_bn: string | null
  fields: ProviderField[]
}

interface Gateway {
  id: string
  kind: string
  provider: string | null
  name_en: string | null
  name_bn: string | null
  environment: 'sandbox' | 'live' | null
  is_active: boolean
  sort_order: number | null
  country: string | null
  is_primary_for_country: boolean
  banner_url: string | null
  banner_small_url: string | null
  weight: number | null
}

const props = defineProps<{
  gatewayId?: string
  /** Pre-selects a provider for a new gateway, e.g. `bkash_pgw`. */
  presetProvider?: string
}>()

const router = useRouter()
const supabase = getSupabase()

const isEdit = computed(() => !!props.gatewayId)

const providers = ref<AutoProvider[]>([])
const loadingRegistry = ref(true)
const registryError = ref<string | null>(null)

const openSection = ref<string | null>('provider')
const saving = ref(false)
const error = ref<string | null>(null)
const hasStoredCredentials = ref(false)

const form = ref({
  provider: '' as string,
  kind: 'bkash',
  name_en: '',
  name_bn: '',
  environment: 'sandbox' as 'sandbox' | 'live',
  is_active: true,
  sort_order: 0,
  weight: 1,
  country: '' as string | null,
  is_primary_for_country: false,
  banner_url: null as string | null,
  banner_small_url: null as string | null,
})

/**
 * Only the credential keys this screen has been given. Sparse on purpose - see
 * `CredentialFieldEditor`: a missing key means "leave the stored value alone", and an empty
 * object therefore means "change no credentials", which is what `store_credential_bundle`
 * does with `{}`.
 */
const credentialDraft = ref<Record<string, string>>({})

const provider = computed(() => providers.value.find((p) => p.slug === form.value.provider) ?? null)

const credentialDraftCount = computed(() => Object.keys(credentialDraft.value).length)

/**
 * Whether this save would leave the gateway with a complete credential set. False means the
 * gateway has never had credentials, because a partial re-entry is merged over the stored
 * bundle rather than replacing it.
 */
const credentialsComplete = computed(
  () => hasStoredCredentials.value || credentialDraftCount.value > 0,
)

const SECTIONS = ['provider', 'environment', 'credentials', 'basics'] as const

function toggleSection(id: string): void {
  openSection.value = openSection.value === id ? null : id
}

function ensureOpenSectionExists(): void {
  if (!openSection.value || !SECTIONS.includes(openSection.value as never)) {
    openSection.value = 'provider'
  }
}

/**
 * Credentials belong to a provider, so switching provider discards them. Keeping the old
 * keys would merge one provider's secrets into another's bundle, and the stored bundle is
 * never readable from here to check what it would end up as.
 */
function onProviderChange(): void {
  credentialDraft.value = {}
  hasStoredCredentials.value = false
  ensureOpenSectionExists()
}

onMounted(async () => {
  const { data, error: rpcError } = await supabase.rpc('admin_auto_providers')
  if (rpcError) {
    registryError.value = rpcError.message
    loadingRegistry.value = false
    return
  }
  providers.value = (data ?? []) as unknown as AutoProvider[]
  loadingRegistry.value = false

  if (isEdit.value) {
    const { data: rows } = await supabase.rpc('admin_gateways')
    const gateway = ((rows ?? []) as unknown as Gateway[]).find((row) => row.id === props.gatewayId)
    if (!gateway) {
      error.value = 'That payment method no longer exists.'
      return
    }
    form.value = {
      provider: gateway.provider ?? '',
      kind: gateway.kind,
      name_en: gateway.name_en ?? '',
      name_bn: gateway.name_bn ?? '',
      environment: gateway.environment ?? 'sandbox',
      is_active: gateway.is_active,
      sort_order: gateway.sort_order ?? 0,
      weight: gateway.weight ?? 1,
      country: gateway.country ?? '',
      is_primary_for_country: gateway.is_primary_for_country,
      banner_url: gateway.banner_url,
      banner_small_url: gateway.banner_small_url,
    }
    const { data: stored } = await supabase.rpc('admin_gateway_has_credentials', {
      //  above is exactly the presence of this id.
      p_gateway_id: props.gatewayId as string,
    })
    hasStoredCredentials.value = !!stored
    ensureOpenSectionExists()
    return
  }

  // A new automatic method with a provider named in the query lands on that provider and
  // opens its credentials; otherwise the first registered provider is preselected and the
  // operator is shown the choice rather than an empty panel.
  const initial = props.presetProvider ?? providers.value[0]?.slug ?? ''
  form.value.provider = initial
  if (initial) openSection.value = 'credentials'
})

const save = async (): Promise<void> => {
  if (!form.value.provider) {
    error.value = 'Choose a provider.'
    openSection.value = 'provider'
    return
  }

  saving.value = true
  error.value = null

  try {
    // Sent as an empty object rather than omitted when nothing was re-entered: the
    // database reads an absent or null `credential_bundle` as "unchanged" and an empty
    // object the same way, so either is safe, and being explicit keeps the payload shape
    // identical to the manual form's.
    //
    // `account_fields` and `evidence_fields` are empty arrays, not null. An automatic
    // gateway collects its own money, so there is nowhere to send it and nothing to review,
    // and the database rejects a row carrying both a provider and those forms.
    const { error: rpcError } = await supabase.rpc('admin_upsert_gateway', {
      p_gateway: {
        id: props.gatewayId ?? '',
        kind: form.value.kind.trim(),
        provider: form.value.provider,
        environment: form.value.environment,
        name_en: form.value.name_en,
        name_bn: form.value.name_bn || null,
        instructions_md_en: null,
        instructions_md_bn: null,
        reference_prompt_en: null,
        reference_prompt_bn: null,
        supports_reference: false,
        is_active: form.value.is_active,
        sort_order: form.value.sort_order ?? 0,
        weight: form.value.weight ?? 1,
        country: form.value.country || null,
        is_primary_for_country: form.value.is_primary_for_country,
        banner_url: form.value.banner_url,
        banner_small_url: form.value.banner_small_url,
        evidence_fields: [],
        account_fields: [],
        credential_bundle: credentialDraft.value,
      },
    })

    if (rpcError) {
      error.value = rpcError.message
      // A credential rejection names the offending field, so open the panel that owns it.
      if (!credentialsComplete.value || /credential/i.test(rpcError.message)) {
        openSection.value = 'credentials'
      }
      return
    }

    router.push('/admin/gateways')
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to save'
  } finally {
    saving.value = false
  }
}
</script>

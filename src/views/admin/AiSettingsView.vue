<template>
  <div class="mx-auto max-w-3xl">
    <header class="mb-6">
      <h1 class="page-title">AI provider</h1>
      <p class="page-subtitle">
        Point the shop at a model provider and store its credential once. Everything that drafts
        copy — briefs, field rewrites, the blurbs staff paste into the shopfront — reads this one
        setting, so there is a single place to rotate a key or turn the feature off.
      </p>
    </header>

    <div v-if="loading" class="card empty-state">Loading provider…</div>

    <p v-else-if="loadError" class="alert-error" role="alert">{{ loadError }}</p>

    <p v-else-if="!providers.length" class="card empty-state">
      No AI provider is registered, so there is nothing to configure. A provider row is what the
      form renders its fields from, so this page stays empty until one exists.
    </p>

    <form v-else class="space-y-4" @submit.prevent="save">
      <div
        v-if="providerChanged"
        class="rounded-lg border border-brand-300 bg-brand-50 p-4 text-sm text-brand-900"
      >
        <p class="font-medium">
          Save {{ provider?.name_en || form.provider }} with all of its credentials filled in.
        </p>
        <p class="mt-1 text-xs">
          Switching providers cannot be a partial save. A credential belongs to the provider that
          issued it, so the new provider's key arrives here rather than being merged with what the
          old one left behind. Every field is required for this one save.
        </p>
      </div>

      <div
        v-if="provider && !provider.is_active"
        class="rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900"
      >
        <p class="font-medium">{{ provider.name_en || provider.slug }} is switched off.</p>
        <p class="mt-1 text-xs">
          An inactive provider is not a legal choice — the database refuses to save one — and the
          stored credential is spent against nothing. Reactivate it, or pick another.
        </p>
      </div>

      <CollapsibleSection
        panel-id="provider"
        title="Provider"
        :open="openSection === 'provider'"
        :has-error="!!error"
        @update:open="toggleSection('provider')"
      >
        <fieldset class="space-y-3">
          <legend class="sr-only">Provider</legend>

          <label
            v-for="option in providers"
            :key="option.slug"
            class="flex items-start gap-3 rounded-lg border p-4"
            :class="[
              form.provider === option.slug
                ? 'border-brand-400 bg-brand-50/40'
                : 'border-stone-200',
              !option.is_active ? 'opacity-60' : 'cursor-pointer',
            ]"
          >
            <input
              v-model="form.provider"
              type="radio"
              :value="option.slug"
              :disabled="!option.is_active"
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
                <template v-if="!option.is_active"> · inactive</template>
              </span>
            </span>
          </label>
        </fieldset>

        <label class="mt-4 flex items-start gap-2">
          <input
            :checked="turningOff"
            type="checkbox"
            class="mt-0.5 rounded border-stone-300"
            @change="onToggleOff"
          />
          <span>
            <span class="block text-sm font-medium text-stone-800">Turn AI copy off</span>
            <span class="block text-xs text-stone-500">
              Clears the provider and retires the stored credential. Drafting stops; nothing already
              generated changes.
            </span>
          </span>
        </label>
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
          v-if="form.provider"
          v-model="credentialDraft"
          :fields="provider?.fields ?? []"
          :has-stored="hasStoredCredentials && !providerChanged"
        />
        <p v-else class="text-sm text-stone-500">Choose a provider above, or turn AI copy off.</p>

        <p
          v-if="providerChanged"
          class="mt-4 rounded-lg border border-amber-300 bg-amber-50 p-3 text-xs text-amber-900"
        >
          Every field is required for a provider switch. The boxes are empty because the stored
          values belong to {{ storedProviderName }}.
        </p>
      </CollapsibleSection>

      <div v-if="error" class="card border-red-200 bg-red-50 p-4 text-sm text-red-800">
        {{ error }}
      </div>

      <div class="flex items-center gap-3">
        <button type="submit" class="btn-primary" :disabled="saving">
          {{ buttonLabel }}
        </button>
        <router-link to="/admin" class="btn-secondary">Back</router-link>
      </div>
    </form>

    <p v-if="!loading && !loadError && hasStoredCredentials" class="mt-6 text-xs text-stone-500">
      A credential is stored. It is never sent back to this page, and it is only ever readable by
      the function that spends it.
    </p>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { getSupabase } from '@/lib/supabase'
import CollapsibleSection from '@/components/admin/CollapsibleSection.vue'
import CredentialFieldEditor, {
  type ProviderField,
} from '@/components/admin/CredentialFieldEditor.vue'

/** A row of `api.admin_ai_providers()`. */
interface AiProvider {
  slug: string
  name_en: string | null
  name_bn: string | null
  fields: ProviderField[]
  is_active: boolean
}

const supabase = getSupabase()

const providers = ref<AiProvider[]>([])
const loading = ref(true)
const loadError = ref<string | null>(null)

const openSection = ref<string | null>('credentials')
const saving = ref(false)
const error = ref<string | null>(null)
const hasStoredCredentials = ref(false)
const turningOff = ref(false)

/**
 * Which provider the stored credential belongs to. Tracked separately from the radio group
 * because the two genuinely differ mid-edit: picking a different provider does not move the
 * stored credential, only saving does.
 */
const storedProvider = ref<string | null>(null)
const form = ref({ provider: '' as string })

/**
 * Only the credential keys re-entered on this screen. Sparse on purpose, exactly as in the
 * gateway form: a key that is absent means "leave the stored value alone", and an empty object
 * means "change no credentials".
 */
const credentialDraft = ref<Record<string, string>>({})

const provider = computed(() => providers.value.find((p) => p.slug === form.value.provider) ?? null)

const credentialDraftCount = computed(() => Object.keys(credentialDraft.value).length)

/** True when the provider on screen is not the one the stored credential belongs to. */
const providerChanged = computed(
  () =>
    !!storedProvider.value && !!form.value.provider && form.value.provider !== storedProvider.value,
)

/**
 * Whether a failed save could be about the credential fields rather than the provider choice.
 * That is what decides whether the credentials panel is flagged, and it keeps the gateway form's
 * rule: a shop that has never saved a credential is the only one where an empty draft is
 * incomplete.
 */
const credentialsComplete = computed(
  () => hasStoredCredentials.value || credentialDraftCount.value > 0,
)

/**
 * What the button does, stated by the button. The checkbox above is a mode rather than an action,
 * so the destructive call has to be something the operator can actually land.
 */
const buttonLabel = computed(() => {
  if (saving.value) return turningOff.value ? 'Turning off…' : 'Saving…'
  return turningOff.value ? 'Turn AI copy off' : 'Save AI provider'
})

const storedProviderName = computed(() => {
  const stored = providers.value.find((p) => p.slug === storedProvider.value)
  return stored?.name_en ?? storedProvider.value ?? 'the previous provider'
})

function toggleSection(id: string): void {
  openSection.value = openSection.value === id ? null : id
}

/**
 * Credentials belong to a provider, so a switch discards the boxes rather than merging one
 * provider's key into another's bundle. The stored credential is untouched here — turning AI copy
 * off is what retires it — but the form must not offer it as a starting point, because the
 * database refuses a switch that does not carry the new provider's fields in full.
 */
function onProviderChange(): void {
  credentialDraft.value = {}
  error.value = null
  openSection.value = 'credentials'
}

function onToggleOff(event: Event): void {
  turningOff.value = (event.target as HTMLInputElement).checked
  error.value = null
  if (turningOff.value) {
    credentialDraft.value = {}
    openSection.value = 'provider'
  }
}

onMounted(async () => {
  const { data, error: rpcError } = await supabase.rpc('admin_ai_providers')
  if (rpcError) {
    loadError.value = rpcError.message
    loading.value = false
    return
  }
  providers.value = (data ?? []) as unknown as AiProvider[]

  const { data: settings, error: settingsError } = await supabase.rpc('admin_ai_settings')
  if (settingsError) {
    loadError.value = settingsError.message
    loading.value = false
    return
  }

  const row = (settings ?? [])[0] as
    { provider: string | null; has_credentials: boolean } | undefined
  form.value.provider = row?.provider ?? ''
  storedProvider.value = row?.provider ?? null
  hasStoredCredentials.value = !!row?.has_credentials
  loading.value = false
})

const save = async (): Promise<void> => {
  if (turningOff.value) {
    await clearProvider()
    return
  }

  if (!form.value.provider) {
    error.value = 'Choose a provider.'
    openSection.value = 'provider'
    return
  }

  saving.value = true
  error.value = null

  try {
    // An empty object rather than an omitted key when nothing was re-entered: the database reads
    // both as "change no credentials", and being explicit keeps one payload shape.
    const { error: rpcError } = await supabase.rpc('admin_upsert_ai_settings', {
      p_settings: {
        provider: form.value.provider,
        credential_bundle: credentialDraft.value,
      },
    })

    if (rpcError) {
      error.value = rpcError.message
      // Both rejection shapes name a field or a provider, so the panel that owns the problem is
      // the one worth opening.
      if (/credential|provider/i.test(rpcError.message)) openSection.value = 'credentials'
      return
    }

    storedProvider.value = form.value.provider
    hasStoredCredentials.value = true
    credentialDraft.value = {}
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to save'
  } finally {
    saving.value = false
  }
}

/**
 * Clearing retires the credential rather than leaving it in the vault with nothing pointing at
 * it, so it is a call of its own rather than a save with an empty payload: there is no provider
 * to merge anything into.
 */
const clearProvider = async (): Promise<void> => {
  saving.value = true
  error.value = null

  try {
    const { error: rpcError } = await supabase.rpc('admin_upsert_ai_settings', {
      p_settings: { provider: null },
    })

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    turningOff.value = false
    form.value.provider = ''
    storedProvider.value = null
    hasStoredCredentials.value = false
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to save'
  } finally {
    saving.value = false
  }
}
</script>

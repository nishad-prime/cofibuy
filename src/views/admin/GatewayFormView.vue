<template>
  <div class="mx-auto max-w-3xl">
    <router-link to="/admin/gateways" class="btn-secondary mb-4 !px-3 !py-1.5 text-xs">
      ← Payment methods
    </router-link>

    <header class="mb-6">
      <h1 class="text-2xl font-bold tracking-tight text-stone-900">
        {{ isEdit ? 'Edit payment method' : 'New payment method' }}
      </h1>
      <p class="mt-1 text-sm text-stone-500">
        You give the customer the account details below and they send you proof. A staff member
        approves each payment by hand.
      </p>
    </header>

    <form class="space-y-4" @submit.prevent="save">
      <CollapsibleSection
        panel-id="basics"
        title="Basics"
        :open="openSection === 'basics'"
        @update:open="toggleSection('basics')"
      >
        <div class="grid gap-4 sm:grid-cols-2">
          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Kind *</span>
            <input
              v-model="form.kind"
              required
              maxlength="48"
              class="field"
              placeholder="bKash, bank, CellFin, Rocket…"
              list="gateway-kind-suggestions"
            />
            <datalist id="gateway-kind-suggestions">
              <option
                v-for="suggestion in KIND_SUGGESTIONS"
                :key="suggestion"
                :value="suggestion"
              />
            </datalist>
            <span class="mt-1 block text-xs text-stone-500">
              Any name you like. Only a label — nothing in the system branches on it.
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
        panel-id="accounts"
        title="Account details"
        :open="openSection === 'accounts'"
        :has-error="hasAccountProblems"
        :note="accountFields.length ? String(accountFields.length) : undefined"
        @update:open="toggleSection('accounts')"
      >
        <AccountFieldEditor ref="accountEditor" v-model="accountFields" />
      </CollapsibleSection>

      <CollapsibleSection
        panel-id="instructions"
        title="Customer instructions"
        :open="openSection === 'instructions'"
        @update:open="toggleSection('instructions')"
      >
        <div class="grid gap-4 sm:grid-cols-2">
          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Instructions (EN)</span>
            <textarea v-model="form.instructions_en" rows="3" class="field" />
          </label>
          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Instructions (BN)</span>
            <textarea v-model="form.instructions_bn" rows="3" class="field" lang="bn" />
          </label>
          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Reference prompt (EN)</span>
            <input v-model="form.reference_prompt_en" class="field" />
          </label>
          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Reference prompt (BN)</span>
            <input v-model="form.reference_prompt_bn" class="field" lang="bn" />
          </label>
        </div>

        <p class="mt-3 text-xs text-stone-500">
          Markdown is supported in the instruction boxes. The reference prompt is the short line
          shown next to the amount field.
        </p>

        <label class="mt-4 flex items-start gap-2">
          <input
            v-model="form.supports_reference"
            type="checkbox"
            class="mt-0.5 rounded border-stone-300"
          />
          <span>
            <span class="block text-sm font-medium text-stone-800">Ask for a reference</span>
            <span class="block text-xs text-stone-500">
              Adds a reference box to checkout, for methods that need one.
            </span>
          </span>
        </label>
      </CollapsibleSection>

      <CollapsibleSection
        panel-id="evidence"
        title="Evidence fields"
        :open="openSection === 'evidence'"
        :has-error="hasEvidenceProblems"
        :note="fields.length ? String(fields.length) : undefined"
        @update:open="toggleSection('evidence')"
      >
        <EvidenceFieldEditor ref="editor" v-model="fields" />
      </CollapsibleSection>

      <div v-if="error" class="card border-red-200 bg-red-50 p-4 text-sm text-red-800">
        {{ error }}
      </div>

      <div class="flex items-center gap-3">
        <button type="submit" class="btn-primary" :disabled="saving">
          {{ saving ? 'Saving…' : 'Save payment method' }}
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
import EvidenceFieldEditor, { type FieldDraft } from '@/components/admin/EvidenceFieldEditor.vue'
import AccountFieldEditor, { type AccountDraft } from '@/components/admin/AccountFieldEditor.vue'
import CollapsibleSection from '@/components/admin/CollapsibleSection.vue'

/**
 * The row `admin_gateways` returns. Named `Gateway` rather than shared with the automatic
 * form: the two views read disjoint halves of this row, and a single interface covering
 * both would let the manual form reach for `environment` and `credential_bundle`, which
 * are meaningless without a provider.
 */
interface Gateway {
  id: string
  kind: string
  name_en: string | null
  name_bn: string | null
  account_fields: Partial<AccountDraft>[] | null
  instructions_md_en: string | null
  instructions_md_bn: string | null
  reference_prompt_en: string | null
  reference_prompt_bn: string | null
  supports_reference: boolean
  is_active: boolean
  sort_order: number
  weight: number | null
  evidence_fields: Partial<FieldDraft>[] | null
}

const props = defineProps<{
  /** Absent when creating. The dispatcher view resolves this from the route. */
  gatewayId?: string
}>()

// Suggestions, not a closed list. They exist so the common methods are one keystroke
// away and so an operator sees the existing naming convention, but the field takes
// anything - CellFin and Rocket are as valid as bKash.
const KIND_SUGGESTIONS = ['bkash', 'nagad', 'bank', 'rocket', 'cellfin']

const router = useRouter()
const supabase = getSupabase()

const isEdit = computed(() => !!props.gatewayId)

const fields = ref<FieldDraft[]>([])
const accountFields = ref<AccountDraft[]>([])
const editor = ref<InstanceType<typeof EvidenceFieldEditor> | null>(null)
const accountEditor = ref<InstanceType<typeof AccountFieldEditor> | null>(null)
const saving = ref(false)
const error = ref<string | null>(null)

const form = ref({
  kind: 'bkash',
  name_en: '',
  name_bn: '',
  instructions_en: '',
  instructions_bn: '',
  reference_prompt_en: '',
  reference_prompt_bn: '',
  supports_reference: false,
  is_active: true,
  sort_order: 0,
  weight: 1,
})

/**
 * Which panel is open. One id rather than a boolean per panel, because the rule the
 * form needs is "one at a time", and a set of independent booleans cannot express that
 * without every panel agreeing about the others.
 *
 * Every panel in `MANUAL_SECTIONS` is unconditionally rendered here - the automatic
 * half of this screen lives in `AutoGatewayFormView`, so there is no longer a mode
 * switch that can leave the open id naming a panel that is not on the page.
 */
const openSection = ref<string | null>('basics')

const MANUAL_SECTIONS = ['basics', 'accounts', 'instructions', 'evidence'] as const

function toggleSection(id: string): void {
  openSection.value = openSection.value === id ? null : id
}

/** Keep the open id pointing at a panel that is actually rendered. */
function ensureOpenSectionExists(): void {
  if (!openSection.value || !MANUAL_SECTIONS.includes(openSection.value as never)) {
    openSection.value = 'basics'
  }
}

const hasAccountProblems = computed(
  () => (accountEditor.value?.problems ?? []).some(Boolean) || false,
)
const hasEvidenceProblems = computed(() => (editor.value?.problems ?? []).some(Boolean) || false)

const isValid = computed(() => !hasAccountProblems.value && !hasEvidenceProblems.value)

const toDraft = (raw: Partial<FieldDraft>): FieldDraft => ({
  key: raw.key ?? '',
  type: (raw.type ?? 'text') as FieldDraft['type'],
  label_en: raw.label_en ?? '',
  label_bn: raw.label_bn ?? '',
  required: raw.required ?? false,
  validate: (raw.validate ?? '') as FieldDraft['validate'],
  // The database requires these for their type, so fall back to a legal value
  // rather than letting an incomplete draft fail the whole save.
  max_len: raw.max_len ?? (raw.type === 'image' ? null : 64),
  max_mb: raw.max_mb ?? (raw.type === 'image' ? 4 : null),
  keyLocked: true,
})

const toAccountDraft = (raw: Partial<AccountDraft>): AccountDraft => ({
  key: raw.key ?? '',
  label_en: raw.label_en ?? '',
  label_bn: raw.label_bn ?? '',
  value: raw.value ?? '',
  keyLocked: true,
})

onMounted(async () => {
  if (!isEdit.value) return

  const { data } = await (supabase.rpc as any)('admin_gateways')
  const gateway: Gateway | undefined = (data || []).find(
    (row: { id: string }) => row.id === props.gatewayId,
  )
  if (!gateway) {
    error.value = 'That payment method no longer exists.'
    return
  }

  // Row columns and form fields are named differently, so map them explicitly
  // instead of merging the row wholesale.
  form.value = {
    kind: gateway.kind,
    name_en: gateway.name_en ?? '',
    name_bn: gateway.name_bn ?? '',
    instructions_en: gateway.instructions_md_en ?? '',
    instructions_bn: gateway.instructions_md_bn ?? '',
    reference_prompt_en: gateway.reference_prompt_en ?? '',
    reference_prompt_bn: gateway.reference_prompt_bn ?? '',
    supports_reference: gateway.supports_reference,
    is_active: gateway.is_active,
    sort_order: gateway.sort_order ?? 0,
    weight: gateway.weight ?? 1,
  }
  fields.value = (gateway.evidence_fields ?? []).map(toDraft)
  accountFields.value = (gateway.account_fields ?? []).map(toAccountDraft)
  ensureOpenSectionExists()
})

const save = async (): Promise<void> => {
  // An invalid field is reported inline by the editor that owns it, so opening that
  // panel is the whole error message. Silently refusing to save would leave a dead
  // button and no explanation, which is worse than the previous behaviour of disabling
  // the button outright.
  if (!isValid.value) {
    if (hasAccountProblems.value) openSection.value = 'accounts'
    else if (hasEvidenceProblems.value) openSection.value = 'evidence'
    return
  }

  saving.value = true
  error.value = null

  try {
    // `api.admin_upsert_gateway` takes one jsonb argument, and these keys must
    // match the names the function reads out of it. Dropping any of them resets
    // that column, so the payload is built explicitly rather than by spreading.
    //
    // `provider` is sent as an explicit null rather than omitted: this view edits
    // manual methods only, and the database rejects a row carrying both a provider
    // and account or evidence fields. `credential_bundle` is deliberately absent -
    // a manual gateway has no credentials, and an empty bundle would be a blank
    // field rather than "unchanged".
    const { error: rpcError } = await (supabase.rpc as any)('admin_upsert_gateway', {
      p_gateway: {
        id: props.gatewayId ?? '',
        kind: form.value.kind.trim(),
        provider: null,
        name_en: form.value.name_en,
        name_bn: form.value.name_bn || null,
        instructions_md_en: form.value.instructions_en || null,
        instructions_md_bn: form.value.instructions_bn || null,
        reference_prompt_en: form.value.reference_prompt_en || null,
        reference_prompt_bn: form.value.reference_prompt_bn || null,
        supports_reference: form.value.supports_reference,
        is_active: form.value.is_active,
        sort_order: form.value.sort_order ?? 0,
        weight: form.value.weight ?? 1,
        evidence_fields: editor.value?.payload ?? [],
        account_fields: accountEditor.value?.payload ?? [],
      },
    })

    if (rpcError) {
      error.value = rpcError.message
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

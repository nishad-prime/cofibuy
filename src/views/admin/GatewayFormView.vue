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
        The account customers send money to, and the proof they have to send back.
      </p>
    </header>

    <form class="space-y-6" @submit.prevent="save">
      <section class="card space-y-5 p-6">
        <h2 class="text-sm font-semibold tracking-wide text-stone-500 uppercase">Basics</h2>

        <div class="grid gap-4 sm:grid-cols-2">
          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Kind *</span>
            <select v-model="form.kind" required class="field">
              <option v-for="option in KINDS" :key="option.value" :value="option.value">
                {{ option.label }}
              </option>
            </select>
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

          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Account number</span>
            <input v-model="form.account_number" class="field ltr-value" />
            <span class="mt-1 block text-xs text-stone-500">
              Shown to the customer. Latin digits, both locales.
            </span>
          </label>

          <label class="block">
            <span class="mb-1 block text-sm font-medium text-stone-700">Account name</span>
            <input v-model="form.account_name" class="field" />
          </label>
        </div>

        <label class="flex items-start gap-2">
          <input v-model="form.is_active" type="checkbox" class="mt-0.5 rounded border-stone-300" />
          <span>
            <span class="block text-sm font-medium text-stone-800">Active</span>
            <span class="block text-xs text-stone-500">
              Inactive methods stay saved but disappear from every customer checkout.
            </span>
          </span>
        </label>
      </section>

      <section class="card space-y-5 p-6">
        <h2 class="text-sm font-semibold tracking-wide text-stone-500 uppercase">
          Customer instructions
        </h2>

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

        <p class="text-xs text-stone-500">
          Markdown is supported in the instruction boxes. The reference prompt is the short line
          shown next to the amount field.
        </p>

        <label class="flex items-start gap-2">
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
      </section>

      <section class="card p-6">
        <EvidenceFieldEditor ref="editor" v-model="fields" />
      </section>

      <div v-if="error" class="card border-red-200 bg-red-50 p-4 text-sm text-red-800">
        {{ error }}
      </div>

      <div class="flex items-center gap-3">
        <button type="submit" class="btn-primary" :disabled="saving || !isValid">
          {{ saving ? 'Saving…' : 'Save payment method' }}
        </button>
        <router-link to="/admin/gateways" class="btn-secondary">Cancel</router-link>
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import EvidenceFieldEditor, { type FieldDraft } from '@/components/admin/EvidenceFieldEditor.vue'

interface Gateway {
  id: string
  kind: 'bkash' | 'nagad' | 'bank'
  name_en: string | null
  name_bn: string | null
  account_number: string | null
  account_name: string | null
  instructions_md_en: string | null
  instructions_md_bn: string | null
  reference_prompt_en: string | null
  reference_prompt_bn: string | null
  supports_reference: boolean
  is_active: boolean
  sort_order: number
  evidence_fields: Partial<FieldDraft>[] | null
}

const KINDS = [
  { value: 'bkash', label: 'bKash' },
  { value: 'nagad', label: 'Nagad' },
  { value: 'bank', label: 'Bank transfer' },
]

const route = useRoute()
const router = useRouter()
const supabase = getSupabase()

const gatewayId = computed(() => route.params.id as string | undefined)
const isEdit = computed(() => !!gatewayId.value)

const fields = ref<FieldDraft[]>([])
const editor = ref<InstanceType<typeof EvidenceFieldEditor> | null>(null)
const saving = ref(false)
const error = ref<string | null>(null)

const form = ref({
  kind: 'bkash' as Gateway['kind'],
  name_en: '',
  name_bn: '',
  instructions_en: '',
  instructions_bn: '',
  reference_prompt_en: '',
  reference_prompt_bn: '',
  account_number: '',
  account_name: '',
  supports_reference: false,
  is_active: true,
  sort_order: 0,
})

const isValid = computed(() => (editor.value?.problems ?? []).every((problem) => !problem))

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

onMounted(async () => {
  if (!isEdit.value) return

  const { data } = await (supabase.rpc as any)('admin_gateways')
  const gateway: Gateway | undefined = (data || []).find(
    (row: { id: string }) => row.id === gatewayId.value,
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
    account_number: gateway.account_number ?? '',
    account_name: gateway.account_name ?? '',
    supports_reference: gateway.supports_reference,
    is_active: gateway.is_active,
    sort_order: gateway.sort_order ?? 0,
  }
  fields.value = (gateway.evidence_fields ?? []).map(toDraft)
})

const save = async (): Promise<void> => {
  if (!isValid.value) return

  saving.value = true
  error.value = null

  try {
    // `api.admin_upsert_gateway` takes one jsonb argument, and these keys must
    // match the names the function reads out of it. Dropping any of them resets
    // that column, so the payload is built explicitly rather than by spreading.
    const { error: rpcError } = await (supabase.rpc as any)('admin_upsert_gateway', {
      p_gateway: {
        id: gatewayId.value ?? '',
        kind: form.value.kind,
        name_en: form.value.name_en,
        name_bn: form.value.name_bn || null,
        instructions_md_en: form.value.instructions_en || null,
        instructions_md_bn: form.value.instructions_bn || null,
        reference_prompt_en: form.value.reference_prompt_en || null,
        reference_prompt_bn: form.value.reference_prompt_bn || null,
        account_number: form.value.account_number || null,
        account_name: form.value.account_name || null,
        supports_reference: form.value.supports_reference,
        is_active: form.value.is_active,
        sort_order: form.value.sort_order ?? 0,
        evidence_fields: editor.value?.payload ?? [],
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

<script setup lang="ts">
import { computed } from 'vue'
import { useAdminI18n } from '@/i18n/admin'

const { t } = useAdminI18n()

/**
 * Editor for a gateway's destination: the details a customer reads in order to send the
 * money. Modelled on EvidenceFieldEditor because the operator does the same job in both
 * places - add labelled rows, order them, remove them - and a second editor with a
 * different shape would be a second thing to learn.
 *
 * What is deliberately not here: a type, a validator, a "required" box. These are values
 * to copy, not questions to answer, so there is nothing for a type or a format rule to do.
 *
 * The rules mirror `private.validate_account_fields`: at most 12 rows, unique keys
 * matching ^[a-z][a-z0-9_]{0,31}$, `label_en` and `value` both mandatory.
 */
export interface AccountDraft {
  key: string
  label_en: string
  label_bn: string
  value: string
  /** Set once the operator edits the key, so labels stop overwriting it. */
  keyLocked: boolean
}

const props = defineProps<{ error?: string | null }>()
const fields = defineModel<AccountDraft[]>({ required: true })

const MAX_FIELDS = 12

interface Preset {
  label: string
  field: Omit<AccountDraft, 'keyLocked'>
}

const PRESETS: Preset[] = [
  {
    label: 'Account number',
    field: {
      key: 'account_number',
      label_en: 'Account / wallet number',
      label_bn: 'অ্যাকাউন্ট নম্বর',
      value: '',
    },
  },
  {
    label: 'Account name',
    field: {
      key: 'account_name',
      label_en: 'Account name',
      label_bn: 'অ্যাকাউন্টের নাম',
      value: '',
    },
  },
  {
    label: 'Routing number',
    field: {
      key: 'routing_number',
      label_en: 'Routing number',
      label_bn: 'রাউটিং নম্বর',
      value: '',
    },
  },
  {
    label: 'Branch',
    field: {
      key: 'branch',
      label_en: 'Branch',
      label_bn: 'শাখা',
      value: '',
    },
  },
  {
    label: 'Bank name',
    field: {
      key: 'bank_name',
      label_en: 'Bank name',
      label_bn: 'ব্যাংকের নাম',
      value: '',
    },
  },
]

const keyPattern = /^[a-z][a-z0-9_]{0,31}$/

const atCapacity = computed(() => fields.value.length >= MAX_FIELDS)

/** A per-row message, or null when the row is valid. */
function problem(field: AccountDraft, index: number): string | null {
  if (!field.key) return 'Key is required.'
  if (!keyPattern.test(field.key)) {
    return 'Lowercase letters, digits and underscores; must start with a letter.'
  }
  const clash = fields.value.findIndex(
    (other, i) => i !== index && other.key.trim() === field.key.trim(),
  )
  if (clash !== -1) return 'Another row already uses this key.'

  if (!field.label_en.trim()) return 'An English label is required.'
  if (!field.value.trim()) return 'A value is required — this is what the customer copies.'

  return null
}

/** Keep the key in step with the label until the operator edits it directly. */
function syncKey(field: AccountDraft): void {
  if (field.keyLocked || field.key) return
  const slug = field.label_en
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 32)
  if (slug && /^[a-z]/.test(slug)) field.key = slug
  else if (slug) field.key = `d_${slug}`.slice(0, 32)
}

function addField(preset?: Preset): void {
  if (atCapacity.value) return
  const base = preset?.field ?? { key: '', label_en: '', label_bn: '', value: '' }
  fields.value.push({ ...base, keyLocked: !!preset })
}

function removeField(index: number): void {
  fields.value.splice(index, 1)
}

function move(index: number, delta: number): void {
  const target = index + delta
  if (target < 0 || target >= fields.value.length) return
  const copy = [...fields.value]
  const [item] = copy.splice(index, 1)
  if (!item) return
  copy.splice(target, 0, item)
  fields.value = copy
}

const toJson = (field: AccountDraft): Record<string, unknown> => ({
  key: field.key.trim(),
  label_en: field.label_en.trim(),
  ...(field.label_bn.trim() ? { label_bn: field.label_bn.trim() } : {}),
  value: field.value.trim(),
})

/** The payload the database expects, with irrelevant keys dropped. */
const payload = computed(() => fields.value.map(toJson))

const problems = computed(() => fields.value.map((field, index) => problem(field, index)))

const hasValues = computed(() => fields.value.some((field) => field.value.trim()))

defineExpose({ payload, problems })
</script>

<template>
  <div class="space-y-4">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.gateways.whereToSend') }}</h2>
        <p class="mt-0.5 text-xs text-stone-500">
          The details a customer copies from. Up to {{ MAX_FIELDS }} rows, shown to them in this
          order. A bank transfer usually needs more than one; a wallet usually needs one.
        </p>
      </div>
      <button
        type="button"
        class="btn-secondary !px-3 !py-2 text-xs"
        :disabled="atCapacity"
        @click="addField()"
      >
        + Add row
      </button>
    </div>

    <div class="flex flex-wrap items-center gap-2">
      <span class="text-xs text-stone-500">{{ t('admin.gateways.quickAdd') }}</span>
      <button
        v-for="preset in PRESETS"
        :key="preset.field.key"
        type="button"
        class="badge cursor-pointer border border-stone-300 bg-white text-stone-600 hover:border-brand-400 hover:text-brand-700"
        :disabled="atCapacity"
        @click="addField(preset)"
      >
        + {{ preset.label }}
      </button>
    </div>

    <p
      v-if="fields.length === 0"
      class="rounded-lg border border-dashed border-stone-300 bg-stone-50 px-4 py-6 text-center text-sm text-stone-500"
    >
      No details. Customers will not be told where to send the money, so this method can only work
      if they already know.
    </p>

    <ul v-else class="space-y-3">
      <li
        v-for="(field, index) in fields"
        :key="index"
        class="rounded-lg border bg-white p-4"
        :class="problems[index] ? 'border-red-300' : 'border-stone-200'"
      >
        <div class="mb-3 flex items-center justify-between gap-2">
          <span class="flex items-center gap-2">
            <span class="badge bg-stone-100 text-stone-600">{{ index + 1 }}</span>
            <span class="text-sm font-medium text-stone-800">
              {{ field.label_en || 'Untitled row' }}
            </span>
            <span v-if="!field.value.trim()" class="badge bg-amber-100 text-amber-800">
              Empty
            </span>
          </span>
          <span class="flex items-center gap-1">
            <button
              type="button"
              class="btn-secondary !px-2 !py-1 text-xs"
              :disabled="index === 0"
              title="Move up"
              @click="move(index, -1)"
            >
              ↑
            </button>
            <button
              type="button"
              class="btn-secondary !px-2 !py-1 text-xs"
              :disabled="index === fields.length - 1"
              title="Move down"
              @click="move(index, 1)"
            >
              ↓
            </button>
            <button
              type="button"
              class="btn-secondary !px-2 !py-1 text-xs !text-red-700"
              title="Remove"
              @click="removeField(index)"
            >
              Remove
            </button>
          </span>
        </div>

        <div class="grid gap-3 sm:grid-cols-2">
          <label class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600"
              >{{ t('admin.gateways.labelEn') }} *</span
            >
            <input v-model="field.label_en" class="field" @blur="syncKey(field)" />
            <span class="mt-1 block text-xs text-stone-500">{{
              t('admin.gateways.whatCustomerReads')
            }}</span>
          </label>

          <label class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600"
              >{{ t('admin.gateways.value') }} *</span
            >
            <input v-model="field.value" class="field ltr-value" />
          </label>

          <label class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600">{{
              t('admin.gateways.labelBn')
            }}</span>
            <input v-model="field.label_bn" class="field" lang="bn" />
            <span class="mt-1 block text-xs text-stone-500">
              Optional. Falls back to the English label.
            </span>
          </label>

          <label class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600"
              >{{ t('admin.gateways.rowKey') }} *</span
            >
            <input
              v-model="field.key"
              class="field font-mono text-xs"
              spellcheck="false"
              @input="field.keyLocked = true"
            />
          </label>
        </div>

        <p v-if="problems[index]" class="mt-2 text-xs text-red-700">{{ problems[index] }}</p>
      </li>
    </ul>

    <p v-if="fields.length > 0 && !hasValues" class="text-xs text-amber-700">
      Every row is empty, so nothing will be saved. Fill in at least one value, or remove the rows.
    </p>

    <p v-if="props.error" class="text-xs text-red-700">{{ props.error }}</p>
  </div>
</template>

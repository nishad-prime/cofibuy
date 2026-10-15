<script setup lang="ts">
import { computed } from 'vue'
import { useAdminI18n } from '@/i18n/admin'

const { t } = useAdminI18n()

/**
 * Editor for a gateway's evidence schema: the fields a customer must fill in
 * after paying (a transaction id, a screenshot, whatever the operator wants).
 *
 * The rules enforced here mirror `private.validate_evidence_fields` in the
 * database exactly, so an operator sees the problem before the round trip:
 * at most 12 fields, unique keys matching ^[a-z][a-z0-9_]{0,31}$, `label_en`
 * mandatory, `max_len` 1-200 for text, `max_mb` 1-10 for images.
 */
export type FieldType = 'text' | 'textarea' | 'number' | 'image'
export type FieldValidator = '' | 'bd_phone' | 'trxid' | 'numeric'

export interface FieldDraft {
  key: string
  type: FieldType
  label_en: string
  label_bn: string
  required: boolean
  validate: FieldValidator
  max_len: number | null
  max_mb: number | null
  /** Set once the operator edits the key, so labels stop overwriting it. */
  keyLocked: boolean
}

const props = defineProps<{ error?: string | null }>()
const fields = defineModel<FieldDraft[]>({ required: true })

const MAX_FIELDS = 12

interface Preset {
  label: string
  field: Omit<FieldDraft, 'keyLocked'>
}

const PRESETS: Preset[] = [
  {
    label: 'Transaction ID',
    field: {
      key: 'trxid',
      type: 'text',
      label_en: 'Transaction ID',
      label_bn: 'ট্রানজেকশন আইডি',
      required: true,
      validate: 'trxid',
      max_len: 24,
      max_mb: null,
    },
  },
  {
    label: 'Sender number',
    field: {
      key: 'sender_number',
      type: 'text',
      label_en: 'Sender number',
      label_bn: 'প্রেরকের নম্বর',
      required: true,
      validate: 'bd_phone',
      max_len: 20,
      max_mb: null,
    },
  },
  {
    label: 'Amount sent',
    field: {
      key: 'amount',
      type: 'number',
      label_en: 'Amount sent',
      label_bn: 'প্রেরিত টাকার পরিমাণ',
      required: true,
      validate: 'numeric',
      max_len: null,
      max_mb: null,
    },
  },
  {
    label: 'Payment screenshot',
    field: {
      key: 'screenshot',
      type: 'image',
      label_en: 'Payment screenshot',
      label_bn: 'পেমেন্টের স্ক্রিনশট',
      required: false,
      validate: '',
      max_len: null,
      max_mb: 4,
    },
  },
  {
    label: 'Note',
    field: {
      key: 'note',
      type: 'textarea',
      label_en: 'Note',
      label_bn: 'নোট',
      required: false,
      validate: '',
      max_len: 200,
      max_mb: null,
    },
  },
]

const TYPE_LABELS: Record<FieldType, string> = {
  text: 'Text',
  textarea: 'Long text',
  number: 'Number',
  image: 'Image upload',
}

const VALIDATOR_LABELS: Record<Exclude<FieldValidator, ''>, string> = {
  bd_phone: 'Bangladeshi phone number',
  trxid: 'Transaction ID',
  numeric: 'Digits only',
}

const keyPattern = /^[a-z][a-z0-9_]{0,31}$/

const atCapacity = computed(() => fields.value.length >= MAX_FIELDS)

/** A per-field message, or null when the field is valid. */
function problem(field: FieldDraft, index: number): string | null {
  if (!field.key) return 'Key is required.'
  if (!keyPattern.test(field.key)) {
    return 'Lowercase letters, digits and underscores; must start with a letter.'
  }
  const clash = fields.value.findIndex(
    (other, i) => i !== index && other.key.trim() === field.key.trim(),
  )
  if (clash !== -1) return 'Another field already uses this key.'

  if (!field.label_en.trim()) return 'An English label is required.'

  if (field.type === 'text' || field.type === 'textarea') {
    const max = field.max_len
    if (max == null || !Number.isInteger(max) || max < 1 || max > 200) {
      return 'Text fields need a maximum length between 1 and 200.'
    }
  }

  if (field.type === 'image') {
    const max = field.max_mb
    if (max == null || !Number.isInteger(max) || max < 1 || max > 10) {
      return 'Image fields need a maximum size between 1 and 10 MB.'
    }
  }

  return null
}

/** Keep the key in step with the label until the operator edits it directly. */
function syncKey(field: FieldDraft): void {
  if (field.keyLocked || field.key) return
  const slug = field.label_en
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 32)
  if (slug && /^[a-z]/.test(slug)) field.key = slug
  else if (slug) field.key = `f_${slug}`.slice(0, 32)
}

function addField(preset?: Preset): void {
  if (atCapacity.value) return
  const base = preset?.field ?? {
    key: '',
    type: 'text' as FieldType,
    label_en: '',
    label_bn: '',
    required: false,
    validate: '' as FieldValidator,
    max_len: 64,
    max_mb: null,
  }
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

const toJson = (field: FieldDraft): Record<string, unknown> => ({
  key: field.key.trim(),
  type: field.type,
  label_en: field.label_en.trim(),
  ...(field.label_bn.trim() ? { label_bn: field.label_bn.trim() } : {}),
  required: field.required,
  ...(field.validate ? { validate: field.validate } : {}),
  ...(field.type === 'image' ? { max_mb: field.max_mb } : {}),
  ...(field.type === 'text' || field.type === 'textarea' ? { max_len: field.max_len } : {}),
})

/** The payload the database expects, with irrelevant keys dropped. */
const payload = computed(() => fields.value.map(toJson))

const problems = computed(() => fields.value.map((field, index) => problem(field, index)))

defineExpose({ payload, problems })
</script>

<template>
  <div class="space-y-4">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 class="text-sm font-semibold text-stone-900">Evidence fields</h2>
        <p class="mt-0.5 text-xs text-stone-500">
          What the customer must submit after paying. Up to {{ MAX_FIELDS }} fields, shown in this
          order.
        </p>
      </div>
      <button
        type="button"
        class="btn-secondary !px-3 !py-2 text-xs"
        :disabled="atCapacity"
        @click="addField()"
      >
        + Add field
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
      No evidence fields. Orders for this payment method will not ask the customer for proof.
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
              {{ field.label_en || 'Untitled field' }}
            </span>
            <span class="badge bg-stone-100 text-stone-500">{{ TYPE_LABELS[field.type] }}</span>
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
          </label>

          <label class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600">{{
              t('admin.gateways.labelBn')
            }}</span>
            <input v-model="field.label_bn" class="field" lang="bn" />
          </label>

          <label class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600">Field key *</span>
            <input
              v-model="field.key"
              class="field font-mono text-xs"
              spellcheck="false"
              @input="field.keyLocked = true"
            />
          </label>

          <label class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600">Type</span>
            <select v-model="field.type" class="field">
              <option v-for="(label, value) in TYPE_LABELS" :key="value" :value="value">
                {{ label }}
              </option>
            </select>
          </label>

          <label v-if="field.type !== 'image'" class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600">{{
              t('admin.gateways.validation')
            }}</span>
            <select v-model="field.validate" class="field">
              <option value="">{{ t('admin.gateways.noFormatCheck') }}</option>
              <option v-for="(label, value) in VALIDATOR_LABELS" :key="value" :value="value">
                {{ label }}
              </option>
            </select>
          </label>

          <label v-if="field.type === 'text' || field.type === 'textarea'" class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600">Max length *</span>
            <input v-model.number="field.max_len" type="number" min="1" max="200" class="field" />
          </label>

          <label v-if="field.type === 'image'" class="block">
            <span class="mb-1 block text-xs font-medium text-stone-600">Max size (MB) *</span>
            <input v-model.number="field.max_mb" type="number" min="1" max="10" class="field" />
          </label>
        </div>

        <label class="mt-3 flex items-center gap-2 text-xs text-stone-600">
          <input v-model="field.required" type="checkbox" class="rounded border-stone-300" />
          Required — the customer cannot submit without it
        </label>

        <p v-if="problems[index]" class="mt-2 text-xs text-red-700">{{ problems[index] }}</p>
      </li>
    </ul>

    <p v-if="props.error" class="text-xs text-red-700">{{ props.error }}</p>
  </div>
</template>

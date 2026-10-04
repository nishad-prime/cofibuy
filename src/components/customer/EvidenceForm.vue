<template>
  <form class="space-y-5" @submit.prevent="handleSubmit">
    <div v-for="field in evidenceFields" :key="field.key" class="space-y-1.5">
      <label class="label" :for="field.key">
        {{ getFieldLabel(field) }}
        <span class="font-normal text-stone-400">
          ({{ field.required ? t('customer.evidence.required') : t('customer.evidence.optional') }})
        </span>
      </label>

      <input
        v-if="field.type === 'text' || field.type === 'number'"
        :id="field.key"
        v-model="formData[field.key]"
        :type="field.type"
        :required="field.required"
        :maxlength="field.max_len"
        class="field ltr-value"
        :class="errors[field.key] ? '!border-red-400' : ''"
        @blur="validateField(field)"
      />

      <textarea
        v-else-if="field.type === 'textarea'"
        :id="field.key"
        v-model="formData[field.key]"
        :required="field.required"
        :maxlength="field.max_len"
        rows="3"
        class="field"
        :class="errors[field.key] ? '!border-red-400' : ''"
        @blur="validateField(field)"
      />

      <div v-else-if="field.type === 'image'">
        <label
          class="flex cursor-pointer items-center gap-3 rounded-lg border border-dashed border-stone-300 bg-stone-50 px-3 py-3 text-sm text-stone-600 transition hover:border-brand-400 hover:text-stone-700"
        >
          <AppIcon name="upload" :size="18" class="text-stone-400" />
          <span class="truncate">{{
            fileNames[field.key] || t('customer.evidence.chooseImage')
          }}</span>
          <input
            :id="field.key"
            type="file"
            accept="image/jpeg,image/png,image/webp"
            class="sr-only"
            @change="handleFileChange($event, field)"
          />
        </label>
        <p v-if="field.max_mb" class="hint">
          {{ t('customer.evidence.maxSize', { size: field.max_mb }) }}
        </p>
      </div>

      <p v-if="errors[field.key]" class="text-xs font-medium text-red-600">
        {{ errors[field.key] }}
      </p>
    </div>

    <button
      type="submit"
      class="btn-primary w-full"
      :disabled="submitting || hasErrors || evidenceFields.length === 0"
    >
      {{ submitting ? t('customer.order.submitting') : t('customer.order.submitEvidenceCta') }}
    </button>
  </form>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { useContent } from '@/composables/useContent'
import AppIcon from '@/components/AppIcon.vue'

/**
 * Mirrors the jsonb shape that `private.validate_evidence_fields` accepts. The
 * validator name is `validate`, because that is the key the database reads.
 */
export interface EvidenceField {
  key: string
  type: string
  label_bn: string | null
  label_en: string | null
  required: boolean
  max_len?: number
  max_mb?: number
  validate?: string | null
}

const props = defineProps<{
  evidenceFields: EvidenceField[]
  submitting: boolean
}>()

const emit = defineEmits<{ (e: 'submit', evidence: Record<string, any>): void }>()

const { pick } = useContent()
const { t } = useI18n()

const formData = ref<Record<string, any>>({})
const errors = ref<Record<string, string>>({})
const fileNames = ref<Record<string, string>>({})

const hasErrors = computed(() => Object.keys(errors.value).length > 0)

const getFieldLabel = (field: EvidenceField): string => {
  return pick({ bn: field.label_bn, en: field.label_en } as any) || field.key
}

const validateBdPhone = (value: string): boolean => {
  return /^01[3-9]\d{8}$/.test(value.replace(/\D/g, ''))
}

const validateTrxid = (value: string): boolean => {
  const trimmed = value.trim()
  return trimmed.length > 0 && trimmed.length <= 100
}

const validateNumeric = (value: string): boolean => {
  return /^\d+$/.test(value)
}

const validateField = (field: EvidenceField): void => {
  const value = formData.value[field.key]

  if (!value && !field.required) {
    delete errors.value[field.key]
    return
  }

  if (field.required && (!value || (typeof value === 'string' && value.trim() === ''))) {
    errors.value[field.key] = t('customer.evidence.errRequired')
    return
  }

  if (field.validate === 'bd_phone' && typeof value === 'string' && !validateBdPhone(value)) {
    errors.value[field.key] = t('customer.evidence.errPhone')
    return
  }

  if (field.validate === 'trxid' && typeof value === 'string' && !validateTrxid(value)) {
    errors.value[field.key] = t('customer.evidence.errTrxid')
    return
  }

  if (field.validate === 'numeric' && typeof value === 'string' && !validateNumeric(value)) {
    errors.value[field.key] = t('customer.evidence.errNumeric')
    return
  }

  if (field.max_len && typeof value === 'string' && value.length > field.max_len) {
    errors.value[field.key] = t('customer.evidence.errMaxLen', { max: field.max_len })
    return
  }

  delete errors.value[field.key]
}

const handleFileChange = (event: Event, field: EvidenceField): void => {
  const target = event.target as HTMLInputElement
  const file = target.files?.[0]
  if (!file) return

  const maxMb = field.max_mb || 5
  if (file.size > maxMb * 1024 * 1024) {
    errors.value[field.key] = t('customer.evidence.errFileSize')
    target.value = ''
    return
  }

  formData.value[field.key] = file
  fileNames.value[field.key] = file.name
  delete errors.value[field.key]
}

const handleSubmit = (): void => {
  props.evidenceFields.forEach((field) => validateField(field))
  if (hasErrors.value) return
  emit('submit', formData.value)
}
</script>

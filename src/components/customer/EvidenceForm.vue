<template>
  <form @submit.prevent="handleSubmit" class="space-y-4">
    <div v-for="field in evidenceFields" :key="field.key" class="space-y-2">
      <label :for="field.key" class="block text-sm font-medium text-gray-700">
        {{ getFieldLabel(field) }}
        <span v-if="field.required" class="text-red-500">*</span>
      </label>

      <input
        v-if="field.type === 'text' || field.type === 'number'"
        :id="field.key"
        v-model="formData[field.key]"
        :type="field.type"
        :required="field.required"
        :maxlength="field.max_len"
        class="w-full rounded-md border border-gray-300 px-3 py-2"
        @blur="validateField(field)"
      />

      <textarea
        v-else-if="field.type === 'textarea'"
        :id="field.key"
        v-model="formData[field.key]"
        :required="field.required"
        :maxlength="field.max_len"
        rows="3"
        class="w-full rounded-md border border-gray-300 px-3 py-2"
        @blur="validateField(field)"
      />

      <div v-else-if="field.type === 'image'">
        <input
          :id="field.key"
          type="file"
          accept="image/jpeg,image/png,image/webp"
          :required="field.required"
          class="w-full rounded-md border border-gray-300 px-3 py-2"
          @change="handleFileChange($event, field.key)"
        />
        <p v-if="field.max_mb" class="mt-1 text-xs text-gray-500">Max size: {{ field.max_mb }}MB</p>
      </div>

      <p v-if="errors[field.key]" class="text-xs text-red-600">
        {{ errors[field.key] }}
      </p>
    </div>

    <button
      type="submit"
      :disabled="submitting || hasErrors"
      class="w-full rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-gray-400"
    >
      {{ submitting ? 'Submitting...' : 'Submit Evidence' }}
    </button>
  </form>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import { useContent } from '@/composables/useContent'

interface EvidenceField {
  key: string
  type: string
  label_bn: string | null
  label_en: string | null
  required: boolean
  max_len?: number
  max_mb?: number
  validator?: string | null
}

const props = defineProps<{
  evidenceFields: EvidenceField[]
  submitting: boolean
}>()

const emit = defineEmits<{
  (e: 'submit', evidence: Record<string, any>): void
}>()

const { pick } = useContent()

const formData = ref<Record<string, any>>({})
const errors = ref<Record<string, string>>({})

const hasErrors = computed(() => Object.keys(errors.value).length > 0)

const getFieldLabel = (field: EvidenceField): string => {
  return pick({ bn: field.label_bn, en: field.label_en } as any) || field.key
}

const validateBdPhone = (value: string): boolean => {
  // Basic BD phone validation
  return /^01[3-9]\d{8}$/.test(value.replace(/\D/g, ''))
}

const validateTrxid = (value: string): boolean => {
  return value.trim().length > 0 && value.trim().length <= 100
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
    errors.value[field.key] = 'This field is required'
    return
  }

  if (field.validator === 'bd_phone' && typeof value === 'string') {
    if (!validateBdPhone(value)) {
      errors.value[field.key] = 'Invalid Bangladeshi phone number'
      return
    }
  }

  if (field.validator === 'trxid' && typeof value === 'string') {
    if (!validateTrxid(value)) {
      errors.value[field.key] = 'Invalid transaction ID'
      return
    }
  }

  if (field.validator === 'numeric' && typeof value === 'string') {
    if (!validateNumeric(value)) {
      errors.value[field.key] = 'Must be numeric'
      return
    }
  }

  if (field.max_len && typeof value === 'string' && value.length > field.max_len) {
    errors.value[field.key] = `Max length ${field.max_len} exceeded`
    return
  }

  delete errors.value[field.key]
}

const handleFileChange = (event: Event, fieldKey: string): void => {
  const target = event.target as HTMLInputElement
  if (target.files && target.files[0]) {
    const file = target.files[0]
    if (
      file.size >
      (props.evidenceFields.find((f) => f.key === fieldKey)?.max_mb || 5) * 1024 * 1024
    ) {
      errors.value[fieldKey] = 'File too large'
      return
    }
    formData.value[fieldKey] = file
    delete errors.value[fieldKey]
  }
}

const handleSubmit = (): void => {
  // Validate all fields
  props.evidenceFields.forEach((field) => validateField(field))
  if (hasErrors.value) {
    return
  }
  emit('submit', formData.value)
}
</script>

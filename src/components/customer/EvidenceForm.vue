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
        v-model="formData[field.key] as string"
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
        v-model="formData[field.key] as string"
        :required="field.required"
        :maxlength="field.max_len"
        rows="3"
        class="field"
        :class="errors[field.key] ? '!border-red-400' : ''"
        @blur="validateField(field)"
      />

      <!--
        The screenshot attach. One surface, three ways in: tap to pick, paste
        from the clipboard (the payment app's screenshot is usually still
        there), or drag a file in. Once attached it flips to a preview with
        replace and remove, so the customer can see exactly what they are
        sending before it goes to review. The file input stays mounted in both
        states: the labels drive it through its id, so Replace works after a
        file is already chosen.
      -->
      <div v-else-if="field.type === 'image'">
        <!-- Attached: thumbnail, file facts, replace / remove. -->
        <div
          v-if="isFile(formData[field.key])"
          class="flex items-center gap-3 rounded-lg border border-white/15 bg-white/5 p-2.5"
        >
          <img
            :src="previews[field.key]"
            :alt="getFieldLabel(field)"
            class="size-14 shrink-0 rounded-md border border-white/10 object-cover"
          />
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-medium text-stone-100">
              {{ fileNames[field.key] }}
            </p>
            <p class="mt-0.5 flex items-center gap-1 text-xs text-brand-300">
              <AppIcon name="check" :size="12" aria-hidden="true" />
              {{ formatSize(fileSizes[field.key] ?? 0) }} ·
              {{ t('customer.evidence.attached') }}
            </p>
          </div>
          <label
            class="shrink-0 cursor-pointer rounded-md border border-white/15 px-2.5 py-1.5 text-xs font-medium text-stone-300 transition hover:bg-white/10 hover:text-stone-100"
            :for="`pick-${field.key}`"
          >
            {{ t('customer.evidence.replace') }}
          </label>
          <button
            type="button"
            class="shrink-0 rounded-md p-1.5 text-stone-500 transition hover:bg-red-500/10 hover:text-red-300"
            :aria-label="t('customer.evidence.remove')"
            @click="removeFile(field.key)"
          >
            <AppIcon name="close" :size="16" aria-hidden="true" />
          </button>
        </div>

        <!-- Empty: the dropzone. -->
        <label
          v-else
          class="flex cursor-pointer flex-col items-center gap-1.5 rounded-lg border border-dashed px-4 py-6 text-center transition"
          :class="
            dragging[field.key]
              ? 'border-brand-400 bg-brand-500/10'
              : errors[field.key]
                ? 'border-red-400/60 bg-red-500/5'
                : 'border-white/20 bg-white/5 hover:border-brand-400/60 hover:bg-white/10'
          "
          :for="`pick-${field.key}`"
          @dragover.prevent="dragging[field.key] = true"
          @dragleave.prevent="dragging[field.key] = false"
          @drop.prevent="handleDrop($event, field)"
        >
          <AppIcon name="upload" :size="20" class="text-stone-400" />
          <span class="text-sm font-medium text-stone-200">
            {{ t('customer.evidence.tapToAttach') }}
          </span>
          <span class="text-xs text-stone-500">
            {{ t('customer.evidence.pasteOrDrag') }}
          </span>
        </label>
        <input
          :id="`pick-${field.key}`"
          type="file"
          accept="image/jpeg,image/png,image/webp"
          class="sr-only"
          @change="handleFileChange($event, field)"
        />
        <p v-if="field.max_mb" class="hint">
          {{ t('customer.evidence.maxSize', { size: field.max_mb }) }}
        </p>
      </div>

      <p v-if="errors[field.key]" class="text-xs font-medium text-red-400">
        {{ errors[field.key] }}
      </p>
    </div>

    <button
      type="submit"
      class="btn-primary flex w-full items-center justify-center gap-2"
      :disabled="submitting || hasErrors || evidenceFields.length === 0"
    >
      <span
        v-if="submitting"
        class="size-4 animate-spin rounded-full border-2 border-current border-t-transparent"
        aria-hidden="true"
      />
      {{ submitting ? t('customer.order.submitting') : t('customer.order.submitEvidenceCta') }}
    </button>
  </form>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
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

const emit = defineEmits<{ (e: 'submit', evidence: Record<string, string | File>): void }>()

const { pick } = useContent()
const { t } = useI18n()

const formData = ref<Record<string, string | File>>({})
const errors = ref<Record<string, string>>({})
const fileNames = ref<Record<string, string>>({})
const fileSizes = ref<Record<string, number>>({})
const previews = ref<Record<string, string>>({})
const dragging = ref<Record<string, boolean>>({})

const hasErrors = computed(() => Object.keys(errors.value).length > 0)

/** Template-visible File check: `instanceof` globals are not whitelisted there. */
const isFile = (value: unknown): value is File => value instanceof File

const getFieldLabel = (field: EvidenceField): string => {
  return pick({ bn: field.label_bn, en: field.label_en }) || field.key
}

const formatSize = (bytes: number): string => {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${Math.max(1, Math.round(bytes / 1024))} KB`
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

/** The accepted upload types; the accept attribute alone is only a hint. */
const ACCEPTED_MIME = ['image/jpeg', 'image/png', 'image/webp']

/**
 * Installs one file for a field: revokes the previous preview, keeps the
 * thumbnail's object URL alive, and clears any earlier complaint. Size and
 * type are checked here, before an upload can even be attempted.
 */
const acceptFile = (file: File, field: EvidenceField): void => {
  const maxMb = field.max_mb || 5
  if (!ACCEPTED_MIME.includes(file.type)) {
    errors.value[field.key] = t('customer.evidence.errFileType')
    return
  }
  if (file.size > maxMb * 1024 * 1024) {
    errors.value[field.key] = t('customer.evidence.errFileSize')
    return
  }

  const previous = previews.value[field.key]
  if (previous) URL.revokeObjectURL(previous)

  formData.value[field.key] = file
  fileNames.value[field.key] = file.name
  fileSizes.value[field.key] = file.size
  previews.value[field.key] = URL.createObjectURL(file)
  delete errors.value[field.key]
  validateField(field)
}

const handleFileChange = (event: Event, field: EvidenceField): void => {
  const target = event.target as HTMLInputElement
  const file = target.files?.[0]
  if (!file) return
  acceptFile(file, field)
  // Reset so picking the same file again still fires a change event.
  target.value = ''
}

const removeFile = (fieldKey: string): void => {
  const previous = previews.value[fieldKey]
  if (previous) URL.revokeObjectURL(previous)
  delete formData.value[fieldKey]
  delete fileNames.value[fieldKey]
  delete fileSizes.value[fieldKey]
  delete previews.value[fieldKey]
  delete errors.value[fieldKey]
}

const fileFromTransfer = (event: Event): File | null => {
  // Feature detection, not instanceof: DragEvent is missing in some runtimes,
  // and a class check there would throw instead of answering.
  const transfer =
    'dataTransfer' in event
      ? (event.dataTransfer as DataTransfer | null)?.items
      : (event as ClipboardEvent).clipboardData?.items
  if (!transfer) return null
  for (const item of transfer) {
    if (item.kind === 'file' && ACCEPTED_MIME.includes(item.type)) {
      return item.getAsFile()
    }
  }
  return null
}

const handleDrop = (event: DragEvent, field: EvidenceField): void => {
  dragging.value[field.key] = false
  const file = fileFromTransfer(event)
  if (file) acceptFile(file, field)
}

/**
 * Clipboard paste works anywhere on the page, not only while the dropzone is
 * under the cursor: the payment app's screenshot is usually still in the
 * clipboard, and one Ctrl+V should attach it. An image field that already has
 * a file is left alone - replacing is an explicit Replace tap.
 */
const onWindowPaste = (event: ClipboardEvent): void => {
  const target = props.evidenceFields.find(
    (field) => field.type === 'image' && !isFile(formData.value[field.key]),
  )
  if (!target) return
  const file = fileFromTransfer(event)
  if (file) {
    event.preventDefault()
    acceptFile(file, target)
  }
}

onMounted(() => window.addEventListener('paste', onWindowPaste))

onBeforeUnmount(() => {
  window.removeEventListener('paste', onWindowPaste)
  for (const url of Object.values(previews.value)) URL.revokeObjectURL(url)
})

const handleSubmit = (): void => {
  props.evidenceFields.forEach((field) => validateField(field))
  if (hasErrors.value) return
  emit('submit', formData.value)
}
</script>

<template>
  <span
    class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
    :class="badgeClass"
  >
    {{ statusLabel }}
    <span v-if="isPolling" class="ml-1 animate-pulse">•</span>
  </span>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'

const props = defineProps<{
  status: string
  isPolling?: boolean
}>()

const { t } = useI18n()

const statusLabel = computed(() => {
  switch (props.status) {
    case 'draft':
      return t('admin.status.draft')
    case 'awaiting_proof':
      return t('admin.status.awaiting_proof')
    case 'under_review':
      return t('admin.status.under_review')
    case 'approved':
      return t('admin.status.approved')
    case 'rejected':
      return t('admin.status.rejected')
    case 'expired':
      return t('admin.status.expired')
    case 'locked':
      return t('admin.status.locked')
    default:
      return props.status
  }
})

const badgeClass = computed(() => {
  switch (props.status) {
    case 'draft':
      return 'bg-gray-100 text-gray-800'
    case 'awaiting_proof':
      return 'bg-yellow-100 text-yellow-800'
    case 'under_review':
      return 'bg-blue-100 text-blue-800'
    case 'approved':
      return 'bg-green-100 text-green-800'
    case 'rejected':
      return 'bg-red-100 text-red-800'
    case 'expired':
      return 'bg-gray-100 text-gray-800'
    case 'locked':
      return 'bg-orange-100 text-orange-800'
    default:
      return 'bg-gray-100 text-gray-800'
  }
})
</script>

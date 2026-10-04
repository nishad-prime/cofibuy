<script setup lang="ts">
import { computed } from 'vue'

/**
 * Rendered in both halves of the app: the admin queue/detail pages and the
 * customer order page.
 *
 * It deliberately does no i18n lookups of its own. The two halves use different
 * i18n instances (see `src/i18n/admin.ts`), and `useI18n()` inside a component
 * always resolves the customer instance, so an `admin.*` lookup here silently
 * rendered the raw key. Callers pass `label` instead.
 */
const props = defineProps<{
  status: string
  label?: string
  isPolling?: boolean
}>()

/** `awaiting_proof` -> `Awaiting proof`, for callers with nothing to translate. */
const prettified = computed(() =>
  props.status
    .split('_')
    .filter(Boolean)
    .map((word) => (word[0] ?? '').toUpperCase() + word.slice(1))
    .join(' '),
)

const statusLabel = computed(() => props.label || prettified.value)

const badgeClass = computed(() => {
  switch (props.status) {
    case 'awaiting_proof':
      return 'badge-warn'
    case 'under_review':
      return 'badge-info'
    case 'approved':
      return 'badge-ok'
    case 'rejected':
      return 'badge-danger'
    case 'locked':
      return 'badge-warn'
    default:
      return 'badge-muted'
  }
})
</script>

<template>
  <span :class="badgeClass">
    {{ statusLabel }}
    <span v-if="isPolling" class="ml-1 animate-pulse">•</span>
  </span>
</template>

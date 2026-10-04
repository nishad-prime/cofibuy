<script setup lang="ts">
import { computed } from 'vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import { useCopyOverrides } from '@/composables/useCopyOverrides'
import { useI18n } from 'vue-i18n'

const props = withDefaults(defineProps<{ copyKey: string; tag?: string }>(), { tag: 'span' })

const { t } = useI18n()
const { isMarkdown } = useCopyOverrides()

const text = computed(() => t(`customer.${props.copyKey}`) as string)
const markdown = computed(() => isMarkdown(props.copyKey))
</script>

<template>
  <MarkdownBody v-if="markdown" :source="text" />
  <component v-else :is="props.tag">{{ text }}</component>
</template>

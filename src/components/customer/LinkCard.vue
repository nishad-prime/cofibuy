<template>
  <div class="rounded-lg border border-gray-200 bg-white p-6 shadow-sm">
    <h3 class="mb-2 text-xl font-semibold text-gray-900">
      {{ title }}
    </h3>
    <p v-if="teaser" class="mb-4 text-gray-600">
      {{ teaser }}
    </p>
    <router-link
      :to="`/${slug}`"
      class="inline-flex items-center rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 focus:outline-none"
    >
      {{ ctaLabel || 'View' }}
    </router-link>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useContent } from '@/composables/useContent'

const props = defineProps<{
  slug: string
  titleBn: string | null
  titleEn: string | null
  teaserBn: string | null
  teaserEn: string | null
  ctaLabelBn: string | null
  ctaLabelEn: string | null
}>()

const { pick } = useContent()

const title = computed(() => pick({ bn: props.titleBn, en: props.titleEn } as any) || '')
const teaser = computed(() => pick({ bn: props.teaserBn, en: props.teaserEn } as any) || '')
const ctaLabel = computed(() => pick({ bn: props.ctaLabelBn, en: props.ctaLabelEn } as any) || '')
</script>

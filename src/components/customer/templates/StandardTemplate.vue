<template>
  <section>
    <h1 class="text-3xl font-bold tracking-tight text-stone-900 sm:text-4xl">
      {{ title }}
    </h1>

    <section v-if="teaser" class="card card-pad mt-6">
      <MarkdownBody :source="teaser" />
    </section>

    <slot name="purchase" />
  </section>
</template>

<script setup lang="ts">
/**
 * The template every page had before templates existed.
 *
 * It reads nothing from the template config, which is the point: pages saved
 * before the `template` column was added default here and must render exactly
 * as they did. Everything the layout shows comes from the page row itself.
 */
import { computed } from 'vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import { useContent } from '@/composables/useContent'

const props = defineProps<{
  page: {
    title_en: string | null
    title_bn: string | null
    teaser_md_en: string | null
    teaser_md_bn: string | null
  }
}>()

const { pick } = useContent()

const title = computed(() => pick({ bn: props.page.title_bn, en: props.page.title_en }))
const teaser = computed(() => pick({ bn: props.page.teaser_md_bn, en: props.page.teaser_md_en }))
</script>

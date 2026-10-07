<template>
  <article class="card card-pad flex flex-col transition hover:-translate-y-0.5 hover:shadow-md">
    <h3 class="text-lg font-semibold text-stone-900">{{ title }}</h3>

    <!--
      The teaser is admin-authored Markdown, so a heading at the start would
      render a block element where the surrounding card expects inline text.
      Render it properly when it is block content, strip the markers when not.
    -->
    <div v-if="isBlockTeaser" class="mt-3 border-t border-stone-100 pt-1">
      <MarkdownBody :source="teaser" />
    </div>
    <p v-else-if="teaser" class="mt-2 text-sm text-stone-600">{{ plainTeaser }}</p>

    <router-link :to="`/${slug}`" class="btn-primary mt-5 self-start">
      {{ ctaLabel || 'View' }}
      <AppIcon name="arrowLeft" :size="16" class="rotate-180" />
    </router-link>
  </article>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useContent } from '@/composables/useContent'
import AppIcon from '@/components/AppIcon.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'

const props = defineProps<{
  slug: string
  titleBn: string | null
  titleEn: string | null
  teaserMdBn: string | null
  teaserMdEn: string | null
  ctaLabelBn: string | null
  ctaLabelEn: string | null
}>()

const { pick } = useContent()

const title = computed(() => pick({ bn: props.titleBn, en: props.titleEn } as any) || '')
const teaser = computed(() => pick({ bn: props.teaserMdBn, en: props.teaserMdEn } as any) || '')
const ctaLabel = computed(() => pick({ bn: props.ctaLabelBn, en: props.ctaLabelEn } as any) || '')

const isBlockTeaser = computed(() => /(^|\n)\s*(#{1,6}\s|[-*]\s|>\s|\|)/.test(teaser.value))

const plainTeaser = computed(() =>
  teaser.value
    .replace(/[#*_`>[\]]/g, '')
    .replace(/\s+/g, ' ')
    .trim(),
)
</script>

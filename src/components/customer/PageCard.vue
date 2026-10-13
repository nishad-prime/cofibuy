<template>
  <article
    class="card card-lift group flex flex-col overflow-hidden transition hover:-translate-y-0.5 hover:shadow-md"
  >
    <!--
      Cover: the page's own hero image (sales pages store it in the template
      config), or a branded gradient placeholder. The strip is the card's
      identity - text-only cards read as stubs next to it.
    -->
    <div class="img-hover group relative aspect-[16/9] w-full overflow-hidden bg-stone-100">
      <img v-if="coverUrl" :src="coverUrl" :alt="title" class="h-full w-full object-cover" />
      <div
        v-else
        class="flex h-full w-full items-center justify-center bg-gradient-to-br from-brand-100 via-brand-50 to-white"
      >
        <span class="text-2xl font-black text-brand-700/70 ltr-value">C</span>
      </div>
    </div>

    <div class="card-pad flex flex-1 flex-col">
      <h3 class="text-lg font-semibold text-stone-900">{{ title }}</h3>

      <router-link :to="`/${slug}`" class="btn-primary group/cta mt-5 self-start">
        {{ ctaLabel || 'View' }}
        <AppIcon
          name="arrowLeft"
          :size="16"
          class="rotate-180 transition-transform group-hover/cta:translate-x-0.5"
        />
      </router-link>
    </div>
  </article>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useContent } from '@/composables/useContent'
import AppIcon from '@/components/AppIcon.vue'

const props = defineProps<{
  slug: string
  titleBn: string | null
  titleEn: string | null
  ctaLabelBn: string | null
  ctaLabelEn: string | null
  templateConfig?: Record<string, unknown>
}>()

const { pick } = useContent()

const title = computed(() => pick({ bn: props.titleBn, en: props.titleEn }) || '')
const ctaLabel = computed(() => pick({ bn: props.ctaLabelBn, en: props.ctaLabelEn }) || '')

/**
 * The sales template stores its hero image on the page's template config,
 * which the public index payload already carries - so the index can show a
 * real cover without touching the database.
 */
const coverUrl = computed(() => {
  const config = props.templateConfig as { hero_image_url?: unknown } | undefined
  const url = config?.hero_image_url
  return typeof url === 'string' && url !== '' ? url : null
})
</script>

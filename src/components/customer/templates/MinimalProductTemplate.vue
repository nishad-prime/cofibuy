<template>
  <div class="divide-y divide-stone-200">
    <!-- Compact product page: image, title, what is inside, checkout. -->
    <section class="section-block bg-white">
      <div class="page-section-inner">
        <img
          v-if="config.hero_image_url"
          :src="config.hero_image_url"
          :alt="heroImageAlt ?? undefined"
          class="w-full rounded-2xl object-cover shadow-lg"
        />
        <h1 class="mt-8 text-4xl font-extrabold tracking-tight text-stone-900">
          {{ heroTitle }}
        </h1>
        <p v-if="config.hero_subtitle" class="mt-4 text-lg text-stone-600">
          {{ config.hero_subtitle }}
        </p>
        <button
          type="button"
          class="btn-primary mt-8 w-full py-3 text-base sm:w-auto sm:px-10"
          @click="scrollToCheckout"
        >
          {{ t('customer.page.getStarted') }}
        </button>
      </div>
    </section>

    <section v-if="visibleIncluded.length > 0" class="section-block bg-stone-50">
      <div class="page-section-inner">
        <h2 class="text-2xl font-bold tracking-tight text-stone-900">
          {{ t('customer.page.whatYouGet') }}
        </h2>
        <ul class="mt-8 space-y-4">
          <li
            v-for="(item, index) in visibleIncluded"
            :key="index"
            class="flex items-start gap-3 rounded-xl bg-white p-4"
          >
            <AppIcon name="check" :size="20" class="mt-0.5 shrink-0 text-emerald-600" />
            <div>
              <p class="font-semibold text-stone-900">{{ item.title }}</p>
              <p class="mt-1 text-sm text-stone-600">{{ item.body }}</p>
            </div>
          </li>
        </ul>
      </div>
    </section>

    <section id="page-checkout" class="section-block bg-white scroll-mt-16">
      <div class="page-section-inner">
        <p v-if="config.checkout_note" class="max-w-xl text-stone-600">
          {{ config.checkout_note }}
        </p>
        <div class="mt-6">
          <slot name="purchase" />
        </div>
      </div>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import AppIcon from '@/components/AppIcon.vue'
import { useContent } from '@/composables/useContent'
import { scrollToCheckout, type MinimalProductConfig } from '@/pages/templates/registry'

const { t } = useI18n()
const { pick } = useContent()

const props = defineProps<{
  page: {
    title_en: string | null
    title_bn: string | null
    teaser_md_en: string | null
    teaser_md_bn: string | null
  }
  config: MinimalProductConfig
}>()

const heroTitle = computed(
  () =>
    pick({ bn: props.config.hero_title_bn, en: props.config.hero_title_en }) ||
    pick({ bn: props.page.title_bn, en: props.page.title_en }),
)
const heroImageAlt = computed(
  () =>
    pick({ bn: props.config.hero_image_alt_bn, en: props.config.hero_image_alt_en }) ||
    heroTitle.value,
)

const config = computed(() => ({
  ...props.config,
  hero_subtitle: pick({ bn: props.config.hero_subtitle_bn, en: props.config.hero_subtitle_en }),
  checkout_note: pick({ bn: props.config.checkout_note_bn, en: props.config.checkout_note_en }),
}))

const visibleIncluded = computed(() =>
  props.config.included
    .map((item) => ({
      title: pick({ bn: item.title_bn, en: item.title_en }),
      body: pick({ bn: item.body_bn, en: item.body_en }),
    }))
    .filter((item) => item.title !== '' || item.body !== ''),
)
</script>

<template>
  <section>
    <!-- Hero: the title is the page's own; the subtitle is the template's one
         piece of prose above the fold. -->
    <h1 class="text-3xl font-bold tracking-tight text-stone-900 sm:text-4xl">
      {{ title }}
    </h1>
    <p v-if="subtitle" class="mt-3 text-lg text-stone-600">
      {{ subtitle }}
    </p>

    <section v-if="teaser" class="card card-pad mt-6">
      <MarkdownBody :source="teaser" />
    </section>

    <!-- Features: what the buyer gets, one row per config item. A row missing
         both titles is skipped rather than rendered as an empty box, because
         the operator builds this list by hand and half-finished rows are the
         normal state mid-edit. -->
    <section v-if="visibleItems.length > 0" class="mt-8 space-y-4">
      <h2 class="text-xl font-semibold text-stone-900">{{ t('customer.page.whatYouGet') }}</h2>
      <div class="grid gap-4 sm:grid-cols-2">
        <div v-for="(item, index) in visibleItems" :key="index" class="card card-pad">
          <h3 class="font-semibold text-stone-900">{{ item.title }}</h3>
          <p class="mt-1 text-sm text-stone-600">{{ item.body }}</p>
        </div>
      </div>
    </section>

    <section v-if="visibleFaq.length > 0" class="mt-8 space-y-4">
      <h2 class="text-xl font-semibold text-stone-900">{{ t('customer.page.faq') }}</h2>
      <div v-for="(entry, index) in visibleFaq" :key="index" class="card card-pad">
        <h3 class="font-semibold text-stone-900">{{ entry.q }}</h3>
        <p class="mt-1 text-sm text-stone-600">{{ entry.a }}</p>
      </div>
    </section>

    <slot name="purchase" />
  </section>
</template>

<script setup lang="ts">
/**
 * A landing-page layout: hero, feature list, FAQ, then the purchase form.
 *
 * Everything beyond the page's own title and teaser comes from the template
 * config, so this component never touches the row directly — the fields it
 * reads are the ones `normalizeConfig` guarantees, which is what lets the
 * markup assume strings and arrays instead of testing for them.
 */
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import MarkdownBody from '@/components/MarkdownBody.vue'
import { useContent } from '@/composables/useContent'
import type { LandingConfig } from '@/pages/templates/registry'

const { t } = useI18n()

const props = defineProps<{
  page: {
    title_en: string | null
    title_bn: string | null
    teaser_md_en: string | null
    teaser_md_bn: string | null
  }
  config: LandingConfig
}>()

const { pick } = useContent()

const title = computed(() => pick({ bn: props.page.title_bn, en: props.page.title_en }))
const teaser = computed(() => pick({ bn: props.page.teaser_md_bn, en: props.page.teaser_md_en }))
const config = computed(() => props.config)

const subtitle = computed(() =>
  pick({ bn: config.value.subtitle_bn, en: config.value.subtitle_en }),
)

const visibleItems = computed(() =>
  config.value.items
    .map((item) => ({
      title: pick({ bn: item.title_bn, en: item.title_en }),
      body: pick({ bn: item.body_bn, en: item.body_en }),
    }))
    .filter((item) => item.title !== '' || item.body !== ''),
)

const visibleFaq = computed(() =>
  config.value.faq
    .map((entry) => ({
      q: pick({ bn: entry.q_bn, en: entry.q_en }),
      a: pick({ bn: entry.a_bn, en: entry.a_en }),
    }))
    .filter((entry) => entry.q !== '' || entry.a !== ''),
)
</script>

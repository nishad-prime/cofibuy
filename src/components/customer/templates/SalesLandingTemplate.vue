<template>
  <div class="divide-y divide-stone-200">
    <!--
      Each section is roughly one mobile screen tall and ends with the same
      CTA: scroll to the checkout. The page is one continuous pitch, and the
      checkout is where every section points.
    -->
    <section class="section-block bg-gradient-to-b from-brand-50 to-white">
      <div class="page-section-inner">
        <p
          v-if="config.hero_eyebrow"
          class="text-sm font-semibold uppercase tracking-wide text-brand-700"
        >
          {{ config.hero_eyebrow }}
        </p>
        <h1 class="mt-3 text-4xl font-extrabold tracking-tight text-stone-900 sm:text-5xl">
          {{ heroTitle }}
        </h1>
        <p v-if="config.hero_subtitle" class="mt-4 max-w-xl text-lg text-stone-600">
          {{ config.hero_subtitle }}
        </p>
        <img
          v-if="config.hero_image_url"
          :src="config.hero_image_url"
          :alt="heroImageAlt ?? undefined"
          class="mt-8 w-full rounded-2xl object-cover shadow-lg"
        />
        <button
          v-if="heroCta"
          type="button"
          class="btn-primary mt-8 w-full py-3 text-base sm:w-auto sm:px-10"
          @click="scrollToCheckout"
        >
          {{ heroCta }}
        </button>
      </div>
    </section>

    <!-- The problem: why the product exists. -->
    <section v-if="config.problem_heading || config.problem_body" class="section-block bg-white">
      <div class="page-section-inner">
        <h2 class="text-3xl font-bold tracking-tight text-stone-900">
          {{ config.problem_heading }}
        </h2>
        <p v-if="config.problem_body" class="mt-4 max-w-xl text-lg leading-relaxed text-stone-600">
          {{ config.problem_body }}
        </p>
        <button type="button" class="btn-secondary mt-8" @click="scrollToCheckout">
          {{ t('customer.page.getStarted') }}
        </button>
      </div>
    </section>

    <!-- The benefits: what changes for the buyer, one card each. -->
    <section v-if="visibleBenefits.length > 0" class="section-block bg-stone-50">
      <div class="page-section-inner">
        <div class="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          <div
            v-for="(item, index) in visibleBenefits"
            :key="index"
            class="rounded-2xl border border-stone-200 bg-white p-6 shadow-sm"
          >
            <span v-if="item.icon" class="text-3xl" aria-hidden="true">{{ item.icon }}</span>
            <h3 class="mt-3 font-semibold text-stone-900">{{ item.title }}</h3>
            <p class="mt-2 text-sm leading-relaxed text-stone-600">{{ item.body }}</p>
          </div>
        </div>
        <button type="button" class="btn-primary mt-8" @click="scrollToCheckout">
          {{ t('customer.page.getStarted') }}
        </button>
      </div>
    </section>

    <!-- What is included: the deliverables, plainly. -->
    <section v-if="visibleIncluded.length > 0" class="section-block bg-white">
      <div class="page-section-inner">
        <h2 class="text-3xl font-bold tracking-tight text-stone-900">
          {{ config.included_heading }}
        </h2>
        <ul class="mt-8 space-y-4">
          <li
            v-for="(item, index) in visibleIncluded"
            :key="index"
            class="flex items-start gap-3 rounded-xl bg-stone-50 p-4"
          >
            <AppIcon name="check" :size="20" class="mt-0.5 shrink-0 text-emerald-600" />
            <div>
              <p class="font-semibold text-stone-900">{{ item.title }}</p>
              <p class="mt-1 text-sm text-stone-600">{{ item.body }}</p>
            </div>
          </li>
        </ul>
        <button type="button" class="btn-primary mt-8" @click="scrollToCheckout">
          {{ t('customer.page.getStarted') }}
        </button>
      </div>
    </section>

    <!-- How it works: the three steps from payment to delivery. -->
    <section v-if="visibleHow.length > 0" class="section-block bg-stone-50">
      <div class="page-section-inner">
        <h2 class="text-3xl font-bold tracking-tight text-stone-900">
          {{ config.how_heading }}
        </h2>
        <ol class="mt-8 space-y-6">
          <li v-for="(step, index) in visibleHow" :key="index" class="flex items-start gap-4">
            <span
              class="grid size-8 shrink-0 place-items-center rounded-full bg-brand-700 text-sm font-bold text-white ltr-value"
            >
              {{ index + 1 }}
            </span>
            <div>
              <p class="font-semibold text-stone-900">{{ step.title }}</p>
              <p class="mt-1 text-sm text-stone-600">{{ step.body }}</p>
            </div>
          </li>
        </ol>
      </div>
    </section>

    <!-- Testimonials: quotes the operator wrote themselves. -->
    <section v-if="visibleTestimonials.length > 0" class="section-block bg-white">
      <div class="page-section-inner">
        <div class="grid gap-6 sm:grid-cols-2">
          <figure
            v-for="(entry, index) in visibleTestimonials"
            :key="index"
            class="rounded-2xl border border-stone-200 bg-stone-50 p-6"
          >
            <blockquote class="text-sm leading-relaxed text-stone-700">
              “{{ entry.quote }}”
            </blockquote>
            <figcaption class="mt-3 text-xs font-medium text-stone-500">
              {{ entry.author }}
            </figcaption>
          </figure>
        </div>
      </div>
    </section>

    <!-- The FAQ, collapsible per question. -->
    <section v-if="visibleFaq.length > 0" class="section-block bg-stone-50">
      <div class="page-section-inner">
        <h2 class="text-3xl font-bold tracking-tight text-stone-900">
          {{ t('customer.page.faq') }}
        </h2>
        <div class="mt-8 space-y-3">
          <details
            v-for="(entry, index) in visibleFaq"
            :key="index"
            class="rounded-xl border border-stone-200 bg-white p-4"
          >
            <summary class="cursor-pointer font-semibold text-stone-900">{{ entry.q }}</summary>
            <p class="mt-2 text-sm text-stone-600">{{ entry.a }}</p>
          </details>
        </div>
      </div>
    </section>

    <!--
      The checkout, where every CTA above lands. The id is the scroll target;
      the component owns the whole payment state machine.
    -->
    <section id="page-checkout" class="section-block bg-white scroll-mt-16">
      <div class="page-section-inner">
        <h2 v-if="config.checkout_heading" class="text-3xl font-bold tracking-tight text-stone-900">
          {{ config.checkout_heading }}
        </h2>
        <p v-if="config.checkout_note" class="mt-3 max-w-xl text-stone-600">
          {{ config.checkout_note }}
        </p>
        <div class="mt-8">
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
import { scrollToCheckout, type SalesLandingConfig } from '@/pages/templates/registry'

const { t } = useI18n()
const { pick } = useContent()

const props = defineProps<{
  page: {
    title_en: string | null
    title_bn: string | null
    teaser_md_en: string | null
    teaser_md_bn: string | null
  }
  config: SalesLandingConfig
}>()

/**
 * The hero's title is the template config's own, falling back to the page
 * row's title: an operator who never touched the template config still gets
 * the page they named.
 */
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
const heroCta = computed(
  () =>
    pick({ bn: props.config.hero_cta_bn, en: props.config.hero_cta_en }) ||
    t('customer.page.getStarted'),
)

const config = computed(() => ({
  ...props.config,
  hero_eyebrow: pick({ bn: props.config.hero_eyebrow_bn, en: props.config.hero_eyebrow_en }),
  hero_subtitle: pick({ bn: props.config.hero_subtitle_bn, en: props.config.hero_subtitle_en }),
  problem_heading: pick({
    bn: props.config.problem_heading_bn,
    en: props.config.problem_heading_en,
  }),
  problem_body: pick({ bn: props.config.problem_body_bn, en: props.config.problem_body_en }),
  included_heading: pick({
    bn: props.config.included_heading_bn,
    en: props.config.included_heading_en,
  }),
  how_heading: pick({ bn: props.config.how_heading_bn, en: props.config.how_heading_en }),
  checkout_heading: pick({
    bn: props.config.checkout_heading_bn,
    en: props.config.checkout_heading_en,
  }),
  checkout_note: pick({
    bn: props.config.checkout_note_bn,
    en: props.config.checkout_note_en,
  }),
}))

const visibleBenefits = computed(() =>
  props.config.benefits
    .map((item) => ({
      icon: item.icon,
      title: pick({ bn: item.title_bn, en: item.title_en }),
      body: pick({ bn: item.body_bn, en: item.body_en }),
    }))
    .filter((item) => item.title !== '' || item.body !== ''),
)

const visibleIncluded = computed(() =>
  props.config.included
    .map((item) => ({
      title: pick({ bn: item.title_bn, en: item.title_en }),
      body: pick({ bn: item.body_bn, en: item.body_en }),
    }))
    .filter((item) => item.title !== '' || item.body !== ''),
)

const visibleHow = computed(() =>
  props.config.how
    .map((step) => ({
      title: pick({ bn: step.title_bn, en: step.title_en }),
      body: pick({ bn: step.body_bn, en: step.body_en }),
    }))
    .filter((step) => step.title !== '' || step.body !== ''),
)

const visibleTestimonials = computed(() =>
  props.config.testimonials
    .map((entry) => ({
      quote: pick({ bn: entry.quote_bn, en: entry.quote_en }),
      author: pick({ bn: entry.author_bn, en: entry.author_en }),
    }))
    .filter((entry) => entry.quote !== '' || entry.author !== ''),
)

const visibleFaq = computed(() =>
  props.config.faq
    .map((entry) => ({
      q: pick({ bn: entry.q_bn, en: entry.q_en }),
      a: pick({ bn: entry.a_bn, en: entry.a_en }),
    }))
    .filter((entry) => entry.q !== '' || entry.a !== ''),
)
</script>

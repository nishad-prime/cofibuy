<template>
  <div class="bg-stone-950 text-white">
    <!--
      Sticky marquee: fills the chrome-free top of a standalone sales page
      with the pitch, and keeps a CTA pinned at the right edge on every
      screen. The scrolling track is decorative (aria-hidden); screen readers
      get the sentence once.
    -->
    <div class="sticky top-0 z-30 border-b border-white/10 bg-stone-950/95 backdrop-blur">
      <span class="sr-only">{{ t('customer.page.marquee') }}</span>
      <div class="relative flex items-center overflow-hidden py-3">
        <div class="marquee-track flex w-max items-center" aria-hidden="true">
          <span v-for="copy in 2" :key="copy" class="flex shrink-0 items-center">
            <span
              v-for="repeat in 3"
              :key="repeat"
              class="flex items-center whitespace-nowrap text-sm font-medium text-stone-400"
            >
              <Sparkles :size="14" aria-hidden="true" class="mx-5 shrink-0 text-brand-400" />
              {{ t('customer.page.marquee') }}
            </span>
          </span>
        </div>
        <!-- Fade + CTA pinned into the strip's right corner, full height. -->
        <div
          class="pointer-events-none absolute inset-y-0 right-0 flex items-stretch bg-gradient-to-l from-stone-950 via-stone-950/90 to-transparent pl-16"
        >
          <button
            type="button"
            class="btn-primary cta-glow pointer-events-auto h-full gap-1.5 !rounded-none !px-5 bg-brand-500 text-sm text-stone-950 hover:bg-brand-400"
            @click="openCheckout"
          >
            {{ heroCta }}
            <ArrowRight :size="16" aria-hidden="true" />
          </button>
        </div>
      </div>
    </div>

    <!--
      Hero: premium, discreet, immediately actionable. The section is the flex
      parent; the inner column is the flex item - no height games.
    -->
    <section
      class="relative flex min-h-[88svh] items-center overflow-hidden bg-stone-950 py-16 sm:py-24"
    >
      <!-- Ambient glow: two slow-drifting brand blobs behind the content. -->
      <div class="ambient-blob -right-24 -top-24 size-[28rem] bg-brand-600" aria-hidden="true" />
      <div
        class="ambient-blob ambient-blob-2 -left-20 bottom-0 size-[24rem] bg-brand-800"
        aria-hidden="true"
      />
      <div v-reveal class="relative mx-auto w-full max-w-3xl px-5 sm:px-6">
        <span
          class="inline-flex items-center gap-1.5 rounded-full border border-white/20 bg-white/5 px-3 py-1 text-xs font-semibold text-stone-300 backdrop-blur"
        >
          <Lock :size="12" aria-hidden="true" />
          {{ t('customer.page.adultsOnly') }}
        </span>

        <h1
          class="copy-accent-dark mt-6 text-4xl font-black leading-[1.05] tracking-tight text-white sm:text-6xl"
        >
          {{ heroTitle }}
        </h1>
        <p
          v-if="config.hero_subtitle"
          class="mt-6 max-w-2xl text-lg leading-relaxed text-stone-300 sm:text-xl"
        >
          {{ config.hero_subtitle }}
        </p>

        <div
          class="img-hover group relative mt-8 overflow-hidden rounded-3xl border border-white/10 shadow-2xl shadow-black/40"
        >
          <img
            v-if="heroImg"
            :src="heroImg.url"
            :alt="heroImg.alt"
            class="aspect-[16/10] w-full object-cover"
          />
          <TemplatePlaceholder v-else :label="heroImageAlt" class="aspect-[16/10] w-full" />
        </div>

        <div class="mt-10 flex flex-col gap-3 sm:flex-row sm:items-center">
          <button
            type="button"
            class="btn-primary cta-glow group w-full bg-brand-500 py-3.5 text-base text-stone-950 shadow-lg shadow-brand-900/40 hover:bg-brand-400 sm:w-auto sm:px-10"
            @click="openCheckout"
          >
            {{ heroCta }}
            <ArrowRight
              :size="18"
              aria-hidden="true"
              class="transition-transform group-hover:translate-x-0.5"
            />
          </button>
          <!-- Our own locale string, so the emphasis markup is trusted content. -->
          <span
            class="text-center text-xs text-stone-400 sm:text-left"
            v-html="rich(t('customer.page.privateCheckout'))"
          />
        </div>
      </div>
    </section>

    <!-- Problem / desire: sell the transformation, not a feature list. -->
    <section
      v-if="config.problem_heading || config.problem_body"
      class="hairline flex min-h-[85svh] items-center bg-stone-900 py-16 sm:py-24"
    >
      <div v-reveal class="mx-auto w-full max-w-3xl px-5 sm:px-6">
        <p class="flex items-center gap-2 text-xs font-semibold text-brand-300">
          <span class="h-3 w-0.5 rounded-full bg-brand-400" aria-hidden="true" />
          <EyeOff :size="16" aria-hidden="true" />
          {{ t('customer.page.whyExists') }}
        </p>
        <h2
          class="copy-accent-dark mt-5 text-3xl font-bold leading-tight tracking-tight sm:text-5xl"
        >
          {{ config.problem_heading }}
        </h2>
        <p v-if="config.problem_body" class="mt-6 max-w-2xl text-lg leading-relaxed text-stone-300">
          {{ config.problem_body }}
        </p>
        <div
          class="img-hover group mt-10 overflow-hidden rounded-3xl border border-white/10 shadow-2xl shadow-black/40"
        >
          <img
            v-if="problemImg"
            :src="problemImg.url"
            :alt="problemImg.alt"
            class="aspect-[16/9] w-full object-cover"
          />
          <TemplatePlaceholder
            v-else
            :label="config.problem_heading"
            class="aspect-[16/9] w-full"
          />
        </div>
        <button
          type="button"
          class="btn-primary group mt-10 w-full bg-white py-3.5 text-base text-stone-900 hover:bg-brand-50 sm:w-auto sm:px-10"
          @click="openCheckout"
        >
          {{ t('customer.page.getStarted') }}
          <ArrowRight
            :size="18"
            aria-hidden="true"
            class="transition-transform group-hover:translate-x-0.5"
          />
        </button>
      </div>
    </section>

    <!-- Deliverables first: make the purchase concrete before the claims. -->
    <section
      v-if="visibleIncluded.length > 0"
      class="flex min-h-[85svh] items-center bg-white py-16 sm:py-24"
    >
      <div v-reveal class="mx-auto w-full max-w-3xl px-5 sm:px-6">
        <p class="flex items-center gap-2 text-xs font-semibold text-brand-700">
          <span class="h-3 w-0.5 rounded-full bg-brand-600" aria-hidden="true" />
          <PackageOpen :size="16" aria-hidden="true" />
          {{ t('customer.page.insidePurchase') }}
        </p>
        <h2 class="mt-5 text-3xl font-bold leading-tight tracking-tight text-stone-950 sm:text-5xl">
          {{ config.included_heading || t('customer.page.whatYouGet') }}
        </h2>
        <ul v-reveal class="reveal-stagger mt-10 grid gap-4 sm:grid-cols-2">
          <li
            v-for="(item, index) in visibleIncluded"
            :key="index"
            class="card-lift overflow-hidden rounded-2xl border border-stone-200 bg-stone-50 shadow-sm"
          >
            <img
              v-if="slotImage('included', index)"
              :src="slotImage('included', index)!.url"
              :alt="slotImage('included', index)!.alt"
              class="h-40 w-full object-cover"
            />
            <TemplatePlaceholder v-else :label="item.title" class="h-40 w-full" />
            <div class="p-5">
              <p class="font-semibold text-stone-950">{{ item.title }}</p>
              <p class="mt-1 text-sm leading-relaxed text-stone-600">{{ item.body }}</p>
            </div>
          </li>
        </ul>
        <button
          type="button"
          class="btn-primary group mt-10 w-full py-3.5 text-base sm:w-auto sm:px-10"
          @click="openCheckout"
        >
          {{ t('customer.page.getStarted') }}
          <ArrowRight
            :size="18"
            aria-hidden="true"
            class="transition-transform group-hover:translate-x-0.5"
          />
        </button>
      </div>
    </section>

    <!-- Benefits: the experience around the content. -->
    <section
      v-if="visibleBenefits.length > 0"
      class="flex min-h-[85svh] items-center bg-brand-50 py-16 sm:py-24"
    >
      <div v-reveal class="mx-auto w-full max-w-3xl px-5 sm:px-6">
        <p class="flex items-center gap-2 text-xs font-semibold text-brand-700">
          <span class="h-3 w-0.5 rounded-full bg-brand-600" aria-hidden="true" />
          <Sparkles :size="16" aria-hidden="true" />
          {{ t('customer.page.adultDiscretion') }}
        </p>
        <!-- Our own locale string, so the emphasis markup is trusted content. -->
        <h2
          class="copy-accent-light mt-5 text-3xl font-bold leading-tight tracking-tight text-stone-950 sm:text-5xl"
          v-html="rich(t('customer.page.benefitsPitch'))"
        />
        <ul v-reveal class="reveal-stagger mt-10 space-y-4">
          <li
            v-for="(item, index) in visibleBenefits"
            :key="index"
            class="card-lift flex items-start gap-4 rounded-2xl border border-brand-200 bg-white p-5 shadow-sm"
          >
            <img
              v-if="slotImage('benefits', index)"
              :src="slotImage('benefits', index)!.url"
              :alt="slotImage('benefits', index)!.alt"
              class="h-20 w-20 shrink-0 rounded-xl object-cover"
            />
            <TemplatePlaceholder v-else :label="item.title" class="h-20 w-20 shrink-0 rounded-xl" />
            <div>
              <h3 class="font-bold text-stone-950">{{ item.title }}</h3>
              <p class="mt-1 text-sm leading-relaxed text-stone-600">{{ item.body }}</p>
            </div>
          </li>
        </ul>
        <button
          type="button"
          class="btn-primary group mt-10 w-full py-3.5 text-base sm:w-auto sm:px-10"
          @click="openCheckout"
        >
          {{ t('customer.page.getStarted') }}
          <ArrowRight
            :size="18"
            aria-hidden="true"
            class="transition-transform group-hover:translate-x-0.5"
          />
        </button>
      </div>
    </section>

    <!-- How it works: remove hesitation with a simple path to the result. -->
    <section
      v-if="visibleHow.length > 0"
      class="flex min-h-[85svh] items-center bg-stone-100 py-16 sm:py-24"
    >
      <div v-reveal class="mx-auto w-full max-w-3xl px-5 sm:px-6">
        <p class="flex items-center gap-2 text-xs font-semibold text-brand-700">
          <span class="h-3 w-0.5 rounded-full bg-brand-600" aria-hidden="true" />
          <ListChecks :size="16" aria-hidden="true" />
          {{ t('customer.page.simpleByDesign') }}
        </p>
        <!-- Our own locale string, so the emphasis markup is trusted content. -->
        <h2
          class="copy-accent-light mt-5 text-3xl font-bold leading-tight tracking-tight text-stone-950 sm:text-5xl"
          v-html="rich(config.how_heading || t('customer.page.howPitch'))"
        />
        <div class="mt-10 grid items-center gap-10 lg:grid-cols-2">
          <ol v-reveal class="reveal-stagger space-y-4">
            <li
              v-for="(step, index) in visibleHow"
              :key="index"
              class="card-lift flex items-start gap-4 rounded-2xl bg-white p-5 shadow-sm"
            >
              <span
                class="grid size-9 shrink-0 place-items-center rounded-full bg-stone-950 text-sm font-bold text-brand-300 ltr-value"
              >
                {{ index + 1 }}
              </span>
              <div>
                <p class="font-bold text-stone-950">{{ step.title }}</p>
                <p class="mt-1 text-sm leading-relaxed text-stone-600">{{ step.body }}</p>
              </div>
            </li>
          </ol>
          <div class="overflow-hidden rounded-3xl shadow-lg">
            <img
              v-if="slotImage('how')"
              :src="slotImage('how')!.url"
              :alt="slotImage('how')!.alt"
              class="aspect-[4/3] w-full object-cover"
            />
            <TemplatePlaceholder v-else :label="config.how_heading" class="aspect-[4/3] w-full" />
          </div>
        </div>
        <button
          type="button"
          class="btn-primary group mt-10 w-full py-3.5 text-base sm:w-auto sm:px-10"
          @click="openCheckout"
        >
          {{ t('customer.page.getStarted') }}
          <ArrowRight
            :size="18"
            aria-hidden="true"
            class="transition-transform group-hover:translate-x-0.5"
          />
        </button>
      </div>
    </section>

    <!-- Proof: social confidence, still discreet. -->
    <section
      v-if="visibleTestimonials.length > 0"
      class="hairline flex min-h-[85svh] items-center bg-stone-950 py-16 sm:py-24"
    >
      <div v-reveal class="mx-auto w-full max-w-3xl px-5 sm:px-6">
        <p class="flex items-center gap-2 text-xs font-semibold text-brand-300">
          <span class="h-3 w-0.5 rounded-full bg-brand-400" aria-hidden="true" />
          <Star :size="16" aria-hidden="true" />
          {{ t('customer.page.trustedBy') }}
        </p>
        <!-- Our own locale string, so the emphasis markup is trusted content. -->
        <h2
          class="copy-accent-dark mt-5 text-3xl font-bold leading-tight tracking-tight sm:text-5xl"
          v-html="rich(t('customer.page.testimonialsPitch'))"
        />
        <ul v-reveal class="reveal-stagger mt-10 space-y-4">
          <li
            v-for="(entry, index) in visibleTestimonials"
            :key="index"
            class="card-lift rounded-2xl border border-white/10 bg-white/5 p-6"
          >
            <div class="flex items-start gap-4">
              <img
                v-if="slotImage('testimonials', index)"
                :src="slotImage('testimonials', index)!.url"
                :alt="slotImage('testimonials', index)!.alt"
                class="size-12 shrink-0 rounded-full object-cover"
              />
              <TemplatePlaceholder
                v-else
                :label="entry.author"
                class="size-12 shrink-0 rounded-full"
              />
              <blockquote class="text-base leading-relaxed text-stone-200">
                {{ entry.quote }}
              </blockquote>
            </div>
            <p class="mt-4 flex items-center gap-1.5 text-xs font-medium text-brand-300">
              <BadgeCheck :size="14" aria-hidden="true" />
              {{ entry.author }}
            </p>
          </li>
        </ul>
        <button
          type="button"
          class="btn-primary cta-glow group mt-10 w-full bg-brand-500 py-3.5 text-base text-stone-950 hover:bg-brand-400 sm:w-auto sm:px-10"
          @click="openCheckout"
        >
          {{ t('customer.page.getStarted') }}
          <ArrowRight
            :size="18"
            aria-hidden="true"
            class="transition-transform group-hover:translate-x-0.5"
          />
        </button>
      </div>
    </section>

    <!-- FAQ: objections answered, CTA still one tap away. -->
    <section
      v-if="visibleFaq.length > 0"
      class="flex min-h-[85svh] items-center bg-brand-50 py-16 sm:py-24"
    >
      <div v-reveal class="mx-auto w-full max-w-3xl px-5 sm:px-6">
        <p class="flex items-center gap-2 text-xs font-semibold text-brand-700">
          <span class="h-3 w-0.5 rounded-full bg-brand-600" aria-hidden="true" />
          <MessageCircleQuestion :size="16" aria-hidden="true" />
          {{ t('customer.page.beforeDecide') }}
        </p>
        <!-- Our own locale string, so the emphasis markup is trusted content. -->
        <h2
          class="copy-accent-light mt-5 text-3xl font-bold leading-tight tracking-tight text-stone-950 sm:text-5xl"
          v-html="rich(t('customer.page.questionsAnswered'))"
        />
        <div v-reveal class="reveal-stagger mt-10 space-y-3">
          <details
            v-for="(entry, index) in visibleFaq"
            :key="index"
            class="card-lift group rounded-2xl border border-brand-200 bg-white p-5"
          >
            <summary
              class="flex cursor-pointer items-center justify-between gap-3 font-semibold text-stone-950"
            >
              {{ entry.q }}
              <ChevronDown
                :size="18"
                aria-hidden="true"
                class="shrink-0 text-stone-400 transition-transform group-open:rotate-180"
              />
            </summary>
            <p class="mt-3 text-sm leading-relaxed text-stone-600">{{ entry.a }}</p>
          </details>
        </div>
        <button
          type="button"
          class="btn-primary group mt-10 w-full py-3.5 text-base sm:w-auto sm:px-10"
          @click="openCheckout"
        >
          {{ t('customer.page.getStarted') }}
          <ArrowRight
            :size="18"
            aria-hidden="true"
            class="transition-transform group-hover:translate-x-0.5"
          />
        </button>
      </div>
    </section>

    <!--
      The payment flow is modal-only on this page: every CTA above opens it.
      The slot hosts the invisible checkout (bare mode) and takes no space.
    -->
    <slot name="purchase" />
  </div>
</template>

<script setup lang="ts">
import { computed, type Directive } from 'vue'
import { useI18n } from 'vue-i18n'
import DOMPurify from 'dompurify'
import {
  ArrowRight,
  BadgeCheck,
  ChevronDown,
  EyeOff,
  ListChecks,
  Lock,
  MessageCircleQuestion,
  PackageOpen,
  Sparkles,
  Star,
} from 'lucide-vue-next'
import TemplatePlaceholder from '@/components/customer/TemplatePlaceholder.vue'
import { useContent } from '@/composables/useContent'
import { type PageImageMap, type SalesLandingConfig } from '@/pages/templates/registry'
import { useCheckoutModal } from '@/composables/useCheckoutModal'

const { t } = useI18n()
const { pick } = useContent()
const { openCheckout } = useCheckoutModal()

/**
 * Emphasis in headings is authored as <strong> inside i18n strings and colored
 * by `.copy-accent-*`. Everything that reaches v-html goes through DOMPurify:
 * the locale strings are ours, but the fallback (`how_heading`) is operator
 * text, so the sanitizer is not optional.
 */
const rich = (value: string): string => DOMPurify.sanitize(value)

/**
 * Scroll-reveal. One observer per element is fine at this scale, and a
 * disconnect-once-visible keeps long pages cheap. Elements that never
 * intersect (older browsers) are shown immediately rather than hidden.
 */
const vReveal: Directive<HTMLElement> = {
  mounted(el) {
    el.classList.add('reveal')
    if (typeof IntersectionObserver === 'undefined') {
      el.classList.add('reveal-visible')
      return
    }
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            el.classList.add('reveal-visible')
            observer.disconnect()
          }
        }
      },
      { threshold: 0.12 },
    )
    observer.observe(el)
  },
}

const props = defineProps<{
  page: {
    title_en: string | null
    title_bn: string | null
  }
  config: SalesLandingConfig
  /** Assigned images by slot; empty when nothing has been uploaded yet. */
  images?: PageImageMap
}>()

/** The assigned image for a slot, falling back to the config's legacy URL. */
const slotImage = (key: string, index = 0): { url: string; alt: string } | null => {
  const direct = props.images?.[index === 0 ? key : `${key}.${index}`]
  const fallbackAlt = heroImageAlt.value ?? ''
  if (direct?.url) {
    return {
      url: direct.url,
      alt: (index === 0 ? fallbackAlt : '') || direct.alt_en || direct.alt_bn || '',
    }
  }
  // The legacy config URL belongs to the hero alone. Letting it fall through
  // for every index-0 slot is what made one image appear all over the page.
  if (key === 'hero' && props.config.hero_image_url) {
    return { url: props.config.hero_image_url, alt: fallbackAlt }
  }
  return null
}

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
const heroImg = computed(() => slotImage('hero'))
const problemImg = computed(() => slotImage('problem'))

const heroCta = computed(
  () =>
    pick({ bn: props.config.hero_cta_bn, en: props.config.hero_cta_en }) ||
    t('customer.page.getStarted'),
)

const config = computed(() => ({
  ...props.config,
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
}))

const visibleBenefits = computed(() =>
  props.config.benefits
    .map((item) => ({
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

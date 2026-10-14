<template>
  <div class="bg-stone-950 text-white">
    <!--
      Telegram support bubble: fixed bottom-right, page-specific chat link.
      Hidden when the operator hasn't set a support URL.
    -->
    <a
      v-if="config.telegram_support_url"
      :href="config.telegram_support_url"
      target="_blank"
      rel="noopener noreferrer"
      class="fixed bottom-6 right-6 z-40 flex size-12 items-center justify-center rounded-full bg-[#0088cc] text-white shadow-lg shadow-black/30 transition-transform hover:scale-110"
      :aria-label="t('customer.page.tgSupport')"
    >
      <Send :size="20" aria-hidden="true" />
    </a>

    <!--
      Hero: the whole first screen is one moment. Ambient brand light behind
      oversized type, a single CTA, nothing else. Without a hero image the
      section is purely typographic; with one, the image sits framed beneath.
    -->
    <section class="relative flex min-h-[100svh] items-center overflow-hidden bg-stone-950">
      <div class="ambient-blob -right-32 -top-32 size-[36rem] bg-brand-600" aria-hidden="true" />
      <div
        class="ambient-blob ambient-blob-2 -left-28 bottom-0 size-[30rem] bg-brand-800"
        aria-hidden="true"
      />
      <div class="dot-grid absolute inset-0 opacity-40" aria-hidden="true" />

      <div
        v-reveal
        class="relative mx-auto w-full max-w-4xl px-5 py-24 text-center sm:px-6 sm:py-28"
      >
        <span
          class="inline-flex items-center gap-1.5 rounded-full border border-white/20 bg-white/5 px-3 py-1 text-xs font-semibold text-stone-300 backdrop-blur"
        >
          <Lock :size="12" aria-hidden="true" />
          {{ t('customer.page.adultsOnly') }}
        </span>

        <h1
          class="copy-accent-dark mx-auto mt-8 max-w-3xl text-5xl font-black leading-[1.02] tracking-tight text-white sm:text-7xl"
        >
          {{ heroTitle }}
        </h1>

        <div
          class="mx-auto mt-8 h-1 w-24 rounded-full bg-gradient-to-r from-brand-400 to-brand-600"
          aria-hidden="true"
        />

        <p
          v-if="heroSubtitle"
          class="mx-auto mt-8 max-w-2xl text-lg leading-relaxed text-stone-300 sm:text-xl"
        >
          {{ heroSubtitle }}
        </p>

        <div class="mt-12 flex flex-col items-center gap-4 sm:flex-row">
          <button
            type="button"
            class="btn-primary cta-glow group w-full bg-brand-500 py-4 text-lg text-stone-950 shadow-lg shadow-brand-900/40 hover:bg-brand-400 sm:w-auto sm:px-14"
            @click="openCheckout"
          >
            {{ heroCta }}
            <ArrowRight
              :size="20"
              aria-hidden="true"
              class="transition-transform group-hover:translate-x-0.5"
            />
          </button>
          <button
            type="button"
            class="group inline-flex w-full items-center justify-center gap-2 rounded-lg border border-white/20 bg-white/5 px-8 py-4 text-base font-semibold text-white backdrop-blur transition-colors hover:border-brand-400/50 hover:bg-white/10 sm:w-auto"
            @click="scrollToVideo"
          >
            <Play :size="18" aria-hidden="true" />
            {{ t('customer.page.watchDemo') }}
          </button>
        </div>
        <!-- Our own locale string, so the emphasis markup is trusted content. -->
        <span
          class="mt-4 block text-xs text-stone-400"
          v-html="rich(t('customer.page.privateCheckout'))"
        />

        <ul
          v-if="heroPoints.length > 0"
          v-reveal
          class="reveal-stagger mx-auto mt-14 grid max-w-2xl gap-3 text-left sm:grid-cols-2"
        >
          <li
            v-for="(point, index) in heroPoints"
            :key="index"
            class="flex items-start gap-3 rounded-xl border border-white/10 bg-white/5 px-4 py-3 backdrop-blur"
          >
            <Check :size="18" aria-hidden="true" class="mt-0.5 shrink-0 text-brand-400" />
            <span class="text-sm leading-relaxed text-stone-200">{{ point }}</span>
          </li>
        </ul>
      </div>

      <!-- Scroll cue: a slow pulse at the bottom edge, decorative. -->
      <div
        class="pointer-events-none absolute bottom-6 left-1/2 -translate-x-1/2 text-stone-500"
        aria-hidden="true"
      >
        <ChevronDown :size="22" class="animate-bounce" />
      </div>
    </section>

    <!--
      Video: the page's centerpiece. A portrait frame with a hairline border
      and a soft brand glow, floating over the ambient background. The section
      hugs its content (no full-screen height): the hero's Watch-demo button
      scrolls here, and the heading must land at the top of the viewport.
    -->
    <section
      id="page-video"
      class="relative flex items-center overflow-hidden bg-stone-950 py-24 sm:py-32"
    >
      <div class="ambient-blob -left-24 top-1/4 size-[26rem] bg-brand-900" aria-hidden="true" />
      <div v-reveal class="relative mx-auto w-full max-w-3xl px-5 text-center sm:px-6">
        <p class="flex items-center justify-center gap-2 text-xs font-semibold text-brand-300">
          <span class="h-3 w-0.5 rounded-full bg-brand-400" aria-hidden="true" />
          <Play :size="16" aria-hidden="true" />
          {{ t('customer.page.videoKicker') }}
        </p>

        <div
          class="relative mx-auto mt-10 max-w-[min(24rem,calc(68svh*9/16))] rounded-[2rem] border border-white/10 bg-stone-900 p-2 shadow-2xl shadow-brand-950/60 ring-1 ring-brand-500/10"
        >
          <video
            ref="videoEl"
            :src="config.video_url"
            controls
            preload="metadata"
            playsinline
            class="aspect-[9/16] w-full rounded-[1.6rem] object-cover"
          />
        </div>

        <button
          type="button"
          class="btn-primary cta-glow group mt-10 w-full bg-brand-500 py-3.5 text-base text-stone-950 hover:bg-brand-400 sm:w-auto sm:px-12"
          @click="openCheckout"
        >
          {{ heroCta }}
          <ArrowRight
            :size="18"
            aria-hidden="true"
            class="transition-transform group-hover:translate-x-0.5"
          />
        </button>
      </div>
    </section>

    <!--
      Ending: the last full screen. The operator's closing line over a marquee
      of trust keywords, then one giant CTA. The marquee is decorative.
    -->
    <section class="relative flex min-h-[100svh] items-center overflow-hidden bg-stone-950">
      <div class="ambient-blob -right-24 bottom-0 size-[30rem] bg-brand-700" aria-hidden="true" />
      <div class="dot-grid absolute inset-0 opacity-30" aria-hidden="true" />

      <div
        v-reveal
        class="relative mx-auto w-full max-w-4xl px-5 py-24 text-center sm:px-6 sm:py-28"
      >
        <h2
          class="copy-accent-dark mx-auto max-w-3xl text-4xl font-black leading-[1.05] tracking-tight text-white sm:text-6xl"
        >
          {{ endingTitle }}
        </h2>
        <p v-if="endingNote" class="mx-auto mt-6 max-w-xl text-base text-stone-400 sm:text-lg">
          {{ endingNote }}
        </p>

        <div
          v-if="endingImg"
          class="img-hover group relative mx-auto mt-12 max-w-2xl overflow-hidden rounded-3xl border border-white/10 shadow-2xl shadow-black/50"
        >
          <img
            :src="endingImg.url"
            :alt="endingImg.alt"
            class="aspect-[16/10] w-full object-cover"
          />
        </div>

        <button
          type="button"
          class="btn-primary cta-glow group mx-auto mt-12 flex w-full items-center justify-center bg-brand-500 py-4 text-lg text-stone-950 shadow-xl shadow-brand-900/50 hover:bg-brand-400 sm:w-auto sm:px-16"
          @click="openCheckout"
        >
          {{ heroCta }}
          <ArrowRight
            :size="20"
            aria-hidden="true"
            class="transition-transform group-hover:translate-x-0.5"
          />
        </button>
      </div>

      <div class="absolute bottom-0 left-0 right-0 border-t border-white/5 py-4" aria-hidden="true">
        <div class="marquee-track flex w-max items-center">
          <span v-for="copy in 2" :key="copy" class="flex shrink-0 items-center">
            <span
              v-for="repeat in 3"
              :key="repeat"
              class="flex items-center whitespace-nowrap text-xs font-medium uppercase tracking-widest text-stone-600"
            >
              <Sparkles :size="12" aria-hidden="true" class="mx-6 shrink-0 text-brand-700" />
              {{ t('customer.page.trustMarquee') }}
            </span>
          </span>
        </div>
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
import { ArrowRight, Check, ChevronDown, Lock, Play, Send, Sparkles } from 'lucide-vue-next'
import { useContent } from '@/composables/useContent'
import { type PageImageMap, type SpotlightConfig } from '@/pages/templates/registry'
import { useCheckoutModal } from '@/composables/useCheckoutModal'

const { t } = useI18n()
const { pick } = useContent()
const { openCheckout } = useCheckoutModal()

/**
 * Emphasis in headings is authored as <strong> inside i18n strings and colored
 * by `.copy-accent-dark`. Everything that reaches v-html goes through
 * DOMPurify: the locale strings are ours, but the sanitizer is not optional.
 */
const rich = (value: string): string => DOMPurify.sanitize(value)

/**
 * Scroll-reveal, identical to the sales template's: one observer per element,
 * disconnect once visible, show immediately when the API is missing.
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
  config: SpotlightConfig
  /** Assigned images by slot; empty when nothing has been uploaded yet. */
  images?: PageImageMap
}>()

/**
 * The hero's title falls back to the page row's title: an operator who never
 * touched the template config still gets the page they named.
 */
const heroTitle = computed(
  () =>
    pick({ bn: props.config.hero_title_bn, en: props.config.hero_title_en }) ||
    pick({ bn: props.page.title_bn, en: props.page.title_en }) ||
    '',
)

const heroSubtitle = computed(
  () => pick({ bn: props.config.hero_subtitle_bn, en: props.config.hero_subtitle_en }) ?? '',
)

const heroCta = computed(
  () =>
    pick({ bn: props.config.hero_cta_bn, en: props.config.hero_cta_en }) ||
    t('customer.page.getStarted'),
)

/** Hero bullets: one per line, blanks dropped. */
const heroPoints = computed(() =>
  (pick({ bn: props.config.hero_points_bn, en: props.config.hero_points_en }) ?? '')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== ''),
)

/** The hero's secondary button: a smooth glide to the video section. */
const scrollToVideo = (): void => {
  document.getElementById('page-video')?.scrollIntoView({ behavior: 'smooth' })
}

const endingTitle = computed(
  () =>
    pick({ bn: props.config.ending_title_bn, en: props.config.ending_title_en }) || heroTitle.value,
)

const endingNote = computed(
  () => pick({ bn: props.config.ending_note_bn, en: props.config.ending_note_en }) ?? '',
)

const endingImg = computed(() => {
  const direct = props.images?.ending
  if (direct?.url) {
    return {
      url: direct.url,
      alt:
        pick({ bn: props.config.ending_image_alt_bn, en: props.config.ending_image_alt_en }) ||
        direct.alt_en ||
        direct.alt_bn ||
        endingTitle.value,
    }
  }
  if (props.config.ending_image_url) {
    return {
      url: props.config.ending_image_url,
      alt:
        pick({ bn: props.config.ending_image_alt_bn, en: props.config.ending_image_alt_en }) ||
        endingTitle.value,
    }
  }
  return null
})
</script>

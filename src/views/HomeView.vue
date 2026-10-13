<template>
  <main class="relative mx-auto max-w-4xl px-4 py-10 sm:px-6 lg:py-14">
    <!-- Dot-grid backdrop behind the hero, fading out downward. -->
    <div class="dot-grid pointer-events-none absolute inset-x-0 top-0 h-72" aria-hidden="true" />

    <section class="relative max-w-2xl">
      <!-- The index's own words win over the bundled copy: the settings fetch is
           best-effort, so the copy keys are the fallback a slow database leaves. -->
      <h1 class="text-3xl font-black tracking-tight text-stone-900 sm:text-5xl">
        {{ heading }}
      </h1>
      <p class="mt-4 text-lg text-stone-600">{{ subheading }}</p>

      <!-- How it works: three beats, one line. -->
      <ol class="mt-6 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-stone-500">
        <li v-for="(step, index) in steps" :key="step.key" class="flex items-center gap-2">
          <span
            class="grid size-6 place-items-center rounded-full bg-brand-100 text-xs font-bold text-brand-800 ltr-value"
          >
            {{ index + 1 }}
          </span>
          {{ t(step.key) }}
          <ChevronRight
            v-if="index < steps.length - 1"
            :size="14"
            aria-hidden="true"
            class="text-stone-300"
          />
        </li>
      </ol>
    </section>

    <div
      v-if="loading"
      class="mt-16 flex justify-center"
      role="status"
      :aria-label="t('customer.common.loading')"
    >
      <span
        class="inline-block size-9 animate-spin rounded-full border-2 border-stone-200 border-t-brand-600 align-middle"
      />
    </div>

    <p v-else-if="error" class="alert-error mt-10" role="alert">{{ error }}</p>

    <div v-else-if="pages.length === 0" class="card empty-state mt-10">
      <span
        class="mx-auto mb-4 grid size-14 place-items-center rounded-full bg-brand-100 text-brand-700"
      >
        <AppIcon name="link" :size="26" />
      </span>
      <p class="font-medium text-stone-700">{{ t('customer.home.empty') }}</p>
    </div>

    <div v-else class="mt-12 grid gap-5 sm:grid-cols-2">
      <PageCard
        v-for="page in pages"
        :key="page.id"
        :slug="page.slug"
        :title-bn="page.title_bn"
        :title-en="page.title_en"
        :cta-label-bn="page.unlock_cta_label_bn"
        :cta-label-en="page.unlock_cta_label_en"
        :template-config="page.template_config"
      />
    </div>
  </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { ChevronRight } from 'lucide-vue-next'
import AppIcon from '@/components/AppIcon.vue'
import PageCard from '@/components/customer/PageCard.vue'
import { useContent } from '@/composables/useContent'
import { useSiteSettings } from '@/composables/useSiteSettings'

import { rpcList } from '@/lib/rpc'

const { t } = useI18n()
const { pick } = useContent()
const { settings } = useSiteSettings()

// The operator's index words, falling back to the shipped copy when unset.
const heading = computed(
  () =>
    pick({
      bn: settings.value.index_heading_bn,
      en: settings.value.index_heading_en,
    }) ?? t('customer.home.heading'),
)
const subheading = computed(
  () =>
    pick({
      bn: settings.value.index_subheading_bn,
      en: settings.value.index_subheading_en,
    }) ?? t('customer.home.subheading'),
)

/** The three beats of the purchase, as the index states them up front. */
const steps = [
  { key: 'customer.home.stepPick' },
  { key: 'customer.home.stepPay' },
  { key: 'customer.home.stepUnlock' },
]

// `list_public_pages` returns the `pages_public` view, so the teaser and
// CTA columns are the `*_md_*` variants.
interface PublicPageRow {
  id: string
  slug: string
  title_bn: string | null
  title_en: string | null
  unlock_cta_label_bn: string | null
  unlock_cta_label_en: string | null
  template_config: Record<string, unknown>
}

const pages = ref<PublicPageRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

onMounted(async () => {
  try {
    const { data, error: rpcError } = await rpcList<PublicPageRow>('list_public_pages')

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    pages.value = (data as PublicPageRow[]) || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load pages'
  } finally {
    loading.value = false
  }
})
</script>

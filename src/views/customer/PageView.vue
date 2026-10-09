<template>
  <main class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
    <!-- A hidden page is standalone: it is sold by its URL alone, so it shows
         no way back to the index, from the page or the layout header. -->
    <router-link
      v-if="!isStandalone"
      to="/"
      class="mb-6 inline-flex items-center gap-2 text-sm font-medium text-stone-600 hover:text-stone-900"
    >
      <AppIcon name="arrowLeft" :size="16" />
      {{ t('customer.paywall.back') }}
    </router-link>

    <div v-if="loading" class="empty-state">{{ t('customer.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <!-- `get_public_page` returns no row for an unknown or inactive slug, so
           without this branch the page rendered blank. -->
    <div v-else-if="!page" class="card card-pad text-center">
      <AppIcon name="link" :size="28" class="mx-auto mb-3 text-stone-400" />
      <h1 class="text-xl font-semibold text-stone-900">{{ t('customer.notFound.title') }}</h1>
      <MarkdownBody :source="t('customer.notFound.body')" class="mt-2 text-sm text-stone-600" />
      <router-link to="/" class="btn-primary mt-6">{{ t('customer.notFound.cta') }}</router-link>
    </div>

    <template v-else>
      <!-- The template owns the page's selling content; the checkout section
           is placed by the template, wherever the template's flow ends. -->
      <component
        :is="template.renderer"
        :page="renderPage"
        :config="templateConfig"
        :images="pageImages"
      >
        <template #purchase>
          <PageCheckoutSection :page="checkoutPage" />
        </template>
      </component>
    </template>
  </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute } from 'vue-router'
import { rpc } from '@/lib/rpc'
import type { PublicPageDetail } from '@/lib/rpc'
import MarkdownBody from '@/components/MarkdownBody.vue'
import AppIcon from '@/components/AppIcon.vue'
import PageCheckoutSection from '@/components/customer/PageCheckoutSection.vue'
import { usePageStandalone } from '@/composables/usePageStandalone'
import { normalizeConfig, templateFor } from '@/pages/templates/registry'
import type { CheckoutPage } from '@/composables/usePageCheckout'

const { t } = useI18n()
const route = useRoute()
const { setStandalone, isStandalone } = usePageStandalone()

const loading = ref(true)
const error = ref<string | null>(null)

const slug = computed(() => route.params.slug as string)

interface Page {
  id: string
  slug: string
  title_bn: string | null
  title_en: string | null
  teaser_md_bn: string | null
  teaser_md_en: string | null
  unlock_cta_label_bn: string | null
  unlock_cta_label_en: string | null
  unlock_cta_url: string | null
  /**
   * Which code-side layout draws this page, and that layout's config. The
   * config is normalized on read so the renderer never meets a missing field.
   */
  template: string
  template_config: unknown
  is_listed: boolean
  min_amount: number | null
  min_hidden: boolean
  amount_presets: number[] | null
  gateways: unknown[]
}

const page = ref<Page | null>(null)

/**
 * The template the page renders with, resolved from the registry. Everything
 * template-shaped about the render — which layout, which config, which
 * component — comes from this one lookup.
 */
const template = computed(() => templateFor(page.value?.template))
const templateConfig = computed(() =>
  normalizeConfig(template.value.id, page.value?.template_config),
)
// The v-else branch guarantees a page at render time; this alias records that
// guarantee in one place instead of a non-null assertion in the markup.
const renderPage = computed(() => page.value as Page)

/**
 * The assigned images, keyed by slot as the public payload delivers them.
 * Templates render what is assigned and collapse what is not.
 */
const pageImages = computed(
  () => (page.value as unknown as { images?: Record<string, unknown> })?.images ?? {},
)

/**
 * The checkout reads exactly the slice of the page it needs - gateways,
 * pricing, CTA labels - through this projection.
 */
const checkoutPage = computed(() => page.value as unknown as CheckoutPage)

onMounted(async () => {
  try {
    const { data: pageData, error: pageError } = await rpc<PublicPageDetail>('get_public_page', {
      p_slug: slug.value,
    })

    if (pageError) {
      error.value = pageError.message
      return
    }

    page.value = pageData as unknown as Page

    // A hidden page is standalone: no way back to the index, anywhere.
    setStandalone(page.value.is_listed === false)
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load page'
  } finally {
    loading.value = false
  }
})
</script>

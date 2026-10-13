<template>
  <!--
    Full-bleed templates draw their own edge-to-edge background and own the
    viewport: the padded, centered shell would show around them as a light
    frame. Everything else keeps the classic reading shell.
  -->
  <!--
    Full-bleed templates draw their own edge-to-edge background and own the
    viewport: the padded, centered shell would show around them as a light
    frame. Everything else keeps the classic reading shell. The shell remembers
    the slug's template in sessionStorage, so a reload of a dark page keeps the
    dark chrome through the loading state instead of flashing white.
  -->
  <main :class="shellDark ? '' : 'mx-auto max-w-3xl px-4 py-10 sm:px-6'">
    <!-- A hidden page is standalone: it is sold by its URL alone, so it shows
         no way back to the index, from the page or the layout header. -->
    <router-link
      v-if="!isStandalone && !loading"
      to="/"
      class="mb-6 inline-flex items-center gap-2 text-sm font-medium"
      :class="shellDark ? 'text-stone-400 hover:text-white' : 'text-stone-600 hover:text-stone-900'"
    >
      <AppIcon name="arrowLeft" :size="16" />
      {{ t('customer.paywall.back') }}
    </router-link>

    <!--
      The loading screen is a branded spinner on a full-viewport dark surface:
      it owns the screen completely while the page - and its chrome - are
      still being decided.
    -->
    <div
      v-if="loading"
      class="-mx-4 -my-10 flex min-h-dvh items-center justify-center bg-stone-950 sm:-mx-6"
      role="status"
      :aria-label="t('customer.common.loading')"
    >
      <span
        class="inline-block size-9 animate-spin rounded-full border-2 border-white/15 border-t-brand-400 align-middle"
      />
    </div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <!-- `get_public_page` returns no row for an unknown or inactive slug, so
           without this branch the page rendered blank. -->
    <div
      v-else-if="!page"
      class="card card-pad text-center"
      :class="shellDark ? 'border-white/10 bg-white/5' : ''"
    >
      <AppIcon name="link" :size="28" class="mx-auto mb-3 text-stone-400" />
      <h1 class="text-xl font-semibold" :class="shellDark ? 'text-white' : 'text-stone-900'">
        {{ t('customer.notFound.title') }}
      </h1>
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
          <!--
            Full-bleed templates carry their own CTAs and no checkout section:
            the section hosts only the modal, invisibly.
          -->
          <PageCheckoutSection :page="checkoutPage" :bare="template.fullBleed === true" />
        </template>
      </component>
    </template>
  </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute } from 'vue-router'
import { rpc } from '@/lib/rpc'
import type { PublicPageDetail } from '@/lib/rpc'
import MarkdownBody from '@/components/MarkdownBody.vue'
import AppIcon from '@/components/AppIcon.vue'
import PageCheckoutSection from '@/components/customer/PageCheckoutSection.vue'
import { usePageStandalone } from '@/composables/usePageStandalone'
import { usePageShell } from '@/composables/usePageShell'
import { normalizeConfig, templateFor } from '@/pages/templates/registry'
import type { CheckoutPage } from '@/composables/usePageCheckout'

const { t } = useI18n()
const route = useRoute()
const { setStandalone, isStandalone } = usePageStandalone()
const { setFullBleed, setPageLoading } = usePageShell()

// The chrome hides while this view fetches; the loading surface owns the
// viewport. Set at setup (not onMounted) so the very first render is covered.
setPageLoading(true)
onUnmounted(() => setPageLoading(false))

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

/**
 * Whether the shell should be dark right now: the loaded template's own
 * choice, or - while the page is still in flight - what this slug rendered
 * last time, from sessionStorage. That memory is what keeps a reload of a
 * dark page from flashing the light shell under the spinner.
 */
const loadingFullBleed = ref(false)

const rememberTemplate = (): void => {
  loadingFullBleed.value = sessionStorage.getItem(`cofibuy:tpl:${slug.value}`) === 'sales-landing'
  // The remembered page was chrome-free too (hidden, or a sales page): apply
  // that now, so the topbar and back link never flash over the spinner.
  setStandalone(sessionStorage.getItem(`cofibuy:standalone:${slug.value}`) === '1')
}

const shellDark = computed(() => template.value.fullBleed === true || loadingFullBleed.value)

watch(slug, rememberTemplate, { immediate: true })
// The layout's chrome follows the shell, dark included, from the first frame.
watch(shellDark, (value) => setFullBleed(value), { immediate: true })
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

    // Remember the template and the chrome state, so the next load of this
    // slug knows both before the fetch answers.
    sessionStorage.setItem(`cofibuy:tpl:${slug.value}`, page.value.template)
    sessionStorage.setItem(
      `cofibuy:standalone:${slug.value}`,
      String(page.value.is_listed === false || template.value.fullBleed === true),
    )

    // A hidden page is standalone: no way back to the index, anywhere. A
    // full-bleed sales page is standalone by design too - its own marquee and
    // sections are the whole experience, and the site chrome would frame it.
    setStandalone(page.value.is_listed === false || template.value.fullBleed === true)
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load page'
  } finally {
    loading.value = false
    setPageLoading(false)
  }
})

onUnmounted(() => setFullBleed(false))
</script>

<template>
  <main class="mx-auto max-w-4xl px-4 py-10 sm:px-6 lg:py-14">
    <section class="max-w-2xl">
      <!-- The index's own words win over the bundled copy: the settings fetch is
           best-effort, so the copy keys are the fallback a slow database leaves. -->
      <h1 class="text-3xl font-bold tracking-tight text-stone-900 sm:text-4xl">
        {{ heading }}
      </h1>
      <p class="mt-3 text-base text-stone-600">{{ subheading }}</p>
    </section>

    <div v-if="loading" class="empty-state">{{ t('customer.common.loading') }}</div>

    <p v-else-if="error" class="alert-error mt-10" role="alert">{{ error }}</p>

    <div v-else-if="links.length === 0" class="card empty-state mt-10">
      <AppIcon name="link" :size="28" class="mx-auto mb-3 text-stone-400" />
      <p class="font-medium text-stone-700">{{ t('customer.home.empty') }}</p>
    </div>

    <div v-else class="mt-10 grid gap-5 sm:grid-cols-2">
      <PageCard
        v-for="link in links"
        :key="link.id"
        :slug="link.slug"
        :title-bn="link.title_bn"
        :title-en="link.title_en"
        :teaser-md-bn="link.teaser_md_bn"
        :teaser-md-en="link.teaser_md_en"
        :cta-label-bn="link.unlock_cta_label_bn"
        :cta-label-en="link.unlock_cta_label_en"
      />
    </div>
  </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import AppIcon from '@/components/AppIcon.vue'
import PageCard from '@/components/customer/PageCard.vue'
import { useContent } from '@/composables/useContent'
import { useSiteSettings } from '@/composables/useSiteSettings'
import type { PublicPage } from '@/lib/rpc'
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

// `list_public_pages` returns the `paywall_links_public` view, so the teaser and
// CTA columns are the `*_md_*` variants.
interface PublicLink {
  id: string
  slug: string
  title_bn: string | null
  title_en: string | null
  teaser_md_bn: string | null
  teaser_md_en: string | null
  unlock_cta_label_bn: string | null
  unlock_cta_label_en: string | null
}

const links = ref<PublicLink[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

onMounted(async () => {
  try {
    const { data, error: rpcError } = await rpcList<PublicPage>('list_public_pages')

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    links.value = (data as PublicLink[]) || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load links'
  } finally {
    loading.value = false
  }
})
</script>

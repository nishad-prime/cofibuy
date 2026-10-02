<template>
  <div class="mx-auto max-w-4xl px-4 py-8">
    <h1 class="mb-8 text-3xl font-bold text-gray-900">{{ t('app.title') }}</h1>

    <div v-if="loading" class="py-8 text-center text-gray-600">Loading...</div>

    <div v-else-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
      {{ error }}
    </div>

    <div v-else-if="links.length === 0" class="py-8 text-center text-gray-600">
      No links available.
    </div>

    <div v-else class="grid gap-6 md:grid-cols-2">
      <LinkCard
        v-for="link in links"
        :key="link.id"
        :slug="link.slug"
        :title-bn="link.title_bn"
        :title-en="link.title_en"
        :teaser-bn="link.teaser_bn"
        :teaser-en="link.teaser_en"
        :cta-label-bn="link.cta_label_bn"
        :cta-label-en="link.cta_label_en"
      />
    </div>

    <LanguageToggle class="mt-8" />
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { getSupabase } from '@/lib/supabase'
import LinkCard from '@/components/customer/LinkCard.vue'
import LanguageToggle from '@/components/LanguageToggle.vue'

const { t } = useI18n()
const supabase = getSupabase()

interface PublicLink {
  id: string
  slug: string
  title_bn: string | null
  title_en: string | null
  teaser_bn: string | null
  teaser_en: string | null
  cta_label_bn: string | null
  cta_label_en: string | null
}

const links = ref<PublicLink[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

onMounted(async () => {
  try {
    const { data, error: rpcError } = await (supabase.rpc as any)('list_public_links')

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

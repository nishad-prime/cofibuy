<template>
  <div>
    <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="page-title">{{ t('admin.pages.heading') }}</h1>
        <p class="page-subtitle">{{ t('admin.pages.subtitle') }}</p>
      </div>
      <router-link to="/admin/pages/new" class="btn-primary">
        <AppIcon name="plus" :size="18" />
        {{ t('admin.pages.new') }}
      </router-link>
    </header>

    <div v-if="loading" class="empty-state">{{ t('admin.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <div v-else-if="pages.length === 0" class="card empty-state">
      <AppIcon name="link" :size="28" class="mx-auto mb-3 text-stone-400" />
      <p class="font-medium text-stone-700">{{ t('admin.pages.empty') }}</p>
      <p class="mt-1">{{ t('admin.pages.subtitle') }}</p>
    </div>

    <div v-else class="table-wrap">
      <div class="table-scroll">
        <table class="min-w-full divide-y divide-stone-200">
          <thead class="bg-stone-50">
            <tr>
              <th class="th">{{ t('admin.pages.page') }}</th>
              <th class="th">{{ t('admin.pages.slug') }}</th>
              <th class="th">{{ t('admin.pages.price') }}</th>
              <th class="th">{{ t('admin.common.status') }}</th>
              <th class="th">
                <span class="sr-only">{{ t('admin.common.actions') }}</span>
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-stone-200">
            <tr v-for="page in pages" :key="page.id" class="row-link">
              <td class="td">
                <p class="font-medium text-stone-900">
                  {{ page.title_en || page.title_bn || '—' }}
                </p>
                <p v-if="page.title_en && page.title_bn" class="text-xs text-stone-500">
                  {{ page.title_bn }}
                </p>
              </td>
              <td class="td">
                <router-link :to="`/${page.slug}`" class="ltr-value text-brand-700 hover:underline">
                  /{{ page.slug }}
                </router-link>
              </td>
              <td class="td">
                <span v-if="Number(page.min_amount_override) > 0" class="ltr-value">
                  {{ formatMoney(Number(page.min_amount_override), 'en', currency) }}
                </span>
                <span v-else class="text-xs text-stone-500">{{
                  t('admin.pages.siteDefault')
                }}</span>
              </td>
              <td class="td">
                <!-- Three states, not two. "Hidden" used to mean `is_active =
                     false`, and reusing it for "not in the index" would make an
                     unlisted page indistinguishable from a draft - when one is
                     fully buyable and the other cannot be opened at all. -->
                <span v-if="!page.is_active" class="badge-muted">{{
                  t('admin.pages.statusDraft')
                }}</span>
                <span v-else-if="!page.is_listed" class="badge-warn">{{
                  t('admin.pages.statusUnlisted')
                }}</span>
                <span v-else class="badge-ok">{{ t('admin.pages.statusLive') }}</span>
              </td>
              <td class="td">
                <div class="flex items-center justify-end gap-1">
                  <router-link
                    :to="`/admin/pages/${page.id}/edit`"
                    class="btn-secondary !px-3 !py-1.5 !text-xs"
                    >{{ t('admin.pages.edit') }}
                  </router-link>
                  <button
                    type="button"
                    class="btn-secondary !px-2.5 !py-1.5 text-red-700 hover:!bg-red-50"
                    :aria-label="`Delete ${page.title_en || page.slug}`"
                    @click="deleteLink(page.id)"
                  >
                    <AppIcon name="trash" :size="16" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { formatMoney } from '@/lib/money'
import { useAdminCurrency } from '@/composables/useAdminCurrency'
import AppIcon from '@/components/AppIcon.vue'
import { rpc } from '@/lib/rpc'
import { useAdminI18n } from '@/i18n/admin'

const { t } = useAdminI18n()
const { currency, load: loadCurrency } = useAdminCurrency()

/** The site's default minimum, shown as the real number behind "site default". */
const defaultMin = ref(0)

interface AdminPageRow {
  id: string
  slug: string
  title_en: string | null
  title_bn: string | null
  is_active: boolean
  is_listed: boolean
  sort_order: number
  min_amount_override: number | null
  hide_min_override: boolean | null
}

const pages = ref<AdminPageRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const loadPages = async (): Promise<void> => {
  error.value = null
  try {
    const { data, error: rpcError } = await rpc<Record<string, unknown>>('admin_pages')
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    pages.value = (data ?? []) as unknown as typeof pages.value
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load links'
  } finally {
    loading.value = false
  }
}

const deleteLink = async (id: string): Promise<void> => {
  if (!confirm('Delete this page? Existing orders keep their reference.')) return
  try {
    // `p_page_id`, not `p_id`. PostgREST matches on the exact argument name, so
    // the wrong one is a 404 rather than an error message anyone would read.
    const { error: rpcError } = await rpc<Record<string, unknown>>('admin_delete_page', {
      p_page_id: id,
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    await loadPages()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to delete page'
  }
}

onMounted(async () => {
  void loadCurrency()
  void loadPages()
  // The site's default minimum: the number behind every "site default" price.
  const { data } = await rpc<{ default_min?: unknown }>('admin_stats')
  const min = Number(data?.default_min)
  if (Number.isFinite(min) && min > 0) defaultMin.value = min
})
</script>

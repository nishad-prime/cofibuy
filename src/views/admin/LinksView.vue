<template>
  <div>
    <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="page-title">Links</h1>
        <p class="page-subtitle">Each link is one sellable page customers open.</p>
      </div>
      <router-link to="/admin/links/new" class="btn-primary">
        <AppIcon name="plus" :size="18" />
        New link
      </router-link>
    </header>

    <div v-if="loading" class="empty-state">Loading...</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <div v-else-if="links.length === 0" class="card empty-state">
      <AppIcon name="link" :size="28" class="mx-auto mb-3 text-stone-400" />
      <p class="font-medium text-stone-700">No links yet</p>
      <p class="mt-1">Create a link to publish a report customers can unlock by paying.</p>
    </div>

    <div v-else class="table-wrap">
      <div class="table-scroll">
        <table class="min-w-full divide-y divide-stone-200">
          <thead class="bg-stone-50">
            <tr>
              <th class="th">Link</th>
              <th class="th">Slug</th>
              <th class="th">Price</th>
              <th class="th">Status</th>
              <th class="th"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-stone-200">
            <tr v-for="link in links" :key="link.id" class="row-link">
              <td class="td">
                <p class="font-medium text-stone-900">
                  {{ link.title_en || link.title_bn || '—' }}
                </p>
                <p v-if="link.title_en && link.title_bn" class="text-xs text-stone-500">
                  {{ link.title_bn }}
                </p>
              </td>
              <td class="td">
                <router-link
                  :to="`/l/${link.slug}`"
                  class="ltr-value text-brand-700 hover:underline"
                >
                  /l/{{ link.slug }}
                </router-link>
              </td>
              <td class="td">
                <span v-if="Number(link.min_amount_override) > 0" class="ltr-value">
                  {{ formatMoney(Number(link.min_amount_override), 'en', currency) }}
                </span>
                <span v-else class="text-xs text-stone-500">Site default</span>
              </td>
              <td class="td">
                <!-- Three states, not two. "Hidden" used to mean `is_active =
                     false`, and reusing it for "not in the index" would make an
                     unlisted link indistinguishable from a draft - when one is
                     fully buyable and the other cannot be opened at all. -->
                <span v-if="!link.is_active" class="badge-muted">Draft</span>
                <span v-else-if="!link.is_listed" class="badge-warn">Unlisted</span>
                <span v-else class="badge-ok">Live</span>
              </td>
              <td class="td">
                <div class="flex items-center justify-end gap-1">
                  <router-link
                    :to="`/admin/links/${link.id}/edit`"
                    class="btn-secondary !px-3 !py-1.5 !text-xs"
                  >
                    Edit
                  </router-link>
                  <button
                    type="button"
                    class="btn-secondary !px-2.5 !py-1.5 text-red-700 hover:!bg-red-50"
                    :aria-label="`Delete ${link.title_en || link.slug}`"
                    @click="deleteLink(link.id)"
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
import { getSupabase } from '@/lib/supabase'
import { formatMoney } from '@/lib/money'
import { useAdminCurrency } from '@/composables/useAdminCurrency'
import AppIcon from '@/components/AppIcon.vue'

const supabase = getSupabase()
const { currency, load: loadCurrency } = useAdminCurrency()

const links = ref<any[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const loadLinks = async (): Promise<void> => {
  error.value = null
  try {
    const { data, error: rpcError } = await (supabase.rpc as any)('admin_links')
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    links.value = data || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load links'
  } finally {
    loading.value = false
  }
}

const deleteLink = async (id: string): Promise<void> => {
  if (!confirm('Delete this link? Existing orders keep their reference.')) return
  try {
    // `p_link_id`, not `p_id`. PostgREST matches on the exact argument name, so
    // the wrong one is a 404 rather than an error message anyone would read.
    const { error: rpcError } = await (supabase.rpc as any)('admin_delete_link', {
      p_link_id: id,
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    await loadLinks()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to delete link'
  }
}

onMounted(() => {
  void loadCurrency()
  void loadLinks()
})
</script>

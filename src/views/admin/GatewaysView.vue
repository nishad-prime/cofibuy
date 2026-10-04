<template>
  <div>
    <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="page-title">Payment methods</h1>
        <p class="page-subtitle">Accounts customers pay to, and the evidence they must submit.</p>
      </div>
      <router-link to="/admin/gateways/new" class="btn-primary">
        <AppIcon name="plus" :size="18" />
        New method
      </router-link>
    </header>

    <div v-if="loading" class="empty-state">Loading...</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <div v-else-if="gateways.length === 0" class="card empty-state">
      <AppIcon name="card" :size="28" class="mx-auto mb-3 text-stone-400" />
      <p class="font-medium text-stone-700">No payment methods yet</p>
      <p class="mt-1">Add bKash, Nagad, or a bank account so customers can pay.</p>
    </div>

    <div v-else class="table-wrap">
      <div class="table-scroll">
        <table class="min-w-full divide-y divide-stone-200">
          <thead class="bg-stone-50">
            <tr>
              <th class="th">Name</th>
              <th class="th">Account</th>
              <th class="th">Evidence fields</th>
              <th class="th">Status</th>
              <th class="th"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-stone-200">
            <tr v-for="gw in gateways" :key="gw.id" class="row-link">
              <td class="td">
                <p class="font-medium text-stone-900">{{ gw.name_en || gw.name_bn || '—' }}</p>
                <p class="text-xs text-stone-500 uppercase">{{ gw.kind }}</p>
              </td>
              <td class="td">
                <span v-if="gw.account_number" class="ltr-value block">
                  {{ gw.account_number }}
                </span>
                <span v-if="gw.account_name" class="block text-xs text-stone-500">
                  {{ gw.account_name }}
                </span>
                <span v-if="!gw.account_number && !gw.account_name" class="text-stone-400">—</span>
              </td>
              <td class="td">
                <span
                  v-if="fieldCount(gw) > 0"
                  class="badge-muted ltr-value"
                  :title="fieldKeys(gw).join(', ')"
                >
                  {{ fieldCount(gw) }} · {{ fieldKeys(gw).join(', ') }}
                </span>
                <span v-else class="text-stone-400">None</span>
              </td>
              <td class="td">
                <span :class="gw.is_active ? 'badge-ok' : 'badge-muted'">
                  {{ gw.is_active ? 'Active' : 'Hidden' }}
                </span>
              </td>
              <td class="td">
                <div class="flex items-center justify-end gap-1">
                  <router-link
                    :to="`/admin/gateways/${gw.id}/edit`"
                    class="btn-secondary !px-3 !py-1.5 !text-xs"
                  >
                    Edit
                  </router-link>
                  <button
                    type="button"
                    class="btn-secondary !px-2.5 !py-1.5 text-red-700 hover:!bg-red-50"
                    :aria-label="`Delete ${gw.name_en || 'gateway'}`"
                    @click="deleteGateway(gw.id)"
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
import AppIcon from '@/components/AppIcon.vue'

const supabase = getSupabase()
const gateways = ref<any[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const fieldCount = (gw: any): number => gw.evidence_fields?.length ?? 0

const fieldKeys = (gw: any): string[] => (gw.evidence_fields ?? []).map((f: any) => f.key)

const loadGateways = async (): Promise<void> => {
  error.value = null
  try {
    const { data, error: rpcError } = await (supabase.rpc as any)('admin_gateways')
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    gateways.value = data || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load gateways'
  } finally {
    loading.value = false
  }
}

const deleteGateway = async (id: string): Promise<void> => {
  if (!confirm('Delete this payment method? Orders that already reference it keep their copy.'))
    return
  try {
    // `p_gateway_id`, not `p_id`, to match `api.admin_delete_gateway(uuid)`.
    const { error: rpcError } = await (supabase.rpc as any)('admin_delete_gateway', {
      p_gateway_id: id,
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    await loadGateways()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to delete'
  }
}

onMounted(loadGateways)
</script>

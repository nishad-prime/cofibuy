<template>
  <div>
    <div class="mb-6 flex items-center justify-between">
      <h1 class="text-2xl font-bold text-gray-900">Payment Methods</h1>
      <router-link
        to="/admin/gateways/new"
        class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
      >
        New Method
      </router-link>
    </div>

    <div v-if="loading" class="text-gray-600">Loading...</div>
    <div v-else-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">{{ error }}</div>
    <div
      v-else-if="gateways.length === 0"
      class="rounded-lg bg-gray-50 p-8 text-center text-gray-600"
    >
      No gateways found.
    </div>

    <div v-else class="overflow-hidden rounded-lg border border-gray-200 bg-white">
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Name
            </th>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Kind
            </th>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Active
            </th>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Actions
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-200 bg-white">
          <tr v-for="gw in gateways" :key="gw.id">
            <td class="px-6 py-4 text-sm text-gray-900">{{ gw.name_en || gw.name_bn || '-' }}</td>
            <td class="px-6 py-4 text-sm text-gray-500">{{ gw.kind }}</td>
            <td class="px-6 py-4 text-sm text-gray-500">{{ gw.active ? 'Yes' : 'No' }}</td>
            <td class="px-6 py-4 text-sm space-x-2">
              <router-link
                :to="`/admin/gateways/${gw.id}/edit`"
                class="text-blue-600 hover:underline"
                >Edit</router-link
              >
              <button @click="deleteGateway(gw.id)" class="text-red-600 hover:underline">
                Delete
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getSupabase } from '@/lib/supabase'

const supabase = getSupabase()
const gateways = ref<any[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const loadGateways = async (): Promise<void> => {
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
  if (!confirm('Delete this gateway?')) return
  try {
    const { error: rpcError } = await (supabase.rpc as any)('admin_delete_gateway', { p_id: id })
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

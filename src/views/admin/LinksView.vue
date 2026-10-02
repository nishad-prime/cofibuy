<template>
  <div>
    <div class="mb-6 flex items-center justify-between">
      <h1 class="text-2xl font-bold text-gray-900">Links</h1>
      <router-link
        to="/admin/links/new"
        class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
      >
        New Link
      </router-link>
    </div>

    <div v-if="loading" class="text-gray-600">Loading...</div>

    <div v-else-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
      {{ error }}
    </div>

    <div v-else-if="links.length === 0" class="rounded-lg bg-gray-50 p-8 text-center text-gray-600">
      No links found.
    </div>

    <div v-else class="overflow-hidden rounded-lg border border-gray-200 bg-white">
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Slug
            </th>
            <th
              class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
            >
              Title
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
          <tr v-for="link in links" :key="link.id">
            <td class="px-6 py-4 text-sm text-gray-900">{{ link.slug }}</td>
            <td class="px-6 py-4 text-sm text-gray-900">
              {{ link.title_en || link.title_bn || '-' }}
            </td>
            <td class="px-6 py-4 text-sm text-gray-500">{{ link.active ? 'Yes' : 'No' }}</td>
            <td class="px-6 py-4 text-sm space-x-2">
              <router-link
                :to="`/admin/links/${link.id}/edit`"
                class="text-blue-600 hover:underline"
              >
                Edit
              </router-link>
              <button @click="deleteLink(link.id)" class="text-red-600 hover:underline">
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

const links = ref<any[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const loadLinks = async (): Promise<void> => {
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
  if (!confirm('Delete this link?')) return
  try {
    const { error: rpcError } = await (supabase.rpc as any)('admin_delete_link', { p_id: id })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    await loadLinks()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to delete link'
  }
}

onMounted(loadLinks)
</script>

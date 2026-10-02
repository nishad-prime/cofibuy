<template>
  <div>
    <h1 class="mb-6 text-2xl font-bold text-gray-900">Team</h1>

    <div v-if="loading" class="text-gray-600">Loading...</div>
    <div v-else-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">{{ error }}</div>

    <div v-else class="space-y-6">
      <div class="rounded-lg border border-gray-200 bg-white p-6">
        <h2 class="mb-4 text-lg font-semibold">Add Team Member</h2>
        <form @submit.prevent="addMember" class="flex space-x-4">
          <input
            v-model="email"
            type="email"
            required
            placeholder="Email"
            class="flex-1 rounded-md border border-gray-300 px-3 py-2"
          />
          <select v-model="role" class="rounded-md border border-gray-300 px-3 py-2">
            <option value="staff">Staff</option>
            <option value="owner">Owner</option>
          </select>
          <button
            type="submit"
            :disabled="adding"
            class="rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:bg-gray-400"
          >
            Add
          </button>
        </form>
      </div>

      <div class="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th
                class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
              >
                User ID
              </th>
              <th
                class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
              >
                Staff
              </th>
              <th
                class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
              >
                Owner
              </th>
              <th
                class="px-6 py-3 text-left text-xs font-medium tracking-wider text-gray-500 uppercase"
              >
                Actions
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200 bg-white">
            <tr v-for="member in team" :key="member.user_id">
              <td class="px-6 py-4 text-sm text-gray-900">{{ member.user_id }}</td>
              <td class="px-6 py-4 text-sm text-gray-500">{{ member.is_staff ? 'Yes' : 'No' }}</td>
              <td class="px-6 py-4 text-sm text-gray-500">{{ member.is_owner ? 'Yes' : 'No' }}</td>
              <td class="px-6 py-4 text-sm">
                <button @click="removeMember(member.user_id)" class="text-red-600 hover:underline">
                  Remove
                </button>
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

const supabase = getSupabase()

const team = ref<any[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const email = ref('')
const role = ref('staff')
const adding = ref(false)

const loadTeam = async (): Promise<void> => {
  try {
    const { data, error: rpcError } = await (supabase.rpc as any)('admin_team')
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    team.value = data || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load team'
  } finally {
    loading.value = false
  }
}

const addMember = async (): Promise<void> => {
  adding.value = true
  error.value = null
  try {
    // For now, we need user_id - in practice, lookup by email would require service role
    // This is a simplified UI; actual flow requires user to exist
    error.value = 'Add member requires user lookup by email - implement as needed'
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to add member'
  } finally {
    adding.value = false
  }
}

const removeMember = async (userId: string): Promise<void> => {
  if (!confirm('Remove this team member?')) return
  try {
    const { error: rpcError } = await (supabase.rpc as any)('admin_remove_staff', {
      p_user_id: userId,
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    await loadTeam()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to remove member'
  }
}

onMounted(loadTeam)
</script>

<template>
  <div>
    <header class="mb-6">
      <h1 class="page-title">Team</h1>
      <p class="page-subtitle">Who can sign in to this admin panel.</p>
    </header>

    <div v-if="loading" class="empty-state">Loading...</div>

    <p v-else-if="error" class="alert-error mb-6" role="alert">{{ error }}</p>

    <div class="space-y-6">
      <section class="card card-pad">
        <h2 class="text-sm font-semibold text-stone-900">Add team member</h2>
        <p class="hint mb-4">
          The address must belong to an account that has already signed up. Granting a role does not
          create the login.
        </p>

        <form class="grid gap-3 sm:grid-cols-[1fr_auto_auto]" @submit.prevent="addMember">
          <input
            v-model="email"
            type="email"
            required
            autocomplete="off"
            placeholder="teammate@example.com"
            class="field ltr-value"
            aria-label="Email address"
          />
          <select v-model="role" class="field sm:w-36" aria-label="Role">
            <option value="staff">Staff</option>
            <option value="owner">Owner</option>
          </select>
          <button type="submit" class="btn-primary" :disabled="adding">
            {{ adding ? 'Adding...' : 'Add' }}
          </button>
        </form>
      </section>

      <div v-if="team.length === 0" class="card empty-state">
        <AppIcon name="team" :size="28" class="mx-auto mb-3 text-stone-400" />
        <p class="font-medium text-stone-700">No team members</p>
      </div>

      <div v-else class="table-wrap">
        <div class="table-scroll">
          <table class="min-w-full divide-y divide-stone-200">
            <thead class="bg-stone-50">
              <tr>
                <th class="th">Email</th>
                <th class="th">Role</th>
                <th class="th">Added</th>
                <th class="th"><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody class="divide-y divide-stone-200">
              <tr v-for="member in team" :key="member.user_id" class="row-link">
                <td class="td">
                  <span class="ltr-value text-stone-900">
                    {{ member.email || 'No signed-up account' }}
                  </span>
                </td>
                <td class="td">
                  <span :class="member.role === 'owner' ? 'badge-warn' : 'badge-muted'">
                    {{ member.role }}
                  </span>
                </td>
                <td class="td whitespace-nowrap text-stone-500">
                  {{ formatDate(member.created_at) }}
                </td>
                <td class="td">
                  <div class="flex justify-end">
                    <button
                      type="button"
                      class="btn-secondary !px-2.5 !py-1.5 text-red-700 hover:!bg-red-50"
                      :aria-label="`Remove ${member.email || member.user_id}`"
                      :disabled="removingId === member.user_id"
                      @click="removeMember(member)"
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
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import AppIcon from '@/components/AppIcon.vue'
import { rpc } from '@/lib/rpc'

interface TeamMember {
  user_id: string
  email: string | null
  role: 'staff' | 'owner'
  created_at: string
}

const team = ref<TeamMember[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const email = ref('')
const role = ref<'staff' | 'owner'>('staff')
const adding = ref(false)
const removingId = ref<string | null>(null)

const formatDate = (value: string): string => {
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? '—' : parsed.toLocaleString()
}

const loadTeam = async (): Promise<void> => {
  const { data, error: rpcError } = await rpc<Record<string, unknown>>('admin_team')

  if (rpcError) {
    error.value = rpcError.message
    return
  }

  error.value = null
  team.value = (data ?? []) as unknown as typeof team.value
}

const addMember = async (): Promise<void> => {
  adding.value = true
  error.value = null

  try {
    const { error: rpcError } = await rpc<Record<string, unknown>>('admin_set_staff', {
      p_email: email.value,
      p_role: role.value,
    })

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    email.value = ''
    await loadTeam()
  } finally {
    adding.value = false
  }
}

const removeMember = async (member: TeamMember): Promise<void> => {
  if (!confirm(`Remove ${member.email || member.user_id} from the team?`)) return

  removingId.value = member.user_id
  error.value = null

  try {
    const { error: rpcError } = await rpc<Record<string, unknown>>('admin_remove_staff', {
      p_user_id: member.user_id,
    })

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    await loadTeam()
  } finally {
    removingId.value = null
  }
}

onMounted(async () => {
  try {
    await loadTeam()
  } finally {
    loading.value = false
  }
})
</script>

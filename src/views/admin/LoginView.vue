<template>
  <div class="flex min-h-screen items-center justify-center bg-gray-50">
    <div class="w-full max-w-md space-y-8 rounded-lg bg-white p-8 shadow">
      <div>
        <h1 class="text-center text-2xl font-bold text-gray-900">Admin Sign In</h1>
      </div>

      <form @submit.prevent="signIn" class="space-y-6">
        <div>
          <label for="email" class="block text-sm font-medium text-gray-700">Email</label>
          <input
            id="email"
            v-model="email"
            type="email"
            required
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>

        <div>
          <label for="password" class="block text-sm font-medium text-gray-700">Password</label>
          <input
            id="password"
            v-model="password"
            type="password"
            required
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>

        <button
          type="submit"
          :disabled="loading"
          class="w-full rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-gray-400"
        >
          {{ loading ? 'Signing in...' : 'Sign In' }}
        </button>

        <div v-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
          {{ error }}
        </div>
      </form>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import { useStaffRole } from '@/composables/useStaffRole'

const route = useRoute()
const router = useRouter()
const supabase = getSupabase()
const { refresh } = useStaffRole()

const email = ref('')
const password = ref('')
const loading = ref(false)
const error = ref<string | null>(null)

onMounted(() => {
  if (route.query.error === 'notStaff') {
    error.value = 'This account does not have admin access.'
  }
})

const signIn = async (): Promise<void> => {
  error.value = null
  loading.value = true

  try {
    const { error: authError } = await supabase.auth.signInWithPassword({
      email: email.value,
      password: password.value,
    })

    if (authError) {
      error.value = authError.message
      return
    }

    await refresh()

    router.push('/admin/queue')
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Sign in failed'
  } finally {
    loading.value = false
  }
}
</script>

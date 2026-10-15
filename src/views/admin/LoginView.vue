<template>
  <div class="admin-dark grid min-h-screen bg-stone-950 lg:grid-cols-2">
    <!-- Brand panel, hidden on small screens where it would just push the form down -->
    <div class="relative hidden flex-col justify-between bg-brand-800 p-12 text-white lg:flex">
      <div class="flex items-center gap-3">
        <span class="grid h-10 w-10 place-items-center rounded-lg bg-white/15 text-base font-bold">
          C
        </span>
        <span class="text-lg font-semibold">{{ t('admin.login.brand') }}</span>
      </div>

      <div class="max-w-sm">
        <h1 class="text-3xl font-bold tracking-tight">{{ t('admin.login.tagline') }}</h1>
        <p class="mt-4 text-brand-100">
          Review incoming orders, publish paid reports, and configure the payment methods your
          customers use.
        </p>
      </div>

      <p class="text-sm text-brand-200">{{ t('admin.login.note') }}</p>
    </div>

    <div class="flex items-center justify-center bg-stone-950 p-6 sm:p-12">
      <div class="w-full max-w-sm">
        <div class="mb-8 lg:hidden">
          <span
            class="mb-4 grid h-10 w-10 place-items-center rounded-lg bg-brand-700 text-base font-bold text-white"
          >
            C
          </span>
        </div>

        <h2 class="page-title">Sign in</h2>
        <p class="page-subtitle">{{ t('admin.login.useStaff') }}</p>

        <form class="mt-8 space-y-5" @submit.prevent="signIn">
          <div>
            <label class="label" for="email">{{ t('admin.common.email') }}</label>
            <input
              id="email"
              v-model="email"
              type="email"
              class="field"
              autocomplete="username"
              required
              placeholder="you@example.com"
            />
          </div>

          <div>
            <label class="label" for="password">{{ t('admin.login.password') }}</label>
            <input
              id="password"
              v-model="password"
              type="password"
              class="field"
              autocomplete="current-password"
              required
              placeholder="••••••••"
            />
          </div>

          <p v-if="error" class="alert-error" role="alert">{{ error }}</p>

          <button type="submit" class="btn-primary w-full" :disabled="loading">
            {{ loading ? 'Signing in...' : t('admin.login.submit') }}
          </button>
        </form>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import { useStaffRole } from '@/composables/useStaffRole'
import { useAdminI18n } from '@/i18n/admin'

const { t } = useAdminI18n()

const route = useRoute()
const router = useRouter()
const supabase = getSupabase()
const { refresh, isStaff } = useStaffRole()

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

    // Sign-in to a staff account that has been demoted since the last visit
    // should say so here rather than bouncing to the queue and back.
    await refresh()

    if (!isStaff.value) {
      await supabase.auth.signOut()
      error.value = 'This account does not have admin access.'
      return
    }

    await router.push('/admin/queue')
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Sign in failed'
  } finally {
    loading.value = false
  }
}
</script>

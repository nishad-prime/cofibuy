<template>
  <div class="mx-auto max-w-md px-4 py-8">
    <h1 class="mb-6 text-2xl font-bold text-gray-900">Account Recovery</h1>

    <div v-if="recoveryDisabled" class="rounded-lg bg-yellow-50 p-4 text-yellow-800">
      Account recovery is not available at this time.
    </div>

    <form v-else-if="!submitted" @submit.prevent="submitRequest" class="space-y-4">
      <div>
        <label for="phone" class="block text-sm font-medium text-gray-700"
          >Phone Number (Bangladesh)</label
        >
        <input
          id="phone"
          v-model="phone"
          type="tel"
          required
          placeholder="01XXXXXXXXX"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
      </div>

      <button
        type="submit"
        :disabled="requesting"
        class="w-full rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-gray-400"
      >
        {{ requesting ? 'Requesting...' : 'Request Recovery' }}
      </button>

      <div v-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
        {{ error }}
      </div>
    </form>

    <div v-else class="rounded-lg bg-green-50 p-4 text-green-800">
      Recovery request submitted. Please check your messages for the verification code.
      <router-link to="/recover/verify" class="mt-2 block text-blue-600 hover:underline">
        Continue to verification →
      </router-link>
    </div>

    <LanguageToggle class="mt-8" />
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getSupabase } from '@/lib/supabase'
import { normalizeBdPhone } from '@/lib/phone'
import LanguageToggle from '@/components/LanguageToggle.vue'

const supabase = getSupabase()

const phone = ref('')
const requesting = ref(false)
const submitted = ref(false)
const error = ref<string | null>(null)
const recoveryDisabled = ref(false)

onMounted(async () => {
  try {
    const { data: settings } = await supabase
      .from('site_settings')
      .select('recovery_enabled')
      .eq('id', 1)
      .maybeSingle()
    if (settings && settings.recovery_enabled === false) {
      recoveryDisabled.value = true
    }
  } catch {
    // Ignore
  }
})

const submitRequest = async (): Promise<void> => {
  error.value = null
  requesting.value = true

  try {
    const normalized = normalizeBdPhone(phone.value)
    if (!normalized) {
      error.value = 'Invalid Bangladeshi phone number'
      return
    }

    const { error: rpcError } = await (supabase.rpc as any)('request_recovery', {
      p_phone: normalized,
    })

    if (rpcError) {
      error.value = rpcError.message
      return
    }

    submitted.value = true
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to request recovery'
  } finally {
    requesting.value = false
  }
}
</script>

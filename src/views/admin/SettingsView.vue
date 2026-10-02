<template>
  <div>
    <h1 class="mb-6 text-2xl font-bold text-gray-900">Settings</h1>

    <div v-if="loading" class="text-gray-600">Loading...</div>
    <div v-else-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">{{ error }}</div>

    <form v-else @submit.prevent="save" class="max-w-2xl space-y-6">
      <div>
        <label class="block text-sm font-medium text-gray-700">Minimum Amount (minor units)</label>
        <input
          v-model.number="form.min_amount_minor"
          type="number"
          min="0"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
      </div>

      <div class="flex items-center">
        <input type="checkbox" v-model="form.hide_min" class="rounded border-gray-300" />
        <label class="ml-2 text-sm text-gray-700">Hide minimum from customers</label>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-700">Default Language</label>
        <select
          v-model="form.default_lang"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        >
          <option value="bn">Bangla</option>
          <option value="en">English</option>
        </select>
      </div>

      <div class="flex items-center">
        <input type="checkbox" v-model="form.recovery_enabled" class="rounded border-gray-300" />
        <label class="ml-2 text-sm text-gray-700">Enable Telegram recovery</label>
        <p class="mt-1 ml-6 text-xs text-gray-500">Warning: OTP worker must be deployed first.</p>
      </div>

      <button
        type="submit"
        :disabled="saving"
        class="rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:bg-gray-400"
      >
        {{ saving ? 'Saving...' : 'Save Settings' }}
      </button>

      <div v-if="success" class="rounded-lg bg-green-50 p-4 text-green-800">
        Settings saved successfully.
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getSupabase } from '@/lib/supabase'

const supabase = getSupabase()

const form = ref<any>({
  min_amount_minor: 0,
  hide_min: false,
  default_lang: 'bn',
  recovery_enabled: false,
})

const loading = ref(true)
const saving = ref(false)
const error = ref<string | null>(null)
const success = ref(false)

onMounted(async () => {
  try {
    const { data, error: rpcError } = await (supabase.rpc as any)('admin_settings')
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    if (data) {
      Object.assign(form.value, data)
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load settings'
  } finally {
    loading.value = false
  }
})

const save = async (): Promise<void> => {
  saving.value = true
  error.value = null
  success.value = false
  try {
    const { error: rpcError } = await (supabase.rpc as any)('admin_set_settings', {
      p_settings: form.value,
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    success.value = true
    setTimeout(() => (success.value = false), 3000)
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to save settings'
  } finally {
    saving.value = false
  }
}
</script>

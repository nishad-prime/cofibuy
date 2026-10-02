<template>
  <div>
    <router-link to="/admin/gateways" class="mb-4 inline-block text-blue-600 hover:underline">
      ← Back to gateways
    </router-link>

    <h1 class="mb-6 text-2xl font-bold text-gray-900">
      {{ isEdit ? 'Edit Gateway' : 'New Gateway' }}
    </h1>

    <form @submit.prevent="save" class="max-w-2xl space-y-6">
      <div>
        <label class="block text-sm font-medium text-gray-700">Kind</label>
        <select
          v-model="form.kind"
          required
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        >
          <option value="bKash">bKash</option>
          <option value="Nagad">Nagad</option>
          <option value="Bank">Bank</option>
        </select>
      </div>

      <div class="grid gap-6 md:grid-cols-2">
        <div>
          <label class="block text-sm font-medium text-gray-700">Name (EN)</label>
          <input
            v-model="form.name_en"
            required
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-gray-700">Name (BN)</label>
          <input
            v-model="form.name_bn"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>
      </div>

      <div class="flex items-center space-x-4">
        <label class="flex items-center">
          <input type="checkbox" v-model="form.active" class="rounded border-gray-300" />
          <span class="ml-2 text-sm">Active</span>
        </label>
        <label class="flex items-center">
          <input
            type="checkbox"
            v-model="form.supports_reference"
            class="rounded border-gray-300"
          />
          <span class="ml-2 text-sm">Supports Reference</span>
        </label>
      </div>

      <button
        type="submit"
        :disabled="saving"
        class="rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:bg-gray-400"
      >
        {{ saving ? 'Saving...' : 'Save' }}
      </button>

      <div v-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
        {{ error }}
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getSupabase } from '@/lib/supabase'

const route = useRoute()
const router = useRouter()
const supabase = getSupabase()

const gatewayId = computed(() => route.params.id as string)
const isEdit = computed(() => !!route.params.id)

const form = ref<any>({
  kind: 'bKash',
  name_en: '',
  name_bn: '',
  instructions_en: '',
  instructions_bn: '',
  account_number: '',
  account_name: '',
  supports_reference: false,
  active: true,
  sort_order: 0,
  evidence_fields: [],
})

const saving = ref(false)
const error = ref<string | null>(null)

onMounted(async () => {
  if (isEdit.value) {
    const { data } = await (supabase.rpc as any)('admin_gateways')
    const gw = (data || []).find((g: any) => g.id === gatewayId.value)
    if (gw) {
      Object.assign(form.value, gw)
    }
  }
})

const save = async (): Promise<void> => {
  saving.value = true
  error.value = null
  try {
    const { error: rpcError } = await (supabase.rpc as any)('admin_upsert_gateway', {
      p_id: isEdit.value ? gatewayId.value : null,
      p_kind: form.value.kind,
      p_name_bn: form.value.name_bn,
      p_name_en: form.value.name_en,
      p_instructions_bn: form.value.instructions_bn,
      p_instructions_en: form.value.instructions_en,
      p_account_number: form.value.account_number,
      p_account_name: form.value.account_name,
      p_supports_reference: form.value.supports_reference,
      p_active: form.value.active,
      p_sort_order: form.value.sort_order,
      p_evidence_fields: form.value.evidence_fields,
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    router.push('/admin/gateways')
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to save'
  } finally {
    saving.value = false
  }
}
</script>

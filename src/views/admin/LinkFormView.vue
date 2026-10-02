<template>
  <div>
    <router-link to="/admin/links" class="mb-4 inline-block text-blue-600 hover:underline">
      ← Back to links
    </router-link>

    <h1 class="mb-6 text-2xl font-bold text-gray-900">{{ isEdit ? 'Edit Link' : 'New Link' }}</h1>

    <form @submit.prevent="save" class="max-w-2xl space-y-6">
      <div>
        <label for="slug" class="block text-sm font-medium text-gray-700">Slug</label>
        <input
          id="slug"
          v-model="form.slug"
          required
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
      </div>

      <div class="grid gap-6 md:grid-cols-2">
        <div>
          <label class="block text-sm font-medium text-gray-700">Title (EN)</label>
          <input
            v-model="form.title_en"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-gray-700">Title (BN)</label>
          <input
            v-model="form.title_bn"
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
          <input type="checkbox" v-model="form.hide_min" class="rounded border-gray-300" />
          <span class="ml-2 text-sm">Hide Min</span>
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

const linkId = computed(() => route.params.id as string)
const isEdit = computed(() => !!route.params.id)

const form = ref<any>({
  slug: '',
  title_en: '',
  title_bn: '',
  teaser_en: '',
  teaser_bn: '',
  body_en: '',
  body_bn: '',
  cta_label_en: '',
  cta_label_bn: '',
  cta_url: '',
  active: false,
  sort_order: 0,
  min_override: null,
  hide_min: false,
})

const saving = ref(false)
const error = ref<string | null>(null)

onMounted(async () => {
  if (isEdit.value) {
    const { data } = await (supabase.rpc as any)('admin_links')
    const link = (data || []).find((l: any) => l.id === linkId.value)
    if (link) {
      Object.assign(form.value, link)
    }
  }
})

const save = async (): Promise<void> => {
  saving.value = true
  error.value = null
  try {
    const { error: rpcError } = await (supabase.rpc as any)('admin_upsert_link', {
      p_id: isEdit.value ? linkId.value : null,
      p_slug: form.value.slug,
      p_title_bn: form.value.title_bn,
      p_title_en: form.value.title_en,
      p_teaser_bn: form.value.teaser_bn,
      p_teaser_en: form.value.teaser_en,
      p_body_bn: form.value.body_bn,
      p_body_en: form.value.body_en,
      p_cta_label_bn: form.value.cta_label_bn,
      p_cta_label_en: form.value.cta_label_en,
      p_cta_url: form.value.cta_url,
      p_active: form.value.active,
      p_sort_order: form.value.sort_order,
      p_min_override: form.value.min_override,
      p_hide_min: form.value.hide_min,
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    router.push('/admin/links')
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to save'
  } finally {
    saving.value = false
  }
}
</script>

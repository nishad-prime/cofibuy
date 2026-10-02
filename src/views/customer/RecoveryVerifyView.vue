<template>
  <div class="mx-auto max-w-md px-4 py-8">
    <h1 class="mb-6 text-2xl font-bold text-gray-900">Verify Recovery Code</h1>

    <form v-if="!verified" @submit.prevent="submitVerify" class="space-y-4">
      <div>
        <label for="phone" class="block text-sm font-medium text-gray-700">Phone Number</label>
        <input
          id="phone"
          v-model="phone"
          type="tel"
          required
          placeholder="01XXXXXXXXX"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
      </div>

      <div>
        <label for="code" class="block text-sm font-medium text-gray-700">Verification Code</label>
        <input
          id="code"
          v-model="code"
          type="text"
          required
          inputmode="numeric"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
      </div>

      <button
        type="submit"
        :disabled="verifying"
        class="w-full rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-gray-400"
      >
        {{ verifying ? 'Verifying...' : 'Verify Code' }}
      </button>

      <div v-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
        {{ error }}
      </div>
    </form>

    <div v-else class="space-y-4">
      <div class="rounded-lg bg-green-50 p-4 text-green-800">Recovery verified successfully.</div>

      <div v-if="grantedLinks.length > 0">
        <h2 class="mb-2 text-lg font-semibold">Granted Links</h2>
        <ul class="space-y-2">
          <li
            v-for="link in grantedLinks"
            :key="link.slug"
            class="rounded-md border border-gray-200 p-3"
          >
            <router-link :to="`/${link.slug}`" class="text-blue-600 hover:underline">
              {{ pick({ bn: link.title_bn, en: link.title_en } as any) || '' }}
            </router-link>
          </li>
        </ul>
      </div>

      <div v-else class="rounded-lg bg-yellow-50 p-4 text-yellow-800">
        No links were granted for this phone number.
      </div>

      <router-link to="/" class="block text-center text-blue-600 hover:underline">
        Go to home
      </router-link>
    </div>

    <LanguageToggle class="mt-8" />
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { getSupabase } from '@/lib/supabase'
import { normalizeBdPhone } from '@/lib/phone'
import { useContent } from '@/composables/useContent'
import LanguageToggle from '@/components/LanguageToggle.vue'

const supabase = getSupabase()
const { pick } = useContent()

const phone = ref('')
const code = ref('')
const verifying = ref(false)
const verified = ref(false)
const error = ref<string | null>(null)
const grantedLinks = ref<Array<{ slug: string; title_bn: string | null; title_en: string | null }>>(
  [],
)

const submitVerify = async (): Promise<void> => {
  error.value = null
  verifying.value = true

  try {
    const normalized = normalizeBdPhone(phone.value)
    if (!normalized) {
      error.value = 'Invalid Bangladeshi phone number'
      return
    }

    const { data, error: rpcError } = await (supabase.rpc as any)('recover_access', {
      p_phone: normalized,
      p_code: code.value.trim(),
    })

    if (rpcError) {
      error.value = 'Invalid code'
      return
    }

    if (data && (data as any).ok) {
      verified.value = true
      grantedLinks.value = (data as any).links || []
    } else {
      error.value = 'Invalid code'
    }
  } catch (err) {
    error.value = 'Invalid code'
  } finally {
    verifying.value = false
  }
}
</script>

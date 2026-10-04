<template>
  <main class="mx-auto max-w-md px-4 py-12 sm:px-6">
    <h1 class="page-title">{{ t('customer.recovery.title') }}</h1>
    <CopyText copy-key="recovery.body" tag="p" class="page-subtitle mb-8" />

    <section v-if="recoveryDisabled" class="alert-error" role="alert">
      {{ error }}
    </section>

    <section v-else-if="submitted" class="card card-pad text-center">
      <AppIcon name="check" :size="28" class="mx-auto mb-3 text-emerald-600" />
      <p class="text-sm text-stone-700">{{ t('customer.recovery.sent') }}</p>
      <router-link to="/recover/verify" class="btn-primary mt-6">
        {{ t('customer.order.title') }}
      </router-link>
    </section>

    <form v-else class="card card-pad space-y-5" @submit.prevent="submitRequest">
      <div>
        <label class="label" for="phone">Phone number</label>
        <input
          id="phone"
          v-model="phone"
          type="tel"
          inputmode="tel"
          required
          placeholder="01XXXXXXXXX"
          class="field ltr-value"
        />
      </div>

      <p v-if="error" class="alert-error" role="alert">{{ error }}</p>

      <button type="submit" class="btn-primary w-full" :disabled="requesting">
        {{ requesting ? t('customer.recovery.submitting') : t('customer.recovery.submit') }}
      </button>
    </form>
  </main>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { getSupabase } from '@/lib/supabase'
import { normalizeBdPhone } from '@/lib/phone'
import AppIcon from '@/components/AppIcon.vue'
import CopyText from '@/components/CopyText.vue'

const { t } = useI18n()
const supabase = getSupabase()

const phone = ref('')
const requesting = ref(false)
const submitted = ref(false)
const error = ref<string | null>(null)
const recoveryDisabled = ref(false)

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
      // `request_recovery` refuses when the feature is switched off, which is
      // the authoritative answer; the flag cannot be read from the client.
      if (rpcError.message.includes('not available')) {
        recoveryDisabled.value = true
      }
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

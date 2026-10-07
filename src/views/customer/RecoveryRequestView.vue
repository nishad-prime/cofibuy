<template>
  <main class="mx-auto max-w-md px-4 py-12 sm:px-6">
    <h1 class="page-title">{{ t('customer.recovery.title') }}</h1>
    <MarkdownBody :source="t('customer.recovery.body')" class="page-subtitle mb-8" />

    <section v-if="recoveryDisabled" class="alert-error" role="alert">
      {{ t('customer.recovery.disabled') }}
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
        <label class="label" for="phone">{{ t('customer.recovery.phone') }}</label>
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
import { computed, onMounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { getSupabase } from '@/lib/supabase'
import { normalizeBdPhone } from '@/lib/phone'
import { useSiteSettings } from '@/composables/useSiteSettings'
import AppIcon from '@/components/AppIcon.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'

const { t } = useI18n()
const supabase = getSupabase()
const { settings, loaded, load } = useSiteSettings()

const phone = ref('')
const requesting = ref(false)
const submitted = ref(false)
const error = ref<string | null>(null)

// `recovery_enabled` used to be discovered by matching the words "not available"
// in whatever the RPC happened to raise. That makes the copy of a server message
// load-bearing, so rephrasing the error would silently re-open a closed form. The
// flag is now read directly.
//
// While `loaded` is false the form stays up rather than showing a spurious
// "unavailable" message before the fetch lands. If the fetch fails, `request_recovery`
// still refuses authoritatively and the error is shown then.
const recoveryDisabled = computed(() => loaded.value && !settings.value.recovery_enabled)

onMounted(() => {
  void load()
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
      // No substring sniffing. If the flag was on and the request was refused
      // anyway, this is an ordinary failure the customer should see verbatim.
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

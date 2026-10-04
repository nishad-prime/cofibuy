<template>
  <main class="mx-auto max-w-md px-4 py-12 sm:px-6">
    <h1 class="page-title">{{ t('customer.recovery.title') }}</h1>

    <form v-if="!verified" class="card card-pad mt-8 space-y-5" @submit.prevent="submitVerify">
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

      <div>
        <label class="label" for="code">{{ t('customer.recovery.code') }}</label>
        <input
          id="code"
          v-model="code"
          type="text"
          required
          inputmode="numeric"
          autocomplete="one-time-code"
          class="field ltr-value"
        />
      </div>

      <p v-if="error" class="alert-error" role="alert">{{ error }}</p>

      <button type="submit" class="btn-primary w-full" :disabled="verifying">
        {{ verifying ? t('customer.common.loading') : t('customer.recovery.submit') }}
      </button>
    </form>

    <div v-else class="mt-8 space-y-4">
      <div class="alert-success flex items-center gap-2">
        <AppIcon name="check" :size="18" />
        {{ t('customer.recovery.sent') }}
      </div>

      <div v-if="grantedLinks.length > 0" class="card card-pad">
        <ul class="space-y-2">
          <li v-for="link in grantedLinks" :key="link.slug">
            <router-link
              :to="`/${link.slug}`"
              class="flex items-center justify-between gap-3 rounded-lg border border-stone-200 px-3 py-2.5 text-sm font-medium text-stone-900 transition hover:border-brand-400 hover:bg-brand-50"
            >
              {{ pick({ bn: link.title_bn, en: link.title_en } as any) || link.slug }}
              <AppIcon name="arrowLeft" :size="16" class="rotate-180 text-stone-400" />
            </router-link>
          </li>
        </ul>
      </div>

      <div v-else class="card empty-state">
        {{ t('customer.recovery.sent') }}
      </div>

      <router-link to="/" class="btn-secondary w-full">{{
        t('customer.notFound.cta')
      }}</router-link>
    </div>
  </main>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { getSupabase } from '@/lib/supabase'
import { normalizeBdPhone } from '@/lib/phone'
import { useContent } from '@/composables/useContent'
import AppIcon from '@/components/AppIcon.vue'

const { t } = useI18n()
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
  } catch {
    error.value = 'Invalid code'
  } finally {
    verifying.value = false
  }
}
</script>

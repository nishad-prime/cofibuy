<template>
  <div>
    <header class="mb-6">
      <h1 class="page-title">{{ t('admin.settings.heading') }}</h1>
      <p class="page-subtitle">{{ t('admin.settings.subtitle') }}</p>
    </header>

    <div v-if="loading" class="empty-state">{{ t('admin.settings.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <form v-else class="max-w-2xl space-y-6" @submit.prevent="save">
      <section class="card card-pad">
        <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.settings.pricing') }}</h2>

        <div class="mt-4">
          <label class="label" for="min_amount">{{ t('admin.settings.minAmount') }}</label>
          <input
            id="min_amount"
            v-model.number="form.min_amount"
            type="number"
            min="0"
            step="1"
            class="field ltr-value"
          />
          <p class="hint">{{ t('admin.settings.minAmountHint') }}</p>
        </div>

        <label class="mt-4 flex items-start gap-3">
          <input v-model="form.hide_min_amount" type="checkbox" class="mt-0.5 size-4 rounded" />
          <span class="text-sm text-stone-700">
            {{ t('admin.settings.hideMin') }}
            <span class="hint block">{{ t('admin.settings.hideMinHint') }}</span>
          </span>
        </label>
      </section>

      <section class="card card-pad">
        <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.settings.localisation') }}</h2>

        <div class="mt-4">
          <label class="label" for="default_lang">{{ t('admin.settings.defaultLang') }}</label>
          <select id="default_lang" v-model="form.default_lang" class="field">
            <option value="bn">বাংলা</option>
            <option value="en">English</option>
          </select>
        </div>
      </section>

      <section class="card card-pad">
        <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.settings.recovery') }}</h2>

        <label class="mt-4 flex items-start gap-3">
          <input v-model="form.recovery_enabled" type="checkbox" class="mt-0.5 size-4 rounded" />
          <span class="text-sm text-stone-700">
            {{ t('admin.settings.recoveryEnabled') }}
            <span class="hint block">{{ t('admin.settings.recoveryHint') }}</span>
          </span>
        </label>
      </section>

      <section class="card card-pad">
        <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.settings.maintenance') }}</h2>

        <label class="mt-4 flex items-start gap-3">
          <input v-model="form.maintenance_mode" type="checkbox" class="mt-0.5 size-4 rounded" />
          <span class="text-sm text-stone-700">
            {{ t('admin.settings.maintenanceEnabled') }}
            <span class="hint block">{{ t('admin.settings.maintenanceHint') }}</span>
          </span>
        </label>

        <p v-if="form.maintenance_mode" class="alert-error mt-4" role="alert">
          {{ t('admin.settings.maintenanceWarning') }}
        </p>

        <div class="mt-4">
          <label class="label" for="contact">{{ t('admin.settings.contact') }}</label>
          <input id="contact" v-model="form.contact" type="text" class="field ltr-value" />
          <p class="hint">{{ t('admin.settings.contactHint') }}</p>
        </div>
      </section>

      <div class="flex items-center gap-3">
        <button type="submit" class="btn-primary" :disabled="saving">
          {{ saving ? t('admin.settings.saving') : t('admin.settings.save') }}
        </button>
        <p v-if="success" class="alert-success" role="status">{{ t('admin.settings.saved') }}</p>
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getSupabase } from '@/lib/supabase'
import { useAdminI18n } from '@/i18n/admin'

const supabase = getSupabase()
const { t } = useAdminI18n()

interface SettingsForm {
  min_amount: number
  hide_min_amount: boolean
  default_lang: 'bn' | 'en'
  recovery_enabled: boolean
  maintenance_mode: boolean
  contact: string
}

/**
 * The row and the form do not share column names in every case, so the row is copied
 * field by field rather than assigned wholesale. `Object.assign` used to leave the old
 * `min_amount_minor` / `hide_min` keys in place and write back nothing at all. The
 * same trap is documented at the top of `LinkFormView`.
 *
 * `contact` is sent even when blank: `admin_set_settings` treats present-but-blank as
 * "clear it", which is how an operator removes stale contact details. It is loaded on
 * mount, so an untouched field round-trips the existing value rather than erasing it.
 */
const form = ref<SettingsForm>({
  min_amount: 100,
  hide_min_amount: false,
  default_lang: 'bn',
  recovery_enabled: false,
  maintenance_mode: false,
  contact: '',
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
      form.value = {
        min_amount: Number(data.min_amount ?? 0),
        hide_min_amount: Boolean(data.hide_min_amount),
        default_lang: data.default_lang === 'en' ? 'en' : 'bn',
        recovery_enabled: Boolean(data.recovery_enabled),
        maintenance_mode: Boolean(data.maintenance_mode),
        contact: typeof data.contact === 'string' ? data.contact : '',
      }
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : t('admin.errors.generic')
  } finally {
    loading.value = false
  }
})

const save = async (): Promise<void> => {
  saving.value = true
  error.value = null
  success.value = false
  try {
    // An emptied number input arrives as `''`, and `''::numeric` is a database
    // error rather than a null, so the value is normalised before it is sent.
    const amount = Number(form.value.min_amount)

    const { error: rpcError } = await (supabase.rpc as any)('admin_set_settings', {
      p_settings: {
        min_amount: Number.isFinite(amount) ? amount : 0,
        hide_min_amount: form.value.hide_min_amount,
        default_lang: form.value.default_lang,
        recovery_enabled: form.value.recovery_enabled,
        maintenance_mode: form.value.maintenance_mode,
        contact: form.value.contact,
      },
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    success.value = true
    setTimeout(() => (success.value = false), 3000)
  } catch (err) {
    error.value = err instanceof Error ? err.message : t('admin.errors.generic')
  } finally {
    saving.value = false
  }
}
</script>

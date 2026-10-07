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

        <div class="mt-4">
          <label class="label" for="currency">{{ t('admin.settings.currency') }}</label>
          <select id="currency" v-model="form.currency" class="field">
            <option v-for="code in currencies" :key="code" :value="code">{{ code }}</option>
          </select>
          <p class="hint">{{ t('admin.settings.currencyHint') }}</p>
        </div>
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
        <h2 class="text-sm font-semibold text-stone-900">{{ t('admin.settings.index') }}</h2>
        <p class="hint">{{ t('admin.settings.indexHint') }}</p>

        <div class="mt-3 space-y-2">
          <textarea
            v-model="paragraph"
            rows="3"
            placeholder="A small shop selling Bengali ebooks and study guides, paid by bKash or bank transfer."
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <button
            type="button"
            :disabled="filling || paragraph.trim() === ''"
            class="rounded-md border border-blue-600 px-4 py-2 text-sm text-blue-700 hover:bg-blue-50 disabled:border-gray-300 disabled:text-gray-400"
            @click="fillIndex"
          >
            {{ filling ? 'Filling...' : 'Fill from the paragraph' }}
          </button>
          <p v-if="fillError" class="rounded-lg bg-red-50 p-3 text-sm text-red-800">
            {{ fillError }}
          </p>
        </div>

        <div class="mt-4 grid gap-4 md:grid-cols-2">
          <div>
            <label class="label" for="index_heading_en">{{
              t('admin.settings.indexHeadingEn')
            }}</label>
            <input
              id="index_heading_en"
              v-model="form.index_heading_en"
              type="text"
              class="field"
            />
          </div>
          <div>
            <label class="label" for="index_heading_bn">{{
              t('admin.settings.indexHeadingBn')
            }}</label>
            <input
              id="index_heading_bn"
              v-model="form.index_heading_bn"
              type="text"
              class="field"
            />
          </div>
          <div>
            <label class="label" for="index_subheading_en">{{
              t('admin.settings.indexSubEn')
            }}</label>
            <textarea
              id="index_subheading_en"
              v-model="form.index_subheading_en"
              rows="2"
              class="field"
            ></textarea>
          </div>
          <div>
            <label class="label" for="index_subheading_bn">{{
              t('admin.settings.indexSubBn')
            }}</label>
            <textarea
              id="index_subheading_bn"
              v-model="form.index_subheading_bn"
              rows="2"
              class="field"
            ></textarea>
          </div>
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
import { CURRENCIES, isSupportedCurrency } from '@/lib/currency'
import { describeEdgeFailure } from '@/lib/edgeError'
import { applyAdminCurrency } from '@/composables/useAdminCurrency'
import { useAdminI18n } from '@/i18n/admin'
import { rpc } from '@/lib/rpc'

const supabase = getSupabase()
const { t } = useAdminI18n()
const currencies = CURRENCIES

interface SettingsForm {
  min_amount: number
  hide_min_amount: boolean
  default_lang: 'bn' | 'en'
  recovery_enabled: boolean
  maintenance_mode: boolean
  contact: string
  currency: string
  index_heading_en: string
  index_heading_bn: string
  index_subheading_en: string
  index_subheading_bn: string
}

/**
 * The row and the form do not share column names in every case, so the row is copied
 * field by field rather than assigned wholesale. `Object.assign` used to leave the old
 * `min_amount_minor` / `hide_min` keys in place and write back nothing at all. The
 * same trap is documented at the top of `PageFormView`.
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
  currency: 'BDT',
  index_heading_en: '',
  index_heading_bn: '',
  index_subheading_en: '',
  index_subheading_bn: '',
})

const loading = ref(true)
const saving = ref(false)

/**
 * Describe-and-fill for the index words.
 *
 * The paragraph is a prompt, not shop copy, so it never reaches
 * `admin_set_settings`; the fill lands in the four fields above, where it is an
 * ordinary unsaved edit like typing.
 */
const paragraph = ref('')
const filling = ref(false)
const fillError = ref<string | null>(null)

const FILL_FIELDS = [
  {
    key: 'index_heading_en',
    label: 'Index heading (English)',
    hint: 'the shop name-line, a few words',
  },
  {
    key: 'index_heading_bn',
    label: 'Index heading (Bangla)',
    hint: 'the shop name-line, a few words',
  },
  {
    key: 'index_subheading_en',
    label: 'Index subheading (English)',
    hint: 'one sentence: what the shop sells and how payment works',
  },
  {
    key: 'index_subheading_bn',
    label: 'Index subheading (Bangla)',
    hint: 'one sentence: what the shop sells and how payment works',
  },
]

const fillIndex = async (): Promise<void> => {
  if (filling.value || paragraph.value.trim() === '') return

  filling.value = true
  fillError.value = null

  try {
    const { data, error: fnError } = await supabase.functions.invoke('ai-fill-form', {
      body: { paragraph: paragraph.value.trim(), fields: FILL_FIELDS },
    })

    if (fnError) throw fnError

    const values = (data as { values?: Record<string, unknown> } | null)?.values
    if (!values) throw new Error('The fill came back empty.')

    for (const field of FILL_FIELDS) {
      const value = values[field.key]
      if (typeof value === 'string' && value !== '') {
        ;(form.value as Record<string, unknown>)[field.key] = value
      }
    }
  } catch (err) {
    const failure = await describeEdgeFailure(err, 'The fill did not come back.')
    if (failure.cause !== '') console.warn('[ai-fill-form]', failure)
    fillError.value = failure.message
  } finally {
    filling.value = false
  }
}
const error = ref<string | null>(null)
const success = ref(false)

onMounted(async () => {
  try {
    const { data, error: rpcError } = await rpc<Record<string, unknown>>('admin_settings')
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
        // A stored code outside the allowlist can only come from a direct write that
        // predates the constraint; the select cannot render it, so fall back to BDT.
        currency: isSupportedCurrency(data.currency) ? data.currency : 'BDT',
        index_heading_en: typeof data.index_heading_en === 'string' ? data.index_heading_en : '',
        index_heading_bn: typeof data.index_heading_bn === 'string' ? data.index_heading_bn : '',
        index_subheading_en:
          typeof data.index_subheading_en === 'string' ? data.index_subheading_en : '',
        index_subheading_bn:
          typeof data.index_subheading_bn === 'string' ? data.index_subheading_bn : '',
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

    const { error: rpcError } = await rpc<Record<string, unknown>>('admin_set_settings', {
      p_settings: {
        min_amount: Number.isFinite(amount) ? amount : 0,
        hide_min_amount: form.value.hide_min_amount,
        default_lang: form.value.default_lang,
        recovery_enabled: form.value.recovery_enabled,
        maintenance_mode: form.value.maintenance_mode,
        contact: form.value.contact,
        currency: form.value.currency,
        // Always sent: the fields are loaded on mount, so they round-trip what
        // the operator found, and a blank means "clear it" in the RPC.
        index_heading_en: form.value.index_heading_en,
        index_heading_bn: form.value.index_heading_bn,
        index_subheading_en: form.value.index_subheading_en,
        index_subheading_bn: form.value.index_subheading_bn,
      },
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    // Keep the shared admin currency in step, or the queue would keep the old symbol
    // until a full reload.
    applyAdminCurrency(form.value.currency)
    success.value = true
    setTimeout(() => (success.value = false), 3000)
  } catch (err) {
    error.value = err instanceof Error ? err.message : t('admin.errors.generic')
  } finally {
    saving.value = false
  }
}
</script>

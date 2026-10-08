<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'

/**
 * Renders a gateway's destination: the ordered, operator-defined rows a customer copies
 * to send the money.
 *
 * One component for all three places that used to read `account_number` and
 * `account_name` directly - the method picker, the page and the order view. Three
 * copies of the same markup is three places for a new detail type to be forgotten, and
 * the order page in particular has to agree with the picker, or a customer copies a
 * different number than the one they were shown.
 *
 * Falls back to the legacy pair when a gateway predates `account_fields`, so an operator
 * who has not resaved a method still sees their bank details rather than a blank box.
 */
export interface AccountField {
  key: string
  label_en: string
  label_bn?: string | null
  value: string
}

const props = withDefaults(
  defineProps<{
    fields?: AccountField[] | null
    legacyNumber?: string | null
    legacyName?: string | null
    /** Renders a copy button on the first row, which is the number customers need. */
    copyable?: boolean
  }>(),
  { fields: null, legacyNumber: null, legacyName: null, copyable: true },
)

const { t, locale } = useI18n()

type Row = AccountField

/**
 * The rows to render. `account_fields` wins when it has anything in it; the legacy pair
 * is only consulted for a gateway saved before the column existed.
 */
const rows = computed<Row[]>(() => {
  const configured = (props.fields ?? []).filter((field) => field.value?.trim())
  if (configured.length > 0) return configured

  const fallback: Row[] = []
  if (props.legacyNumber?.trim()) {
    fallback.push({
      key: 'account_number',
      label_en: t('customer.paywall.accountNumber'),
      label_bn: null,
      value: props.legacyNumber,
    })
  }
  if (props.legacyName?.trim()) {
    fallback.push({
      key: 'account_name',
      label_en: t('customer.paywall.accountName'),
      label_bn: null,
      value: props.legacyName,
    })
  }
  return fallback
})

const label = (row: Row): string => {
  if (locale.value === 'bn' && row.label_bn?.trim()) return row.label_bn
  return row.label_en
}

const copied = defineModel<boolean>('copied', { default: false })

async function copy(row: Row): Promise<void> {
  try {
    await navigator.clipboard.writeText(row.value)
    copied.value = true
    setTimeout(() => {
      copied.value = false
    }, 1500)
  } catch {
    // Clipboard access can be refused; the value is on screen either way, so there is
    // nothing useful to say about it.
  }
}
</script>

<template>
  <div v-if="rows.length > 0" class="space-y-2">
    <div
      v-for="(row, index) in rows"
      :key="row.key"
      class="flex items-center justify-between gap-3"
    >
      <span class="shrink-0 text-xs text-stone-500">{{ label(row) }}</span>
      <span class="flex min-w-0 items-center gap-2">
        <span class="truncate font-mono text-sm text-stone-900 ltr-value">{{ row.value }}</span>
        <button
          v-if="copyable && index === 0"
          type="button"
          class="btn-secondary !px-2 !py-1 text-xs"
          :title="copied ? t('customer.common.copied') : t('customer.common.copy')"
          @click="copy(row)"
        >
          {{ copied ? t('customer.common.copied') : t('customer.common.copy') }}
        </button>
      </span>
    </div>
  </div>
</template>

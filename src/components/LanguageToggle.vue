<script setup lang="ts">
import { useLocale } from '@/composables/useLocale'
import { useI18n } from 'vue-i18n'
import { usePageShell } from '@/composables/usePageShell'

const { locale, otherLocale, toggle } = useLocale()
const { t } = useI18n()
const { isFullBleed } = usePageShell()
</script>

<template>
  <button
    type="button"
    class="rounded-lg border px-3 py-1.5 text-sm font-medium"
    :class="
      isFullBleed
        ? 'border-white/25 text-stone-200 hover:bg-white/10'
        : 'border-stone-300 text-stone-700 hover:bg-stone-100'
    "
    :aria-label="t('customer.lang.label')"
    @click="toggle"
  >
    <span v-if="locale === 'bn'" class="ltr-value">{{ otherLocale.toUpperCase() }}</span>
    <span v-else>বাংলা</span>
  </button>
</template>

<script setup lang="ts">
import { useLocale } from '@/composables/useLocale'
import { useI18n } from 'vue-i18n'

const { locale, otherLocale, toggle } = useLocale()
const { t } = useI18n()
</script>

<template>
  <button
    type="button"
    class="rounded-lg border border-stone-300 px-3 py-1.5 text-sm font-medium text-stone-700 hover:bg-stone-100"
    :aria-label="t('lang.label')"
    @click="toggle"
  >
    <span v-if="locale === 'bn'" class="ltr-value">{{ otherLocale.toUpperCase() }}</span>
    <span v-else>বাংলা</span>
  </button>
</template>

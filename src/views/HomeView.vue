<script setup lang="ts">
import { isSupabaseConfigured } from '@/lib/env'
import { useI18n } from 'vue-i18n'

const { t } = useI18n()
</script>

<template>
  <section class="space-y-6">
    <div>
      <h1 class="text-2xl font-semibold text-stone-900">{{ t('home.heading') }}</h1>
      <p class="mt-1 text-stone-600">{{ t('home.subheading') }}</p>
    </div>

    <div
      v-if="!isSupabaseConfigured"
      class="card border-amber-300 bg-amber-50 p-4 text-sm text-amber-900"
    >
      <p class="font-semibold">{{ t('setup.title') }}</p>
      <p class="mt-1">{{ t('setup.body') }}</p>
      <p class="mt-2 font-mono text-xs">{{ t('setup.see') }}</p>
    </div>
  </section>
</template>

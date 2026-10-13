<script setup lang="ts">
import { useI18n } from 'vue-i18n'
import AppIcon from '@/components/AppIcon.vue'

const { t } = useI18n()
</script>

<template>
  <main class="mx-auto max-w-md px-4 py-20 sm:px-6">
    <div class="card card-pad rounded-2xl text-center shadow-sm">
      <span
        class="mx-auto mb-4 grid size-14 place-items-center rounded-full bg-brand-100 text-brand-700"
      >
        <AppIcon name="link" :size="26" />
      </span>
      <h1 class="text-xl font-semibold text-stone-900">{{ t('customer.notFound.title') }}</h1>
      <p class="mt-2 text-sm text-stone-600">{{ t('customer.notFound.body') }}</p>
      <RouterLink to="/" class="btn-primary mt-6">{{ t('customer.notFound.cta') }}</RouterLink>
    </div>
  </main>
</template>

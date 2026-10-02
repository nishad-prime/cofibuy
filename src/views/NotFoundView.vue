<script setup lang="ts">
import { useI18n } from 'vue-i18n'

const { t } = useI18n()
</script>

<template>
  <section class="card p-8 text-center">
    <h1 class="text-xl font-semibold text-stone-900">{{ t('customer.notFound.title') }}</h1>
    <p class="mt-2 text-stone-600">{{ t('customer.notFound.body') }}</p>
    <RouterLink to="/" class="btn-primary mt-6">{{ t('customer.notFound.cta') }}</RouterLink>
  </section>
</template>

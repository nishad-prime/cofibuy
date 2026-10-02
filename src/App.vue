<script setup lang="ts">
import LanguageToggle from '@/components/LanguageToggle.vue'
import { useI18n } from 'vue-i18n'

const { t } = useI18n()
</script>

<template>
  <div class="flex min-h-dvh flex-col">
    <header class="border-b border-stone-200 bg-white/90 backdrop-blur">
      <div class="mx-auto flex w-full max-w-3xl items-center justify-between gap-4 px-4 py-3">
        <RouterLink to="/" class="flex items-center gap-2 font-semibold text-stone-900">
          <img src="/favicon.svg" alt="" class="h-7 w-7" width="28" height="28" />
          <span>{{ t('customer.app.name') }}</span>
        </RouterLink>
        <LanguageToggle />
      </div>
    </header>

    <main class="mx-auto w-full max-w-3xl flex-1 px-4 py-8">
      <RouterView />
    </main>

    <footer class="border-t border-stone-200 py-6 text-center text-xs text-stone-500">
      {{ t('customer.app.name') }}
    </footer>
  </div>
</template>

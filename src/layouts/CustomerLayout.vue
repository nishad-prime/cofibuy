<script setup lang="ts">
import { onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import LanguageToggle from '@/components/LanguageToggle.vue'
import { loadCopyOverrides } from '@/composables/useCopyOverrides'

const { t } = useI18n()

// Fired, not awaited. The bundled wording is already rendering and stays correct
// if this never returns, so a copy fetch must not gate first paint - see the
// composable for the budget and why it exists.
onMounted(() => {
  void loadCopyOverrides()
})
</script>

<template>
  <!--
    Customer-facing chrome only. The admin routes are deliberately outside this
    layout: /admin/login and /admin/* are separate top-level routes, so they no
    longer render a storefront header above the panel.
  -->
  <div class="flex min-h-dvh flex-col">
    <header class="sticky top-0 z-10 border-b border-stone-200 bg-white/90 backdrop-blur">
      <div
        class="mx-auto flex w-full max-w-4xl items-center justify-between gap-4 px-4 py-3 sm:px-6"
      >
        <RouterLink to="/" class="flex items-center gap-2.5">
          <span
            class="grid h-8 w-8 place-items-center rounded-lg bg-brand-700 text-sm font-bold text-white"
          >
            C
          </span>
          <span class="font-semibold text-stone-900">{{ t('customer.app.name') }}</span>
        </RouterLink>
        <LanguageToggle />
      </div>
    </header>

    <main class="flex-1">
      <RouterView />
    </main>

    <footer class="border-t border-stone-200 py-6 text-center text-xs text-stone-400">
      {{ t('customer.app.name') }}
    </footer>
  </div>
</template>

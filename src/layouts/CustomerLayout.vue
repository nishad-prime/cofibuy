<script setup lang="ts">
import { onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import LanguageToggle from '@/components/LanguageToggle.vue'
import { loadSiteSettings } from '@/composables/useSiteSettings'
import { usePageStandalone } from '@/composables/usePageStandalone'

const { t } = useI18n()
const { isStandalone } = usePageStandalone()

// Fired, not awaited. The bundled wording and the default settings are already
// rendering and stay correct if either never returns, so neither fetch may gate first
// paint - see the composables for the budget and why it exists.
//
// This is the only place either is kicked off. The layout wraps every customer route,
// so a view that called them itself would issue a second request on navigation; both
// composables memoise, but asking in one place makes the one-request-per-session
// property obvious rather than something to be discovered.
onMounted(() => {
  void loadSiteSettings()
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
        <!-- A standalone page is reached by URL alone and shows no way back to
             the index, header included; the mark stays, as a wordmark. -->
        <RouterLink
          :to="isStandalone ? '' : '/'"
          :class="
            isStandalone
              ? 'pointer-events-none flex items-center gap-2.5'
              : 'flex items-center gap-2.5'
          "
        >
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
      {{ t('customer.app.name') }} · {{ t('customer.app.tagline') }}
    </footer>
  </div>
</template>

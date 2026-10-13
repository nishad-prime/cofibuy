<script setup lang="ts">
import { onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import LanguageToggle from '@/components/LanguageToggle.vue'
import { loadSiteSettings } from '@/composables/useSiteSettings'
import { usePageStandalone } from '@/composables/usePageStandalone'
import { usePageShell } from '@/composables/usePageShell'

const { t } = useI18n()
const { isStandalone } = usePageStandalone()
const { isFullBleed, isPageLoading } = usePageShell()

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
    <!--
      A standalone (hidden) page is sold by its URL alone: it carries no
      storefront chrome at all - no topbar, no site title, nothing but the
      page itself. While a page's fetch is in flight the chrome stays out of
      the way entirely, because a header that appears before its page would
      flash and shift. Listed pages get the header, tinted to the page on
      full-bleed templates.
    -->
    <header
      v-if="!isPageLoading && !isStandalone"
      class="sticky top-0 z-10 border-b backdrop-blur"
      :class="isFullBleed ? 'border-white/10 bg-stone-950/80' : 'border-stone-200 bg-white/90'"
    >
      <div
        class="mx-auto flex w-full max-w-4xl items-center justify-between gap-4 px-4 py-3 sm:px-6"
      >
        <RouterLink to="/" class="flex items-center gap-2.5">
          <span
            class="grid h-8 w-8 place-items-center rounded-lg bg-gradient-to-br from-brand-400 to-brand-700 text-sm font-bold text-white shadow-sm"
          >
            C
          </span>
          <span class="font-semibold" :class="isFullBleed ? 'text-white' : 'text-stone-900'">
            {{ t('customer.app.name') }}
          </span>
        </RouterLink>
        <LanguageToggle />
      </div>
    </header>

    <main class="flex-1">
      <RouterView />
    </main>

    <footer
      v-if="!isPageLoading"
      class="relative py-6 text-center text-xs"
      :class="
        isFullBleed
          ? 'border-white/10 bg-stone-950 text-stone-500'
          : 'border-stone-200 text-stone-400'
      "
    >
      <span
        v-if="!isFullBleed"
        class="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-brand-300/60 to-transparent"
        aria-hidden="true"
      />
      {{ t('customer.app.name') }} · {{ t('customer.app.tagline') }}
    </footer>
  </div>
</template>

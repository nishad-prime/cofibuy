import './styles/main.css'

import { i18n } from '@/i18n'
import router from '@/router'
import { createApp } from 'vue'
import App from './App.vue'

// Only the customer instance is installed. `adminI18n` is reached through
// `adminI18n.global` in `useAdminI18n()` instead: installing a second instance
// makes it the injected default for `useI18n()`, and vue-i18n ignores the
// `instance` option, so there is no way to bind it per component.
// The router awaits `ensureAdminMessages()` before the first admin navigation,
// so the admin bundle is never fetched for customers.
createApp(App).use(i18n).use(router).mount('#app')

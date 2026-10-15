<template>
  <div class="admin-dark min-h-screen bg-stone-950 text-stone-100">
    <!-- Desktop sidebar -->
    <aside
      class="fixed inset-y-0 left-0 hidden w-64 flex-col border-r border-white/10 bg-stone-950/95 lg:flex"
    >
      <div class="flex h-16 items-center gap-3 border-b border-white/10 px-5">
        <span
          class="grid h-9 w-9 place-items-center rounded-lg bg-gradient-to-br from-brand-400 to-brand-700 text-sm font-bold text-stone-950"
        >
          C
        </span>
        <div class="leading-tight">
          <p class="text-sm font-semibold text-stone-100">Cofibuy</p>
          <p class="text-xs text-stone-500">{{ t('admin.nav.admin') }}</p>
        </div>
      </div>

      <nav class="flex-1 space-y-1 overflow-y-auto p-3">
        <router-link
          v-for="item in visibleItems"
          :key="item.to"
          :to="item.to"
          class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition"
          :class="
            isActive(item.to)
              ? 'bg-brand-500/10 text-brand-300 ring-1 ring-brand-500/30'
              : 'text-stone-400 hover:bg-white/5 hover:text-stone-100'
          "
        >
          <AppIcon :name="item.icon" />
          {{ t(item.label) }}
        </router-link>
      </nav>

      <div class="border-t border-white/10 p-3">
        <div class="mb-2 flex items-center gap-3 rounded-lg bg-white/5 p-3">
          <span
            class="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-white/10 text-xs font-semibold text-stone-300 uppercase"
          >
            {{ initials }}
          </span>
          <div class="min-w-0 leading-tight">
            <p class="truncate text-sm font-medium text-stone-100">{{ user?.email }}</p>
            <p class="text-xs text-stone-500 capitalize">{{ roleLabel }}</p>
          </div>
        </div>
        <button class="btn-secondary w-full" type="button" @click="handleSignOut">
          <AppIcon name="logout" :size="18" />
          Sign out
        </button>
      </div>
    </aside>

    <!-- Mobile top bar -->
    <header
      class="sticky top-0 z-20 flex h-16 items-center justify-between border-b border-white/10 bg-stone-950/95 px-4 backdrop-blur lg:hidden"
    >
      <div class="flex items-center gap-2.5">
        <span
          class="grid h-8 w-8 place-items-center rounded-lg bg-gradient-to-br from-brand-400 to-brand-700 text-sm font-bold text-stone-950"
        >
          C
        </span>
        <span class="text-sm font-semibold text-stone-100">{{ t('admin.title') }}</span>
      </div>
      <button
        type="button"
        class="btn-secondary !px-2.5 !py-2"
        :aria-expanded="navOpen"
        :aria-label="t('admin.nav.toggleNav')"
        @click="navOpen = !navOpen"
      >
        <AppIcon :name="navOpen ? 'close' : 'menu'" />
      </button>
    </header>

    <nav v-if="navOpen" class="border-b border-white/10 bg-stone-950/95 p-3 lg:hidden">
      <router-link
        v-for="item in visibleItems"
        :key="item.to"
        :to="item.to"
        class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium"
        :class="
          isActive(item.to) ? 'bg-brand-500/10 text-brand-300' : 'text-stone-400 hover:bg-white/5'
        "
        @click="navOpen = false"
      >
        <AppIcon :name="item.icon" />
        {{ t(item.label) }}
      </router-link>
      <button class="btn-secondary mt-2 w-full" type="button" @click="handleSignOut">
        <AppIcon name="logout" :size="18" />
        Sign out
      </button>
    </nav>

    <main class="lg:pl-64">
      <div class="mx-auto max-w-6xl px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
        <router-view />
      </div>
    </main>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import AppIcon from '@/components/AppIcon.vue'
import { useAuthSession } from '@/composables/useAuthSession'
import { useStaffRole } from '@/composables/useStaffRole'
import { useAdminI18n } from '@/i18n/admin'

interface NavItem {
  to: string
  label: string
  icon: string
  ownerOnly?: boolean
}

const ITEMS: NavItem[] = [
  { to: '/admin', label: 'admin.nav.dashboard', icon: 'wallet' },
  { to: '/admin/queue', label: 'admin.nav.queue', icon: 'queue' },
  { to: '/admin/pages', label: 'admin.nav.pages', icon: 'link' },
  { to: '/admin/gateways', label: 'admin.nav.gateways', icon: 'card' },
  { to: '/admin/team', label: 'admin.nav.team', icon: 'team', ownerOnly: true },
  { to: '/admin/settings', label: 'admin.nav.settings', icon: 'settings', ownerOnly: true },
  { to: '/admin/ai', label: 'admin.nav.ai', icon: 'lock', ownerOnly: true },
]

const { t } = useAdminI18n()
const route = useRoute()
const router = useRouter()
const { user, signOut } = useAuthSession()
const { role, isOwner } = useStaffRole()

const navOpen = ref(false)

const visibleItems = computed(() => ITEMS.filter((item) => !item.ownerOnly || isOwner.value))

// Exact match for the index routes, prefix match for nested ones such as
// /admin/pages/:id/edit, so the parent stays highlighted while editing.
function isActive(to: string): boolean {
  // The dashboard owns exactly `/admin`. A prefix match would keep it lit on
  // every page in the panel, since all of them start there.
  if (to === '/admin') return route.path === '/admin'
  return route.path === to || route.path.startsWith(`${to}/`)
}

const initials = computed(() => (user.value?.email ?? '?').slice(0, 2))

const roleLabel = computed(() => {
  if (role.value === 'none') return t('admin.errors.noAccess')
  return role.value === 'owner' ? t('admin.team.owner') : t('admin.team.staff')
})

watch(
  () => route.fullPath,
  () => (navOpen.value = false),
)

const handleSignOut = async (): Promise<void> => {
  navOpen.value = false
  await signOut()
  router.push('/admin/login')
}
</script>

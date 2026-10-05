<template>
  <div class="min-h-screen bg-stone-50">
    <!-- Desktop sidebar -->
    <aside
      class="fixed inset-y-0 left-0 hidden w-64 flex-col border-r border-stone-200 bg-white lg:flex"
    >
      <div class="flex h-16 items-center gap-3 border-b border-stone-200 px-5">
        <span
          class="grid h-9 w-9 place-items-center rounded-lg bg-brand-700 text-sm font-bold text-white"
        >
          C
        </span>
        <div class="leading-tight">
          <p class="text-sm font-semibold text-stone-900">Cofibuy</p>
          <p class="text-xs text-stone-500">Admin</p>
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
              ? 'bg-brand-50 text-brand-800 ring-1 ring-brand-200'
              : 'text-stone-600 hover:bg-stone-100 hover:text-stone-900'
          "
        >
          <AppIcon :name="item.icon" />
          {{ item.label }}
        </router-link>
      </nav>

      <div class="border-t border-stone-200 p-3">
        <div class="mb-2 flex items-center gap-3 rounded-lg bg-stone-50 p-3">
          <span
            class="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-stone-200 text-xs font-semibold text-stone-700 uppercase"
          >
            {{ initials }}
          </span>
          <div class="min-w-0 leading-tight">
            <p class="truncate text-sm font-medium text-stone-800">{{ user?.email }}</p>
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
      class="sticky top-0 z-20 flex h-16 items-center justify-between border-b border-stone-200 bg-white px-4 lg:hidden"
    >
      <div class="flex items-center gap-2.5">
        <span
          class="grid h-8 w-8 place-items-center rounded-lg bg-brand-700 text-sm font-bold text-white"
        >
          C
        </span>
        <span class="text-sm font-semibold text-stone-900">Cofibuy Admin</span>
      </div>
      <button
        type="button"
        class="btn-secondary !px-2.5 !py-2"
        :aria-expanded="navOpen"
        aria-label="Toggle navigation"
        @click="navOpen = !navOpen"
      >
        <AppIcon :name="navOpen ? 'close' : 'menu'" />
      </button>
    </header>

    <nav v-if="navOpen" class="border-b border-stone-200 bg-white p-3 lg:hidden">
      <router-link
        v-for="item in visibleItems"
        :key="item.to"
        :to="item.to"
        class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium"
        :class="
          isActive(item.to) ? 'bg-brand-50 text-brand-800' : 'text-stone-600 hover:bg-stone-100'
        "
        @click="navOpen = false"
      >
        <AppIcon :name="item.icon" />
        {{ item.label }}
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

interface NavItem {
  to: string
  label: string
  icon: string
  ownerOnly?: boolean
}

const ITEMS: NavItem[] = [
  { to: '/admin/queue', label: 'Order queue', icon: 'queue' },
  { to: '/admin/links', label: 'Links', icon: 'link' },
  { to: '/admin/gateways', label: 'Gateways', icon: 'card' },
  { to: '/admin/team', label: 'Team', icon: 'team', ownerOnly: true },
  { to: '/admin/settings', label: 'Settings', icon: 'settings', ownerOnly: true },
  { to: '/admin/copy', label: 'Site copy', icon: 'sparkles', ownerOnly: true },
]

const route = useRoute()
const router = useRouter()
const { user, signOut } = useAuthSession()
const { role, isOwner } = useStaffRole()

const navOpen = ref(false)

const visibleItems = computed(() => ITEMS.filter((item) => !item.ownerOnly || isOwner.value))

// Exact match for the index routes, prefix match for nested ones such as
// /admin/links/:id/edit, so the parent stays highlighted while editing.
function isActive(to: string): boolean {
  return route.path === to || route.path.startsWith(`${to}/`)
}

const initials = computed(() => (user.value?.email ?? '?').slice(0, 2))

const roleLabel = computed(() => {
  if (role.value === 'none') return 'No access'
  return role.value === 'owner' ? 'Owner' : 'Staff'
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

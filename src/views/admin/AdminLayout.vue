<template>
  <div class="flex min-h-screen bg-gray-100">
    <aside class="w-64 bg-white shadow-md">
      <div class="border-b border-gray-200 p-4">
        <h1 class="text-xl font-bold text-gray-900">Cofibuy Admin</h1>
        <p v-if="user?.email" class="mt-1 text-xs text-gray-500">{{ user.email }}</p>
        <p v-if="role !== 'none'" class="text-xs font-medium text-blue-600">{{ role }}</p>
      </div>

      <nav class="mt-4 space-y-1 p-4">
        <router-link
          to="/admin/queue"
          class="block rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-100"
          :class="$route.path === '/admin/queue' ? 'bg-gray-100 text-gray-900' : 'text-gray-700'"
        >
          Order Queue
        </router-link>
        <router-link
          to="/admin/links"
          class="block rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-100"
          :class="
            $route.path.startsWith('/admin/links') ? 'bg-gray-100 text-gray-900' : 'text-gray-700'
          "
        >
          Links
        </router-link>
        <router-link
          to="/admin/gateways"
          class="block rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-100"
          :class="
            $route.path.startsWith('/admin/gateways')
              ? 'bg-gray-100 text-gray-900'
              : 'text-gray-700'
          "
        >
          Payment Methods
        </router-link>
        <router-link
          v-if="isOwner"
          to="/admin/team"
          class="block rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-100"
          :class="$route.path === '/admin/team' ? 'bg-gray-100 text-gray-900' : 'text-gray-700'"
        >
          Team
        </router-link>
        <router-link
          v-if="isOwner"
          to="/admin/settings"
          class="block rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-100"
          :class="$route.path === '/admin/settings' ? 'bg-gray-100 text-gray-900' : 'text-gray-700'"
        >
          Settings
        </router-link>
      </nav>

      <div class="absolute bottom-0 w-64 border-t border-gray-200 p-4">
        <button
          @click="handleSignOut"
          class="w-full rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700"
        >
          Sign Out
        </button>
      </div>
    </aside>

    <main class="flex-1 overflow-y-auto p-8">
      <router-view />
    </main>
  </div>
</template>

<script setup lang="ts">
import { useRouter } from 'vue-router'
import { useAuthSession } from '@/composables/useAuthSession'
import { useStaffRole } from '@/composables/useStaffRole'

const router = useRouter()
const { user, signOut } = useAuthSession()
const { role, isOwner } = useStaffRole()

const handleSignOut = async (): Promise<void> => {
  await signOut()
  router.push('/admin/login')
}
</script>

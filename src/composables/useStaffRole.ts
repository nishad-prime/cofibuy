import { ref, computed, onUnmounted, type Ref, type ComputedRef } from 'vue'
import { getSupabase } from '@/lib/supabase'
import { useAuthSession } from './useAuthSession'

export type StaffRole = 'owner' | 'staff' | 'none'

export interface StaffRoleState {
  role: Ref<StaffRole>
  isStaff: ComputedRef<boolean>
  isOwner: ComputedRef<boolean>
  loading: Ref<boolean>
  refresh: () => Promise<void>
}

export function useStaffRole(): StaffRoleState {
  const { user, isAuthenticated } = useAuthSession()
  const supabase = getSupabase()

  const role = ref<StaffRole>('none')
  const loading = ref(false)
  let lastCheckedUserId: string | null = null

  const isStaff = computed(() => role.value === 'staff' || role.value === 'owner')
  const isOwner = computed(() => role.value === 'owner')

  const refresh = async (): Promise<void> => {
    if (!isAuthenticated.value || !user.value) {
      role.value = 'none'
      lastCheckedUserId = null
      return
    }

    const currentUserId = user.value.id
    if (lastCheckedUserId === currentUserId && role.value !== 'none') {
      return
    }

    loading.value = true

    try {
      // Probe with staff-gated RPC (admin_stats) to determine staff capability
      const { error: statsError } = await (supabase.rpc as any)('admin_stats')

      if (statsError) {
        role.value = 'none'
        lastCheckedUserId = null
        return
      }

      // User is staff-capable (owner is also staff). Check if owner by attempting owner-only RPC
      const { error: teamError } = await (supabase.rpc as any)('admin_team')

      if (teamError) {
        // Permission denied or other error - likely staff but not owner
        role.value = 'staff'
        lastCheckedUserId = currentUserId
        return
      }

      // admin_team succeeded - user has owner access
      role.value = 'owner'
      lastCheckedUserId = currentUserId
    } catch {
      role.value = 'none'
      lastCheckedUserId = null
    } finally {
      loading.value = false
    }
  }

  // Watch for auth changes
  const unwatch = (() => {
    let previousAuth = false
    let previousUserId: string | null = null

    const check = () => {
      const currentAuth = isAuthenticated.value
      const currentUserId = user.value?.id ?? null

      if (currentAuth !== previousAuth || currentUserId !== previousUserId) {
        previousAuth = currentAuth
        previousUserId = currentUserId
        void refresh()
      }
    }

    const interval = setInterval(check, 500)
    return () => clearInterval(interval)
  })()

  onUnmounted(() => {
    unwatch()
  })

  return {
    role,
    isStaff,
    isOwner,
    loading,
    refresh,
  }
}

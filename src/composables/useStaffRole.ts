import { ref, computed, getCurrentInstance, onUnmounted, type Ref, type ComputedRef } from 'vue'
import { getSupabase } from '@/lib/supabase'
import { useAuthSession, whenAuthReady } from './useAuthSession'

export type StaffRole = 'owner' | 'staff' | 'none'

export interface StaffRoleState {
  role: Ref<StaffRole>
  isStaff: ComputedRef<boolean>
  isOwner: ComputedRef<boolean>
  loading: Ref<boolean>
  refresh: () => Promise<void>
}

/*
 * Shared for the same reason as the session refs in `useAuthSession`: the
 * router guard and the views have to agree on one answer, and `refresh()` has
 * to observe the session the auth listener actually wrote.
 */
const role = ref<StaffRole>('none')
const loading = ref(false)
let lastCheckedUserId: string | null = null
let refreshPromise: Promise<void> | null = null

const isStaff = computed(() => role.value === 'staff' || role.value === 'owner')
const isOwner = computed(() => role.value === 'owner')

async function runProbes(): Promise<void> {
  const supabase = getSupabase()

  // `admin_stats` is gated on staff, so succeeding proves the capability
  // without a dedicated role RPC.
  const { error: statsError } = await (supabase.rpc as any)('admin_stats')

  if (statsError) {
    role.value = 'none'
    lastCheckedUserId = null
    return
  }

  // `admin_team` is owner-only, so success is the only positive signal
  // available for the owner tier.
  const { error: teamError } = await (supabase.rpc as any)('admin_team')

  role.value = teamError ? 'staff' : 'owner'
}

async function refresh(): Promise<void> {
  const { user, isAuthenticated } = useAuthSession()

  await whenAuthReady()

  if (!user.value) {
    role.value = 'none'
    lastCheckedUserId = null
    return
  }

  if (!isAuthenticated.value) {
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
    await runProbes()
    if (role.value !== 'none') {
      lastCheckedUserId = currentUserId
    }
  } catch {
    role.value = 'none'
    lastCheckedUserId = null
  } finally {
    loading.value = false
  }
}

/** Coalesces concurrent callers, e.g. the guard and a view mounting together. */
function refreshOnce(): Promise<void> {
  if (!refreshPromise) {
    refreshPromise = refresh().finally(() => {
      refreshPromise = null
    })
  }
  return refreshPromise
}

let watcherStarted = false
let pollTimer: ReturnType<typeof setInterval> | null = null

function startWatcher(): void {
  if (watcherStarted) return
  watcherStarted = true

  const { user, isAuthenticated } = useAuthSession()

  let previousUserId: string | null = null

  pollTimer = setInterval(() => {
    const currentUserId = user.value?.id ?? null
    const currentAuth = isAuthenticated.value

    if (currentUserId !== previousUserId || currentAuth !== !!previousUserId) {
      previousUserId = currentUserId
      void refreshOnce()
    }
  }, 500)
}

export function useStaffRole(): StaffRoleState {
  const { user, isAuthenticated } = useAuthSession()

  // A signed-in session may already exist before the first component mounts,
  // so the initial answer has to be filled in immediately rather than waiting
  // for the poll to notice.
  if (!user.value && !isAuthenticated.value) {
    lastCheckedUserId = null
  }

  startWatcher()

  if (getCurrentInstance()) {
    onUnmounted(() => {
      if (pollTimer) {
        clearInterval(pollTimer)
        pollTimer = null
        watcherStarted = false
      }
    })
  }

  return {
    role,
    isStaff,
    isOwner,
    loading,
    refresh: refreshOnce,
  }
}

import { type RouteLocationNormalized, type NavigationGuardNext } from 'vue-router'
import { useStaffRole } from './useStaffRole'
import { useAuthSession } from './useAuthSession'

export function useAdminGuard() {
  const { isAuthenticated } = useAuthSession()
  const { isStaff, isOwner, refresh } = useStaffRole()

  const requireStaff = async (
    _to: RouteLocationNormalized,
    _from: RouteLocationNormalized,
    next: NavigationGuardNext,
  ): Promise<void> => {
    if (!isAuthenticated.value) {
      next({ path: '/admin/login' })
      return
    }

    await refresh()

    if (!isStaff.value) {
      next({ path: '/admin/login', query: { error: 'notStaff' } })
      return
    }

    next()
  }

  const requireOwner = async (
    _to: RouteLocationNormalized,
    _from: RouteLocationNormalized,
    next: NavigationGuardNext,
  ): Promise<void> => {
    if (!isAuthenticated.value) {
      next({ path: '/admin/login' })
      return
    }

    await refresh()

    if (!isStaff.value) {
      next({ path: '/admin/login', query: { error: 'notStaff' } })
      return
    }

    if (!isOwner.value) {
      next({ path: '/admin/queue', query: { error: 'forbidden' } })
      return
    }

    next()
  }

  return {
    requireStaff,
    requireOwner,
  }
}

import { type RouteLocationNormalized, type NavigationGuardNext } from 'vue-router'
import { useStaffRole } from './useStaffRole'
import { useAuthSession, whenAuthReady } from './useAuthSession'

export function useAdminGuard() {
  const { isAuthenticated } = useAuthSession()
  const { isStaff, isOwner, refresh } = useStaffRole()

  const requireStaff = async (
    _to: RouteLocationNormalized,
    _from: RouteLocationNormalized,
    next: NavigationGuardNext,
  ): Promise<void> => {
    // Without this the first navigation after a page load is decided before
    // the persisted session has been read, and a signed-in admin is bounced to
    // the login form on every refresh.
    await whenAuthReady()

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
    await whenAuthReady()

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

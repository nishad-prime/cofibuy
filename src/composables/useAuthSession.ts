import { ref, getCurrentInstance, onUnmounted, type Ref } from 'vue'
import { getSupabase } from '@/lib/supabase'
import type { Session, User } from '@supabase/supabase-js'

export interface AuthSession {
  session: Ref<Session | null>
  user: Ref<User | null>
  isAuthenticated: Ref<boolean>
  signOut: () => Promise<void>
}

/*
 * Module-level so every caller shares one state.
 *
 * `useAdminGuard` runs inside router guards, which are outside any component
 * instance, so a per-call `ref` meant the guard, the login view and
 * `useStaffRole` each held a different `user`. `refresh()` then read a `user`
 * that was never populated, concluded the caller was not staff and left the
 * login form in place after a successful sign-in.
 */
const session = ref<Session | null>(null)
const user = ref<User | null>(null)
const isAuthenticated = ref(false)

let initialised = false
let subscriberCount = 0
let unsubscribe: (() => void) | null = null
let readyPromise: Promise<void> | null = null

function applySession(next: Session | null): void {
  session.value = next
  user.value = next?.user ?? null
  isAuthenticated.value = !!next
}

function ensureInitialised(): void {
  if (initialised) return
  initialised = true
  readyPromise = null

  const supabase = getSupabase()

  // Reading storage is asynchronous, so anything that runs before it settles
  // would otherwise see an anonymous app. `whenReady` exists for that reason.
  readyPromise = supabase.auth
    .getSession()
    .then(({ data }: { data: { session: Session | null } }) => applySession(data.session))
    .catch(() => {
      // A failed read leaves the state anonymous; the next auth event or an
      // explicit sign-in will populate it.
    })

  const {
    data: { subscription },
  } = supabase.auth.onAuthStateChange((_event: string, next: Session | null) => applySession(next))

  unsubscribe = () => subscription.unsubscribe()
}

function release(): void {
  subscriberCount -= 1
  if (subscriberCount <= 0 && unsubscribe) {
    unsubscribe()
    unsubscribe = null
    initialised = false
    readyPromise = null
  }
}

/**
 * Resolves once the persisted session has been read.
 *
 * The router guard has to await this: on a hard reload the first navigation is
 * decided before `getSession()` returns, and treating that as "anonymous"
 * throws a signed-in admin back to the login form.
 */
export function whenAuthReady(): Promise<void> {
  ensureInitialised()
  return readyPromise ?? Promise.resolve()
}

export function useAuthSession(): AuthSession {
  ensureInitialised()
  subscriberCount += 1

  // Only a component can clean up after itself. The router guard is not one,
  // so it deliberately leaks the single shared subscription instead.
  if (getCurrentInstance()) {
    onUnmounted(release)
  }

  const signOut = async (): Promise<void> => {
    await getSupabase().auth.signOut()
  }

  return {
    session,
    user,
    isAuthenticated,
    signOut,
  }
}

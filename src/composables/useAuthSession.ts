import { ref, onUnmounted, type Ref } from 'vue'
import { getSupabase } from '@/lib/supabase'
import type { Session, User } from '@supabase/supabase-js'

export interface AuthSession {
  session: Ref<Session | null>
  user: Ref<User | null>
  isAuthenticated: Ref<boolean>
  signOut: () => Promise<void>
}

export function useAuthSession(): AuthSession {
  const supabase = getSupabase()
  const session = ref<Session | null>(null)
  const user = ref<User | null>(null)
  const isAuthenticated = ref(false)

  // Initialize current session
  supabase.auth
    .getSession()
    .then(({ data }) => {
      session.value = data.session
      user.value = data.session?.user ?? null
      isAuthenticated.value = !!data.session
    })
    .catch(() => {
      // Ignore session init errors - will be handled on auth state change
    })

  const {
    data: { subscription },
  } = supabase.auth.onAuthStateChange((_event, newSession) => {
    session.value = newSession
    user.value = newSession?.user ?? null
    isAuthenticated.value = !!newSession
  })

  onUnmounted(() => {
    subscription.unsubscribe()
  })

  const signOut = async (): Promise<void> => {
    await supabase.auth.signOut()
  }

  return {
    session,
    user,
    isAuthenticated,
    signOut,
  }
}

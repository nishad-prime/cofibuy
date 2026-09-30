import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { requireSupabaseConfig } from './env'
import type { Database } from './database.types'

let client: SupabaseClient<Database> | null = null

/**
 * Lazily creates the Supabase client.
 *
 * Created on first use rather than at import time so the static shell boots
 * without a configured project, and so the anon key is never read into a
 * module that a tooling pass might evaluate.
 */
export function getSupabase(): SupabaseClient<Database> {
  if (client) return client

  const { url, anonKey } = requireSupabaseConfig()
  client = createClient<Database>(url, anonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
      // Bangladesh carrier CGNAT makes IP-based anonymous sign-in limits a real
      // problem. The app mitigates with lazy auth plus Turnstile; see
      // `useAuthSession`.
      flowType: 'pkce',
    },
    global: {
      headers: { 'x-application-name': 'cofibuy' },
    },
  })

  return client
}

/** Test seam: replaces the memoised client. */
export function __setSupabaseClientForTests(next: SupabaseClient<Database> | null): void {
  client = next
}

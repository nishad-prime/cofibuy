/**
 * Environment configuration.
 *
 * The repository contains no credentials. Both values come from the host's
 * environment at build time, and both are safe to ship to the browser: the
 * anon key is constrained entirely by row level security.
 *
 * Validation is deferred rather than throwing at import time so the static
 * shell (routing, locale resolution, fonts) can boot — and be tested — before
 * anyone has configured a project.
 */

export type SupabaseConfig = {
  url: string
  anonKey: string
}

function readConfig(): SupabaseConfig | null {
  const url = import.meta.env.VITE_SUPABASE_URL?.trim()
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim()

  if (!url || !anonKey) return null
  if (!/^https?:\/\//.test(url)) return null

  return { url: url.replace(/\/+$/, ''), anonKey }
}

export const supabaseConfig: SupabaseConfig | null = readConfig()

export const isSupabaseConfigured = supabaseConfig !== null

/**
 * Raised when a code path that needs the database is reached without a
 * configured project. Deliberately explicit rather than a silent stub.
 */
export class SupabaseNotConfiguredError extends Error {
  constructor() {
    super(
      'Supabase is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY, ' +
        'then restart the dev server. See .env.example.',
    )
    this.name = 'SupabaseNotConfiguredError'
  }
}

export function requireSupabaseConfig(): SupabaseConfig {
  if (!supabaseConfig) throw new SupabaseNotConfiguredError()
  return supabaseConfig
}

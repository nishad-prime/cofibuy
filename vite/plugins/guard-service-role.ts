import type { Plugin } from 'vite'

/**
 * Fails the build if a privileged Supabase credential reaches the client bundle.
 *
 * Two checks:
 *  1. Config time — refuse to run if a VITE_-prefixed variable looks privileged.
 *  2. Bundle time — scan emitted chunks for the literal `service_role` role name.
 *
 * The anon key is publishable by design and is fine in the bundle. The
 * service_role key bypasses every row level security policy, so leaking it is
 * equivalent to publishing the entire database.
 */
const FORBIDDEN_ROLE = ['service', 'role'].join('_')

const FORBIDDEN_ENV_NAMES = [
  'VITE_SUPABASE_SERVICE_ROLE_KEY',
  'VITE_SUPABASE_SERVICE_KEY',
  'VITE_SUPABASE_DB_URL',
  'VITE_SUPABASE_DB_PASSWORD',
  'VITE_SUPABASE_ACCESS_TOKEN',
]

/** service_role JWTs: three base64url segments, middle one is the claims object. */
const JWT_PATTERN = /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g

function decodeJwtClaims(token: string): string {
  try {
    const segment = token.split('.')[1] ?? ''
    return Buffer.from(segment, 'base64url').toString('utf8')
  } catch {
    return ''
  }
}

function checkEnv(): void {
  const offenders: string[] = []

  for (const name of FORBIDDEN_ENV_NAMES) {
    if (process.env[name]) offenders.push(name)
  }

  for (const [name, value] of Object.entries(process.env)) {
    if (!name.startsWith('VITE_') || !value) continue
    if (value.includes(FORBIDDEN_ROLE)) offenders.push(name)
  }

  if (offenders.length > 0) {
    throw new Error(
      `[guard-service-role] Refusing to build. Privileged Supabase values found in ` +
        `client-exposed environment: ${offenders.join(', ')}. ` +
        `Service-role keys must never use a VITE_ prefix; they belong in the OTP ` +
        `worker or database tooling, not in the app.`,
    )
  }
}

export function guardServiceRole(): Plugin {
  return {
    name: 'cofibuy:guard-service-role',
    enforce: 'pre',
    configResolved() {
      checkEnv()
    },
    generateBundle(_options, bundle) {
      const offenders: string[] = []

      for (const [fileName, output] of Object.entries(bundle)) {
        if (output.type !== 'chunk') continue
        const code = output.code

        if (code.includes(FORBIDDEN_ROLE)) {
          offenders.push(`${fileName}: contains the privileged role name`)
          continue
        }

        for (const token of code.match(JWT_PATTERN) ?? []) {
          if (decodeJwtClaims(token).includes(FORBIDDEN_ROLE)) {
            offenders.push(`${fileName}: contains a privileged-role JWT`)
          }
        }
      }

      if (offenders.length > 0) {
        this.error(
          `[guard-service-role] Refusing to emit a bundle that may leak database ` +
            `credentials:\n  - ${offenders.join('\n  - ')}`,
        )
      }
    },
  }
}

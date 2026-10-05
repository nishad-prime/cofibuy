/**
 * The bKash token, fetched under a lease.
 *
 * Split out of the two functions because the rule is subtle and worth stating once: a
 * caller that finds a usable, unexpired token must use it. Only a caller that *claims* the
 * refresh lease is allowed to spend one of the two hourly calls, and a caller that loses the
 * race re-reads the token the winner just stored rather than calling bKash itself.
 *
 * Losing the race is normal under load, not an error. Six customers checking out in the same
 * second is a good minute for the shop, and five of them getting a slightly stale token for
 * a few hundred milliseconds is the correct outcome.
 *
 * Every call is keyed on `bundleId`, never on the environment. A bKash token belongs to one
 * app_key, so two gateways on different merchant accounts must never share one - C2 dropped
 * the environment-keyed functions for exactly that reason, and reintroducing an
 * environment here would hand merchant A's token to merchant B.
 */

import type { ApiClient } from './supabase.ts'
import { grantToken, refreshToken_, type BkashCredentials, type BkashEnvironment } from './bkash.ts'

type TokenState = {
  usable: boolean
  bootstrap: boolean
  refreshing: boolean
  id_token?: string
  refresh_token?: string
  needs_refresh?: boolean
}

export class TokenUnavailableError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'TokenUnavailableError'
  }
}

/**
 * @param admin a service-role client. The token functions are revoked from anon and
 *   authenticated on purpose, so this is the only way to reach them.
 */
export async function bkashIdToken(
  admin: ApiClient,
  bundleId: string,
  environment: BkashEnvironment,
  credentials: BkashCredentials,
): Promise<string> {
  const state = await readState(admin, bundleId, environment)

  if (state.usable && state.id_token && !state.needs_refresh) {
    return state.id_token
  }

  // Somebody else is mid-refresh. Their token lands in the table within a second or two;
  // waiting briefly beats racing them and burning the hourly allowance.
  if (state.refreshing) {
    const waited = await waitForToken(admin, bundleId, environment)
    if (waited) return waited
    throw new TokenUnavailableError(
      'another request is refreshing the bkash token; try again in a moment',
    )
  }

  const claimed = await admin.rpc('bkash_claim_refresh', {
    p_bundle_id: bundleId,
    p_environment: environment,
  })
  if (claimed.error) {
    throw new TokenUnavailableError(`could not claim the token refresh: ${claimed.error.message}`)
  }
  if (claimed.data !== true) {
    // Lost the race between reading the state and claiming. The winner stores before it
    // releases, so what is in the table now is theirs.
    const waited = await waitForToken(admin, bundleId, environment)
    if (waited) return waited
    throw new TokenUnavailableError('could not obtain a bkash token; try again in a moment')
  }

  try {
    // A first-ever call has no refresh token, so it must be a grant. The branch is on
    // `bootstrap` rather than on the presence of a refresh token because a missing refresh
    // token with an existing id_token is corruption, and silently granting would paper
    // over it by spending the refresh allowance.
    const minted = state.bootstrap
      ? await grantToken(environment, credentials)
      : await refreshToken_(environment, credentials, state.refresh_token ?? '')

    const stored = await admin.rpc('bkash_store_token', {
      p_bundle_id: bundleId,
      p_environment: environment,
      p_id_token: minted.idToken,
      p_refresh_token: minted.refreshToken,
      p_expires_in: minted.expiresIn,
    })
    if (stored.error) {
      throw new TokenUnavailableError(`could not store the bkash token: ${stored.error.message}`)
    }

    return minted.idToken
  } catch (cause) {
    // Release the lease, or this failure costs every other checkout 60 seconds of waiting
    // on a refresh that is not going to happen.
    await admin.rpc('bkash_release_refresh', {
      p_bundle_id: bundleId,
      p_environment: environment,
    })
    throw cause
  }
}

async function readState(
  admin: ApiClient,
  bundleId: string,
  environment: BkashEnvironment,
): Promise<TokenState> {
  const { data, error } = await admin.rpc('bkash_token_state', {
    p_bundle_id: bundleId,
    p_environment: environment,
  })
  if (error) {
    throw new TokenUnavailableError(`could not read the bkash token state: ${error.message}`)
  }
  return (data ?? {}) as TokenState
}

/**
 * Polls for the token a concurrent caller is writing. Four tries at 250ms is a second in
 * total, which covers a bKash round trip; past that the caller is told to retry rather than
 * being left waiting on a request that may never arrive.
 */
async function waitForToken(
  admin: ApiClient,
  bundleId: string,
  environment: BkashEnvironment,
): Promise<string | null> {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 250))
    const state = await readState(admin, bundleId, environment)
    if (state.usable && state.id_token && !state.needs_refresh) return state.id_token
  }
  return null
}

/**
 * Reads one gateway's bKash credentials.
 *
 * Two RPCs rather than one, and that is the existing design rather than an accident:
 * `gateway_credential_bundle` returns the *bundle id*, and `secret_bundle_open` turns that
 * into plaintext. Neither is executable as `authenticated`, so the only way to the password
 * is a service-role call from an Edge Function. Keeping the split means the Edge Function
 * holds a handle it can pass around, rather than a bundle that leaks the moment it is logged
 * by accident - and it means the plaintext crosses the wire exactly once, on the one
 * function whose entire job is to make an authenticated HTTP call.
 */
export async function readCredentials(
  admin: ApiClient,
  gatewayId: string,
): Promise<{ bundleId: string; credentials: BkashCredentials }> {
  const bundle = await admin.rpc('gateway_credential_bundle', { p_gateway_id: gatewayId })
  if (bundle.error) {
    throw new TokenUnavailableError(
      `could not look up credentials for gateway ${gatewayId}: ${bundle.error.message}`,
    )
  }

  const bundleId = bundle.data
  if (!bundleId) {
    // Named deliberately: the operator reading this log is the only person who can fix it,
    // and they need the gateway id to find the form. A generic "not configured" sends them
    // hunting through a list of gateways instead.
    throw new GatewayNotConfiguredError(
      `gateway ${gatewayId} has no bkash credentials saved; open the gateway form and save them before taking a payment`,
    )
  }

  const opened = await admin.rpc('secret_bundle_open', { p_bundle_id: bundleId })
  if (opened.error) {
    throw new TokenUnavailableError(
      `could not open credentials for gateway ${gatewayId}: ${opened.error.message}`,
    )
  }
  if (!opened.data) {
    // The row exists but its vault secret is gone. Different fault from the above and worth
    // separating: re-saving the gateway is the fix in both cases, but only one of them is
    // explained by someone having added the gateway and never filled the form in.
    throw new GatewayNotConfiguredError(
      `gateway ${gatewayId} has a credential row pointing at a deleted vault secret; re-save the gateway credentials`,
    )
  }

  return { bundleId, credentials: opened.data as BkashCredentials }
}

/** A gateway that cannot take a payment because it was never configured. Operator-fixable. */
export class GatewayNotConfiguredError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'GatewayNotConfiguredError'
  }
}

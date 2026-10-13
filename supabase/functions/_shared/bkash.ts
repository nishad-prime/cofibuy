/**
 * bKash Tokenized Checkout, from the server's side.
 *
 * Two things live here: the credential and token dance, and the three HTTP calls. Neither
 * is allowed to log the `id_token` or the bundle, because both of those are in every
 * request this file makes and a stray `console.log` of a response body would put a live
 * merchant JWT in the log store.
 *
 * The token is fetched from the database rather than cached in this isolate. Grant Token may
 * be called at most twice an hour and exceeding that blocks refreshes for a full hour, so
 * an isolate-local cache would spend the whole allowance during a traffic spike and then
 * refuse to take money. `api.bkash_claim_refresh` hands out a lease instead, so a burst of
 * checkouts results in one refresh.
 */

/** The two environments, and the base URL each one answers on. */
const BASE_URL = {
  sandbox: 'https://tokenized.sandbox.bka.sh/v1.2.0-beta/tokenized/checkout',
  live: 'https://tokenized.pay.bka.sh/v1.2.0-beta/tokenized/checkout',
} as const

export type BkashEnvironment = keyof typeof BASE_URL

/** A bKash credential bundle, as stored in `private.secret_bundles`. */
export interface BkashCredentials {
  username: string
  password: string
  app_key: string
  app_secret: string
}

/**
 * bKash answers 200 with a body describing the failure. `statusCode 0000` is the only
 * success; everything else is an error whose `statusMessage` is written for a human to
 * read. Treating HTTP 200 as success would approve orders bKash explicitly refused.
 */
export class BkashError extends Error {
  readonly statusCode: string

  constructor(statusCode: string, statusMessage: string) {
    super(`bkash ${statusCode}: ${statusMessage}`)
    this.name = 'BkashError'
    this.statusCode = statusCode
  }
}

/** Raised for a transport failure, a timeout, or an unparseable body. */
export class BkashTransportError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'BkashTransportError'
  }
}

/**
 * `2026-08-20` bKash accepts a 60 second id_token here; the checkout page itself lives at
 * the base URL with `/payment/create`. Keeping it as one template means the environment
 * cannot be chosen for one half of the flow and not the other.
 */
function checkoutUrl(environment: BkashEnvironment, path: string): string {
  return `${BASE_URL[environment]}${path}`
}

async function bkashFetch(
  environment: BkashEnvironment,
  path: string,
  init: { headers: Record<string, string>; body?: unknown; timeoutMs?: number },
): Promise<Record<string, unknown>> {
  const url = checkoutUrl(environment, path)
  const timeout = new AbortController()
  const timer = setTimeout(() => timeout.abort(), init.timeoutMs ?? 15_000)

  let response: Response
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: init.headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      signal: timeout.signal,
    })
  } catch (cause) {
    // The cause is deliberately not interpolated: an undici fetch error can carry the
    // request options, which carry the Authorization header.
    throw new BkashTransportError(
      `bkash ${path} could not be reached: ${cause instanceof Error ? cause.name : 'unknown'}`,
    )
  } finally {
    clearTimeout(timer)
  }

  let payload: Record<string, unknown>
  let text = ''
  try {
    text = await response.text()
    payload = JSON.parse(text) as Record<string, unknown>
  } catch {
    // bKash's bare 400s (unwhitelisted callbackURL, malformed amount) answer with a
    // non-JSON body or an empty one. The first 512 characters are logged so the
    // portal-side cause is visible; error bodies carry no token material.
    console.error(
      `bkash ${path} answered ${response.status} with a non-JSON body:`,
      text.slice(0, 512),
    )
    throw new BkashTransportError(
      `bkash ${path} answered ${response.status} with a body that is not JSON`,
    )
  }

  if (payload.statusCode !== '0000') {
    if (typeof payload.statusMessage !== 'string') {
      // A 400 whose JSON body lacks `statusMessage` is otherwise undiagnosable.
      // Log the body and surface a snippet to the caller; only error-shaped
      // payloads reach this branch, so no token material can be exposed.
      const snippet = JSON.stringify(payload).slice(0, 512)
      console.error(
        `bkash ${path} answered ${response.status} with no statusMessage; body:`,
        snippet,
      )
      throw new BkashError(
        typeof payload.statusCode === 'string' ? payload.statusCode : String(response.status),
        `no reason given; body: ${snippet}`,
      )
    }
    throw new BkashError(
      typeof payload.statusCode === 'string' ? payload.statusCode : String(response.status),
      payload.statusMessage,
    )
  }

  return payload
}

/** Grant Token. At most two per hour, which is why the result is stored in the database. */
export async function grantToken(
  environment: BkashEnvironment,
  credentials: BkashCredentials,
): Promise<{ idToken: string; refreshToken: string; expiresIn: number }> {
  const payload = await bkashFetch(environment, '/token/grant', {
    headers: {
      // bKash's token endpoints take the merchant username and password as headers;
      // there is no Basic auth in the Tokenized Checkout API.
      username: credentials.username,
      password: credentials.password,
      'content-type': 'application/json',
      'x-app-key': credentials.app_key,
    },
    body: { app_key: credentials.app_key, app_secret: credentials.app_secret },
  })

  const idToken = payload.id_token
  const refreshToken = payload.refresh_token
  if (typeof idToken !== 'string' || idToken === '' || typeof refreshToken !== 'string') {
    throw new BkashError('0000', 'grant succeeded but returned no token pair')
  }

  return {
    idToken,
    refreshToken,
    // A grant that omits the lifetime still means one hour. Assuming longer would leave us
    // calling a dead token until something failed visibly.
    expiresIn: typeof payload.expires_in === 'number' ? payload.expires_in : 3600,
  }
}

/**
 * Refresh Token, for the same two-per-hour allowance. `grantToken` exists because a
 * refresh needs the refresh token we do not have on a first-ever call.
 */
export async function refreshToken_(
  environment: BkashEnvironment,
  credentials: BkashCredentials,
  refreshToken: string,
): Promise<{ idToken: string; refreshToken: string; expiresIn: number }> {
  const payload = await bkashFetch(environment, '/token/refresh', {
    headers: {
      username: credentials.username,
      password: credentials.password,
      'content-type': 'application/json',
      'x-app-key': credentials.app_key,
    },
    body: {
      app_key: credentials.app_key,
      app_secret: credentials.app_secret,
      grant_token: refreshToken,
    },
  })

  const idToken = payload.id_token
  const nextRefresh = payload.refresh_token
  if (typeof idToken !== 'string' || idToken === '' || typeof nextRefresh !== 'string') {
    throw new BkashError('0000', 'refresh succeeded but returned no token pair')
  }

  return {
    idToken,
    refreshToken: nextRefresh,
    expiresIn: typeof payload.expires_in === 'number' ? payload.expires_in : 3600,
  }
}

/**
 * Create Payment. Returns the `paymentID` and the `bkashURL` the customer is sent to.
 *
 * The amount is a number and the currency is fixed, because the store only prices in BDT -
 * `api.bkash_payment_start` refuses anything else before this is reached.
 */
export async function createPayment(
  environment: BkashEnvironment,
  idToken: string,
  credentials: BkashCredentials,
  request: {
    amount: number
    currency: string
    invoice: string
    payerReference: string
    /** Where bKash sends the browser when the payment finishes. Must be one of the
     * URLs whitelisted in the bKash merchant portal, or bKash refuses the create. */
    callbackUrl: string
  },
): Promise<{ paymentId: string; redirectUrl: string }> {
  const payload = await bkashFetch(environment, '/create', {
    headers: {
      authorization: `Bearer ${idToken}`,
      'content-type': 'application/json',
      'x-app-key': credentials.app_key,
      // /create and /execute want the merchant credentials as headers, unlike
      // the token endpoints which take them in the Basic auth or the body.
      username: credentials.username,
      password: credentials.password,
    },
    body: {
      // `mode` 0011 is Tokenized Checkout, and `callbackURL` is mandatory with it.
      // Neither was sent for the whole life of this function: bKash answered every
      // create with a bare 400, which is what "the bKash function doesn't work"
      // turned out to be.
      mode: '0011',
      callbackURL: request.callbackUrl,
      amount: request.amount.toFixed(2),
      currency: request.currency,
      intent: 'sale',
      merchantInvoiceNumber: request.invoice,
      payerReference: request.payerReference,
    },
  })

  const paymentId = payload.paymentID
  const redirectUrl = payload.bkashURL
  if (typeof paymentId !== 'string' || paymentId === '' || typeof redirectUrl !== 'string') {
    throw new BkashError('0000', 'create succeeded but returned no payment id or url')
  }

  return { paymentId, redirectUrl }
}

/**
 * Execute Payment. **Callable exactly once per `paymentID`.** After one attempt bKash
 * refuses the payment id for good, so a retry here is not "try again", it is "give up" -
 * and Query Payment, which is safe to repeat, is what should follow an uncertain result.
 *
 * Returns the trx id and payer account. `amount` is reported by bKash and compared against
 * the order by `api.bkash_settle_order` before anything is approved.
 */
export async function executePayment(
  environment: BkashEnvironment,
  idToken: string,
  credentials: BkashCredentials,
  paymentId: string,
): Promise<{
  trxId: string
  payerAccount: string | null
  amount: number | null
  currency: string | null
}> {
  const payload = await bkashFetch(environment, '/payment/execute', {
    headers: {
      authorization: `Bearer ${idToken}`,
      'content-type': 'application/json',
      'x-app-key': credentials.app_key,
      username: credentials.username,
      password: credentials.password,
    },
    body: { paymentID: paymentId },
  })

  const trxId = payload.trxID
  if (typeof trxId !== 'string' || trxId === '') {
    throw new BkashError('0000', 'execute succeeded but returned no trx id')
  }

  return {
    trxId,
    payerAccount: typeof payload.payerAccount === 'string' ? payload.payerAccount : null,
    amount: typeof payload.amount === 'number' ? payload.amount : null,
    currency: typeof payload.currency === 'string' ? payload.currency : null,
  }
}

/** Narrows the environment the database handed back, refusing anything else. */
export function asEnvironment(value: unknown): BkashEnvironment {
  if (value === 'sandbox' || value === 'live') return value
  throw new BkashTransportError(`unknown bkash environment: ${String(value)}`)
}

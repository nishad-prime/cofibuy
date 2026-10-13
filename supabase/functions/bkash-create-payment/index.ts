/**
 * POST /functions/v1/bkash-create-payment
 *
 * Starts a bKash payment for one of the caller's own orders and hands back the URL bKash
 * wants the customer at. Nothing is settled here; this function cannot approve an order
 * even in principle, because approving needs a trx id and only Execute Payment produces one.
 *
 * Runs for sandbox gateways as well as live ones. That is the point of a sandbox merchant:
 * the request shapes, the token dance and the redirect can all be exercised end to end with
 * no money moving. The refusal lives in `api.bkash_settle_order`, which is where a sandbox
 * result would otherwise become an access grant.
 */

import { serviceClient, userClientFor } from '../_shared/supabase.ts'
import { asEnvironment, BkashError, BkashTransportError, createPayment } from '../_shared/bkash.ts'
import {
  bkashIdToken,
  GatewayNotConfiguredError,
  readCredentials,
  TokenUnavailableError,
} from '../_shared/token.ts'
import { corsHeaders, errorResponse, jsonResponse, readJson } from '../_shared/http.ts'

interface CreatePaymentBody {
  orderId?: unknown
  slug?: unknown
  kind?: unknown
  amount?: unknown
  /** The storefront's origin, so bKash's callback lands on this site's own
   * `/payment/return`. The merchant portal whitelists it; a value that is not
   * whitelisted is refused by bKash, so a spoofed origin fails there and not
   * here. */
  origin?: unknown
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders() })
  }
  if (request.method !== 'POST') {
    return errorResponse('method_not_allowed', 'use POST', 405)
  }

  // The caller's own JWT, forwarded unchanged. This client can read nothing of theirs: the
  // RPCs below check `user_id`, and the credential read happens on the service-role client.
  const authorization = request.headers.get('authorization')
  if (!authorization) {
    return errorResponse('authentication_required', 'sign in first', 401)
  }

  const userClient = userClientFor(authorization.replace(/^Bearer\s+/i, ''))

  const admin = serviceClient()

  // Hoisted so the catch can echo a masked hint about which credentials were in
  // play when bKash declined. Two characters and a length are not a secret.
  let held: { username?: unknown; password?: unknown } | null = null

  try {
    const body = await readJson<CreatePaymentBody>(request)

    // Two ways in. The pay button on the page sends what the customer chose
    // (slug, kind, amount) and `pay_online_start` creates the order and opens
    // the payment session in one SQL call. The order page's retry button sends
    // an existing orderId, which skips order creation entirely - an order that
    // already exists has nothing left to decide.
    const oneStep = typeof body?.orderId !== 'string' || body.orderId === ''

    let start: Record<string, unknown>
    let orderId: string

    if (oneStep) {
      if (typeof body?.slug !== 'string' || body.slug === '') {
        return errorResponse('invalid_request', 'slug is required', 400)
      }
      if (typeof body?.kind !== 'string' || body.kind === '') {
        return errorResponse('invalid_request', 'kind is required', 400)
      }
      const amount = Number(body?.amount)
      if (!Number.isFinite(amount) || amount <= 0) {
        return errorResponse('invalid_request', 'amount must be a positive number', 400)
      }

      const { data: started, error: startError } = await userClient.rpc('pay_online_start', {
        p_slug: body.slug,
        p_kind: body.kind,
        p_amount: amount,
      })
      if (startError) {
        // `kind_mismatch` is a stable prefix by contract (see the routing
        // migration): the customer already has an open order and the page
        // navigates them to it. Everything else is reported as-is.
        return errorResponse('cannot_start_payment', startError.message, 400)
      }
      if (!started || started.ok !== true) {
        // A refusal envelope (below_minimum, locked): an answer, not an error,
        // so it goes back with the payload the page already knows how to show.
        return jsonResponse({ ok: false, refusal: started })
      }
      start = started as Record<string, unknown>
      orderId = String(start.order_id)
    } else {
      const { data: existing, error: startError } = await userClient.rpc('bkash_payment_start', {
        p_order_id: body.orderId,
      })
      if (startError) {
        // `bkash_payment_start` raises P0002 for an order that is not the caller's, which is
        // the same answer as an order that does not exist. Deliberately not distinguishing
        // them here: telling a stranger that an id exists is itself a leak.
        return errorResponse('cannot_start_payment', startError.message, 400)
      }
      start = existing as Record<string, unknown>
      orderId = body.orderId as string
    }

    // bKash sends the customer's browser here when the payment finishes. It has to
    // be exactly the URL whitelisted in the merchant portal - same scheme, host and
    // path - so it is built from the storefront's own origin and never guessed.
    const origin =
      typeof body?.origin === 'string' && body.origin.startsWith('https://')
        ? body.origin.replace(/\/$/, '')
        : ''
    if (origin === '') {
      return errorResponse('invalid_request', 'origin must be an https URL', 400)
    }
    const callbackUrl = `${origin}/payment/return`

    const environment = asEnvironment(start.environment)

    // The only secret read in this function, and it is read with the service-role client
    // because both halves of the credential path are revoked from anon and authenticated.
    const { bundleId, credentials } = await readCredentials(admin, start.gateway_id as string)
    held = { username: credentials.username, password: credentials.password }
    const idToken = await bkashIdToken(admin, bundleId, environment, credentials)

    // Debug aid for bare-400 declines: the callback origin is what bKash refuses
    // when it is not whitelisted. No secrets are in these fields.
    const mask = (v: unknown) =>
      typeof v === 'string' && v.length > 0 ? `${v.slice(0, 2)}…(len ${v.length})` : 'MISSING'
    console.error('bkash create request', {
      environment,
      amount: Number(start.amount),
      currency: String(start.currency),
      callbackUrl,
      username: mask(credentials.username),
      password: mask(credentials.password),
      app_key: mask(credentials.app_key),
      app_secret: mask(credentials.app_secret),
    })

    const created = await createPayment(environment, idToken, credentials, {
      amount: Number(start.amount),
      currency: String(start.currency),
      // `reference_code`, which is unique and URL safe. See the note in the migration:
      // this is what makes a bKash statement reconcilable to an order without the IPN.
      invoice: String(start.invoice),
      payerReference: String(start.payer_reference),
      callbackUrl,
    })

    // Recorded before the customer is sent anywhere. A payment bKash accepted but that we
    // forgot is unrecoverable: `bkash_payment_claim` requires a session row, so without
    // this the customer would be bounced back with "no payment session" for a payment that
    // really was taken.
    // `bkash_record_session` is service_role only - deliberately, since it writes a
    // session row for an order without re-checking that the caller owns it. The ownership
    // check already happened in `bkash_payment_start`, above, against the same order id.
    const { error: recordError } = await admin.rpc('bkash_record_session', {
      p_order_id: orderId,
      p_payment_id: created.paymentId,
      p_amount: Number(start.amount),
    })
    if (recordError) {
      // The payment exists at bKash and this is a real failure. The order stays unpaid and
      // `bkash_execute` will report no session, so the safe outcome is to keep the customer
      // on the order page with an error rather than redirecting them to a payment we
      // cannot finish.
      return errorResponse('could_not_record_payment', recordError.message, 500)
    }

    return jsonResponse({
      ok: true,
      orderId,
      paymentId: created.paymentId,
      redirectUrl: created.redirectUrl,
      // Surfaced so the frontend can say "this is a test payment, no money will move"
      // instead of implying a charge happened.
      sandbox: start.sandbox === true,
    })
  } catch (cause) {
    if (cause instanceof GatewayNotConfiguredError) {
      return errorResponse('gateway_not_configured', cause.message, 409)
    }
    if (cause instanceof TokenUnavailableError) {
      return errorResponse('token_unavailable', cause.message, 503)
    }
    if (cause instanceof BkashError) {
      const mask = (v: unknown) =>
        typeof v === 'string' && v.length > 0 ? `${v.slice(0, 2)}…(len ${v.length})` : 'MISSING'
      const hint = held
        ? ` [sending username=${mask(held.username)} password=${mask(held.password)}]`
        : ''
      return errorResponse('bkash_declined', cause.message + hint, 502)
    }
    if (cause instanceof BkashTransportError) {
      return errorResponse('bkash_unreachable', cause.message, 502)
    }
    if (cause instanceof SyntaxError) {
      return errorResponse('invalid_request', 'body must be json', 400)
    }
    console.error('bkash-create-payment failed', cause instanceof Error ? cause.name : 'unknown')
    return errorResponse('unexpected_error', 'could not start the payment', 500)
  }
})

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

  try {
    const body = await readJson<CreatePaymentBody>(request)
    if (typeof body?.orderId !== 'string' || body.orderId === '') {
      return errorResponse('invalid_request', 'orderId is required', 400)
    }

    const { data: start, error: startError } = await userClient.rpc('bkash_payment_start', {
      p_order_id: body.orderId,
    })
    if (startError) {
      // `bkash_payment_start` raises P0002 for an order that is not the caller's, which is
      // the same answer as an order that does not exist. Deliberately not distinguishing
      // them here: telling a stranger that an id exists is itself a leak.
      return errorResponse('cannot_start_payment', startError.message, 400)
    }

    const environment = asEnvironment(start.environment)

    // The only secret read in this function, and it is read with the service-role client
    // because both halves of the credential path are revoked from anon and authenticated.
    const { bundleId, credentials } = await readCredentials(admin, start.gateway_id as string)
    const idToken = await bkashIdToken(admin, bundleId, environment, credentials)

    const created = await createPayment(environment, idToken, credentials, {
      amount: Number(start.amount),
      currency: String(start.currency),
      // `reference_code`, which is unique and URL safe. See the note in the migration:
      // this is what makes a bKash statement reconcilable to an order without the IPN.
      invoice: String(start.invoice),
      payerReference: String(start.payer_reference),
    })

    // Recorded before the customer is sent anywhere. A payment bKash accepted but that we
    // forgot is unrecoverable: `bkash_payment_claim` requires a session row, so without
    // this the customer would be bounced back with "no payment session" for a payment that
    // really was taken.
    // `bkash_record_session` is service_role only - deliberately, since it writes a
    // session row for an order without re-checking that the caller owns it. The ownership
    // check already happened in `bkash_payment_start`, above, against the same order id.
    const { error: recordError } = await admin.rpc('bkash_record_session', {
      p_order_id: body.orderId,
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
      orderId: start.order_id,
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
      return errorResponse('bkash_declined', cause.message, 502)
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

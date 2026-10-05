/**
 * POST /functions/v1/bkash-execute
 *
 * Finishes a payment. The customer comes back from bKash holding a `paymentID` in the query
 * string, and this function turns that into an approved order - or does not.
 *
 * The order of operations is the whole design:
 *
 *   1. `bkash_payment_claim` establishes, in SQL, that this payment id belongs to this
 *      customer's order. Until it returns, nothing is executed and no secret is touched.
 *   2. If it reports `already_settled`, we return without calling bKash at all. Execute is
 *      allowed exactly once per payment id, so a repeated call is not a retry, it is a
 *      permanent failure of that payment.
 *   3. Execute happens.
 *   4. `bkash_settle_order` approves, and refuses if anything disagrees.
 *
 * Step 4 is where a sandbox payment dies: the gateway's environment is `sandbox`, and the
 * RPC raises before it marks the session completed or approves the order. The customer is
 * told plainly that this was a test payment, which is the honest description of what
 * happened.
 */

import { createClient } from '@supabase/supabase-js'
import { asEnvironment, BkashError, BkashTransportError, executePayment } from '../_shared/bkash.ts'
import {
  bkashIdToken,
  GatewayNotConfiguredError,
  readCredentials,
  TokenUnavailableError,
} from '../_shared/token.ts'
import { corsHeaders, errorResponse, jsonResponse, readJson } from '../_shared/http.ts'

interface ExecuteBody {
  orderId?: unknown
  paymentId?: unknown
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders() })
  }
  if (request.method !== 'POST') {
    return errorResponse('method_not_allowed', 'use POST', 405)
  }

  const authorization = request.headers.get('authorization')
  if (!authorization) {
    return errorResponse('authentication_required', 'sign in first', 401)
  }

  const userClient = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    authorization.replace(/^Bearer\s+/i, ''),
    { auth: { persistSession: false } },
  )

  const admin = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  )

  try {
    const body = await readJson<ExecuteBody>(request)
    if (typeof body?.orderId !== 'string' || body.orderId === '') {
      return errorResponse('invalid_request', 'orderId is required', 400)
    }
    if (typeof body.paymentId !== 'string' || body.paymentId === '') {
      return errorResponse('invalid_request', 'paymentId is required', 400)
    }

    const { data: claim, error: claimError } = await userClient.rpc('bkash_payment_claim', {
      p_order_id: body.orderId,
      p_payment_id: body.paymentId,
    })
    if (claimError) {
      // Either the payment is not this customer's, or there is no session for it. Both are
      // reported the same way.
      return errorResponse('cannot_execute_payment', claimError.message, 400)
    }

    // The customer reloaded the return page, or the callback arrived twice. The money is in
    // and the grant exists. bKash is not contacted, because contacting it would consume the
    // one execute this payment id is allowed.
    if (claim.already_settled === true) {
      return jsonResponse({
        ok: true,
        alreadySettled: true,
        orderId: claim.order_id,
        status: claim.status,
        sandbox: false,
      })
    }

    const environment = asEnvironment(claim.environment)
    const { bundleId, credentials } = await readCredentials(admin, claim.gateway_id as string)
    const idToken = await bkashIdToken(admin, bundleId, environment, credentials)

    let executed
    try {
      executed = await executePayment(environment, idToken, credentials, body.paymentId)
    } catch (cause) {
      // Execute failed. bKash refunds a failed payment, and the customer is sent back to
      // the order to try again - so the session is failed rather than left `initiated`.
      //
      // Not every failure is a refusal, though. A network timeout after bKash accepted the
      // execute is indistinguishable from bKash never hearing us, and marking that failed
      // would send the customer to retry a payment that already succeeded. Query Payment
      // would resolve it, but this function does not implement it; the safer half of the
      // ambiguity is a session the customer can re-enter, which `bkash_payment_claim` will
      // then refuse to execute a second time and send them to support with the order
      // reference. That is recoverable. A failed session is not.
      if (cause instanceof BkashError && /^3\d{3}$/.test(cause.statusCode)) {
        await admin.rpc('bkash_fail_session', {
          p_order_id: body.orderId,
          p_payment_id: body.paymentId,
          p_reason: cause.message,
        })
      }
      throw cause
    }

    const { data: settlement, error: settlementError } = await admin.rpc('bkash_settle_order', {
      p_order_id: body.orderId,
      p_payment_id: body.paymentId,
      p_trx_id: executed.trxId,
      p_payer_account: executed.payerAccount,
      p_amount: executed.amount,
    })

    if (settlementError) {
      // The most important failure in this file. bKash took the money and the database did
      // not approve, which means an operator has to reconcile this by hand. The message is
      // returned verbatim because it is written for that operator: it names the sandbox
      // refusal, the amount mismatch, or the expired order, and the frontend shows it to the
      // customer rather than hiding it behind "something went wrong".
      console.error('bkash-execute could not settle', settlementError.message)
      return errorResponse('payment_not_settled', settlementError.message, 409)
    }

    return jsonResponse({
      ok: true,
      alreadySettled: settlement.already === true,
      orderId: body.orderId,
      status: settlement.status,
      trxId: settlement.trx_id,
      // True means bKash confirmed a payment and we deliberately refused to grant access
      // for it. The frontend shows it as a test payment, not a receipt.
      sandbox: environment === 'sandbox',
    })
  } catch (cause) {
    if (cause instanceof GatewayNotConfiguredError) {
      return errorResponse('gateway_not_configured', cause.message, 409)
    }
    if (cause instanceof TokenUnavailableError) {
      return errorResponse('token_unavailable', cause.message, 503)
    }
    if (cause instanceof BkashError) {
      return errorResponse('payment_failed', cause.message, 402)
    }
    if (cause instanceof BkashTransportError) {
      return errorResponse('bkash_unreachable', cause.message, 502)
    }
    if (cause instanceof SyntaxError) {
      return errorResponse('invalid_request', 'body must be json', 400)
    }
    console.error('bkash-execute failed', cause instanceof Error ? cause.name : 'unknown')
    return errorResponse('unexpected_error', 'could not finish the payment', 500)
  }
})

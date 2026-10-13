import { corsHeaders, errorResponse, jsonResponse } from '../_shared/http.ts'
import { userClientFor } from '../_shared/supabase.ts'

/**
 * POST /functions/v1/telegram-request-invite
 *
 * Proxies to the bot Worker's /api/create-invite after the operator approves
 * an order. The bot does all the work — this function exists only so the
 * shared secret stays server-side: the admin frontend never sees it.
 *
 * Authorization: the caller must be staff. Verified the same way
 * ai-fill-form does it — by calling `admin_pages` through the caller's own
 * JWT and letting the database refuse non-staff callers.
 *
 * Secrets (supabase secrets set):
 *   TELEGRAM_BOT_URL       — the bot Worker's base URL
 *   TELEGRAM_SHARED_SECRET — the shared secret the bot expects
 */

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders() })
  }

  const authorization = request.headers.get('authorization')
  if (!authorization) {
    return errorResponse('authentication_required', 'sign in first', 401)
  }

  try {
    const body = (await request.json().catch(() => null)) as { orderId?: string } | null
    const orderId = body?.orderId
    if (!orderId || !/^[0-9a-f-]{36}$/i.test(orderId)) {
      return errorResponse('invalid_request', 'orderId is required', 400)
    }

    // Staff check through the caller's own JWT — same pattern as ai-fill-form.
    const userClient = userClientFor(authorization.replace(/^Bearer\s+/i, ''))
    const { error: authError } = await userClient.rpc('admin_pages')
    if (authError) {
      return errorResponse('forbidden', authError.message, 403)
    }

    const botUrl = Deno.env.get('TELEGRAM_BOT_URL')
    const sharedSecret = Deno.env.get('TELEGRAM_SHARED_SECRET')
    if (!botUrl || !sharedSecret) {
      return errorResponse(
        'telegram_not_configured',
        'Telegram delivery is not configured on this deployment',
        503,
      )
    }

    const botRes = await fetch(`${botUrl}/api/create-invite`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${sharedSecret}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ orderId }),
      signal: AbortSignal.timeout(10_000),
    })

    const botData = (await botRes.json().catch(() => null)) as {
      ok?: boolean
      inviteUrl?: string
      error?: string
    } | null

    if (!botData?.ok) {
      return errorResponse(
        'invite_failed',
        botData?.error ?? 'the bot could not create an invite',
        botRes.status === 404 ? 404 : 502,
      )
    }

    return jsonResponse({ ok: true, inviteUrl: botData.inviteUrl })
  } catch (cause) {
    const name = cause instanceof Error ? cause.name : 'unknown'
    console.error('telegram-request-invite failed', name)
    return errorResponse('unexpected_error', 'could not reach the Telegram bot', 502)
  }
})

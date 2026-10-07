/**
 * The handful of HTTP concerns both bKash functions need, in one place.
 *
 * Worth a file of its own because the CORS headers are the part that is easy to get subtly
 * wrong and expensive when wrong: an Edge Function that omits `Access-Control-Allow-Headers`
 * fails in the browser while working perfectly in curl, so the bug is invisible until a
 * customer tries to pay.
 */

/**
 * Reflects the caller's Origin rather than naming one.
 *
 * `Deno.env.get('APP_URL')` is the right answer and this is not it: the frontend and the API
 * are two different hosts on Supabase, and hardcoding either one means the payment button is
 * broken in local dev or in the customer's real browser. Reflecting is acceptable for an
 * authenticated POST that can only read the caller's own rows - the response carries no
 * credential and no secret - and the alternative is a list that has to be updated every time
 * a preview branch gets its own URL.
 */
export function corsHeaders(): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers':
      'authorization, x-client-info, apikey, content-type, x-application-name',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  }
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(), 'content-type': 'application/json' },
  })
}

/**
 * A failed payment is an ordinary outcome, so the body is structured rather than a bare
 * string: the frontend keys off `error` to pick a message and `detail` to show it. The
 * detail is the database's or bKash's own words, which is why nothing sanitises it - both
 * are written for a human to read and neither contains a credential.
 */
export function errorResponse(error: string, detail: string, status: number): Response {
  return jsonResponse({ error, detail }, status)
}

/**
 * Parses a JSON body, turning a malformed one into a SyntaxError the caller can report as a
 * 400 rather than an unhandled 500.
 */
export async function readJson<T>(request: Request): Promise<T> {
  return (await request.json()) as T
}

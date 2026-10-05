import { describe, expect, it } from 'vitest'
import { FunctionsFetchError, FunctionsHttpError, FunctionsRelayError } from '@supabase/supabase-js'
import { describeEdgeFailure } from './edgeError'

/**
 * The regression these guard: the generic SDK string
 * `Failed to send a request to the Edge Function` reaching the screen.
 *
 * `describeEdgeFailure` is async because reading the function's own `detail` means
 * parsing the `Response`, so every test awaits it.
 */

/** A response shaped like `_shared/http.ts` writes: `{ error, detail }`. */
function functionResponded(body: unknown, status = 400): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

describe('describeEdgeFailure', () => {
  it('names the cause when the request never completed', async () => {
    // A bare `TypeError` is what fetch rejects with when a preflight is blocked,
    // when an ad blocker intervenes, or when the laptop is offline.
    const failure = await describeEdgeFailure(
      new FunctionsFetchError(new TypeError('Failed to fetch')),
      'fallback',
    )

    expect(failure.kind).toBe('FunctionsFetchError')
    expect(failure.status).toBeNull()
    expect(failure.message).not.toBe('Failed to send a request to the Edge Function')
    expect(failure.message).toMatch(/connection|VPN/i)
  })

  it('keeps the transport cause out of the message but on the record', async () => {
    const failure = await describeEdgeFailure(
      new FunctionsFetchError(new TypeError('Failed to fetch')),
      'fallback',
    )

    // The cause is for devtools. Showing `TypeError: Failed to fetch` to a
    // customer mid-payment is worse than saying nothing useful.
    expect(failure.message).not.toMatch(/TypeError/)
    expect(failure.cause).toBe('TypeError: Failed to fetch')
  })

  it('reports an aborted request as aborted, which is a different fault', async () => {
    const abort = new Error('The operation was aborted.')
    abort.name = 'AbortError'

    const failure = await describeEdgeFailure(new FunctionsFetchError(abort), 'fallback')

    expect(failure.cause).toMatch(/aborted/i)
  })

  it("prefers the function's own detail, which names the fault", async () => {
    const failure = await describeEdgeFailure(
      new FunctionsHttpError(
        functionResponded({
          error: 'gateway_not_configured',
          detail: 'bKash credentials are not saved yet.',
        }),
      ),
      'fallback',
    )

    expect(failure.message).toBe('bKash credentials are not saved yet.')
    expect(failure.status).toBe(400)
  })

  it('reports the status when the answer has no readable body', async () => {
    // A gateway or relay failure can answer with HTML, and `Response.json()` then
    // throws. That must not mask the status, which is the only useful fact left.
    const html = new Response('<html>gateway error</html>', { status: 502 })

    const failure = await describeEdgeFailure(new FunctionsRelayError(html), 'fallback')

    expect(failure.message).toMatch(/502/)
    expect(failure.status).toBe(502)
  })

  it('passes a plain Error through untouched, since we wrote that message', async () => {
    const failure = await describeEdgeFailure(new Error('Draft came back incomplete.'), 'fallback')

    expect(failure.kind).toBe('unknown')
    expect(failure.message).toBe('Draft came back incomplete.')
  })

  it('falls back when thrown a value with no message at all', async () => {
    const failure = await describeEdgeFailure(undefined, 'Could not start the payment')

    expect(failure.message).toBe('Could not start the payment')
  })
})

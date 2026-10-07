import { i18n } from '@/i18n'

/**
 * Naming the failure from a `supabase.functions.invoke` error.
 *
 * The reason this exists: the SDK's `FunctionsFetchError` message is the literal
 * string `Failed to send a request to the Edge Function`, and it wraps *every*
 * reason the request never completed - a dropped connection, a DNS failure, a
 * blocked preflight, an ad blocker, a VPN, an offline laptop. None of those are
 * distinguishable from the message, which is why that string on its own is a
 * dead end for the operator holding it.
 *
 * The discriminating detail is in `context`, and it is thrown away by the
 * obvious `err.message`. What is in there depends on the class:
 *
 * - `FunctionsHttpError` / `FunctionsRelayError`: `context` is the `Response`,
 *   and the body carries `{ error, detail }` written by `_shared/http.ts`.
 * - `FunctionsFetchError`: `context` is the underlying rejection - a `TypeError`
 *   naming the cause, or an `AbortError` if a signal fired.
 *
 * So the function names the class, prefers the function's own `detail` when there
 * is one, and otherwise reports the transport failure honestly instead of
 * repeating the SDK's generic string back at someone trying to fix it.
 */

/** The three classes `invoke` rejects with. Checked by name so this needs no import. */
type EdgeErrorName = 'FunctionsHttpError' | 'FunctionsRelayError' | 'FunctionsFetchError'

function isEdgeErrorName(value: unknown): value is EdgeErrorName {
  return (
    value === 'FunctionsHttpError' ||
    value === 'FunctionsRelayError' ||
    value === 'FunctionsFetchError'
  )
}

/** Pulls `{ error, detail }` out of a `Response` context without assuming it parses. */
async function detailFromResponse(context: unknown): Promise<string> {
  if (!(context instanceof Response)) return ''

  let body: unknown
  try {
    body = await context.clone().json()
  } catch {
    // A relay error or a gateway 5xx can carry HTML or nothing at all. Unparseable
    // is not a reason to hide the status, so it is reported below instead.
    return ''
  }

  const detail = (body as { detail?: unknown } | null)?.detail
  return typeof detail === 'string' ? detail : ''
}

export type EdgeFailure = {
  /** Which of the SDK's three failure classes this was. */
  kind: EdgeErrorName | 'unknown'
  /**
   * The message to show a person.
   *
   * Function-authored text when there is any, because those messages name the
   * field or provider at fault and were written for a human. Otherwise a message
   * that says what actually went wrong at the transport layer.
   */
  message: string
  /**
   * The underlying cause, for a console rather than the screen.
   *
   * Kept separate from `message` because it is raw: `Failed to fetch`,
   * `The operation was aborted`, a `TypeError` name. Useful in devtools, wrong
   * in front of a customer.
   */
  cause: string
  /**
   * The HTTP status, when the request completed and was rejected on its answer.
   *
   * Absent for a `FunctionsFetchError`: no response ever arrived, which is the
   * whole point of that class.
   */
  status: number | null
}

/**
 * Describes why an Edge Function call failed, in a form worth acting on.
 *
 * @param err    Whatever `invoke` rejected with, or any thrown value.
 * @param fallback Message to use when `err` is not a recognisable Edge error and
 *   carries no usable text of its own. Passed in rather than imported so the
 *   caller keeps its own locale.
 */
export async function describeEdgeFailure(err: unknown, fallback: string): Promise<EdgeFailure> {
  const name = (err as { name?: unknown } | null)?.name
  const context = (err as { context?: unknown } | null)?.context
  const message = err instanceof Error ? err.message : ''

  // A plain Error thrown by our own validation, e.g. an incomplete draft. Those
  // are already written for a person and carry no Edge context worth unwrapping.
  if (!isEdgeErrorName(name)) {
    return { kind: 'unknown', message: message || fallback, cause: message, status: null }
  }

  // The function answered. Its own `detail` wins, because it names the fault.
  const detail = await detailFromResponse(context)
  if (detail !== '') {
    return { kind: name, message: detail, cause: message, status: (context as Response).status }
  }

  if (name === 'FunctionsFetchError') {
    // No response arrived. `message` is the SDK's generic string, so it is the
    // wrong thing to show; the cause underneath is the only real information.
    const cause = describeTransportCause(context)

    return {
      kind: name,
      message: i18n.global.t('customer.errors.transport'),
      cause,
      status: null,
    }
  }

  // An Edge error with no parsable body: the gateway or the relay answered
  // instead of the function. The status is the only fact worth offering.
  const status = context instanceof Response ? context.status : null
  return {
    kind: name,
    message:
      status !== null
        ? `The payment service responded with an error (HTTP ${status}).`
        : 'The payment service responded with an error.',
    cause: message,
    status,
  }
}

/** Names the transport-level cause, which is what actually distinguishes these. */
function describeTransportCause(context: unknown): string {
  if (context instanceof Error) {
    if (context.name === 'AbortError') return 'The request was aborted before it finished.'

    // A bare `Failed to fetch` is the browser refusing to tell us more, which is
    // what a blocked preflight or a blocked third-party request looks like.
    return `${context.name}: ${context.message}`
  }

  if (typeof context === 'string' && context !== '') return context
  return 'No further detail available.'
}

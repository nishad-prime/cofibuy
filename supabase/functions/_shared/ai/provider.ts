/**
 * One HTTP call to an OpenAI-compatible chat completions endpoint, shaped so that the only
 * acceptable answer is a tool call.
 *
 * ## Why a forced tool call and not `response_format`
 *
 * The obvious way to ask a model for JSON is `response_format: { type: 'json_schema' }`.
 * It is the wrong tool here for three reasons:
 *
 *   - Support is uneven. It is not in the base spec, so it is absent on older deployments
 *     and on the smaller models a shop is likely to point at, and the failure is a 400
 *     that reads like a bad key.
 *   - It constrains the *shape* of a response, not the fact that there is one. A model that
 *     has decided it cannot do the task still has to emit something shaped like the schema,
 *     and the result is a well-formed empty object rather than an honest refusal.
 *   - The token cap and the schema fight each other under truncation. A response cut off
 *     mid-array is invalid in a way nothing upstream can distinguish from a model that
 *     chose to stop.
 *
 * A forced tool call inverts the first point (every compatible endpoint has had tools
 * since 2023) and fixes the second: the model signals refusal by not calling the tool, which
 * is detectable rather than plausible. It also gives a natural place to hang `max_tokens`,
 * because tool arguments are billed and truncated the same way prose is.
 */

import { toJsonSchema, type JsonSchema } from './schema.ts'

/** Where the provider lives and who we are. No defaults: a wrong host is worse than none. */
export interface AiProviderConfig {
  /** Full chat completions path, e.g. `https://api.openai.com/v1/chat/completions`. */
  readonly url: string
  readonly apiKey: string
  readonly model: string
}

/** The one tool the model is allowed to call, named so the call site reads as intent. */
export interface AiToolSpec {
  readonly name: string
  readonly description: string
  readonly parameters: JsonSchema
}

export interface AiCallOptions {
  readonly system: string
  readonly user: string
  readonly tool: AiToolSpec
  /** Hard output ceiling, forwarded as `max_tokens`. Never defaulted upward. */
  readonly maxOutputTokens: number
  /** Aborts this call. Per attempt, not per generation - see generate.ts. */
  readonly timeoutMs: number
  readonly temperature?: number
}

export type AiErrorCode =
  | 'not_configured'
  | 'timeout'
  | 'transport'
  | 'unauthorized'
  | 'rate_limited'
  | 'rejected'
  | 'refused'
  | 'truncated'
  | 'invalid_arguments'
  /** Arrived well-formed but wrong after the one retry. Raised by generate.ts. */
  | 'schema'
  /** The request itself was malformed - a bad field list, not a bad model. */
  | 'invalid_fields'

/**
 * Every way an AI call can fail, as one type.
 *
 * A single class with a `code` rather than a hierarchy, because every caller does the same
 * thing with it: decide whether to show the person a message they can act on or retry
 * quietly, then log the code. `providerMessage` is kept separate and capped because it is
 * the one part that goes near a log line.
 */
export class AiError extends Error {
  readonly code: AiErrorCode
  readonly providerMessage: string | null
  readonly status: number | null

  constructor(
    code: AiErrorCode,
    message: string,
    providerMessage: string | null = null,
    status: number | null = null,
  ) {
    super(message)
    this.name = 'AiError'
    this.code = code
    this.providerMessage = providerMessage
    this.status = status
  }
}

/** The arguments the model put in the forced tool call, parsed but not yet validated. */
export interface AiToolCall {
  readonly arguments: unknown
}

/**
 * Makes the call and returns the tool arguments, or throws.
 *
 * Takes `fetch` as a parameter so tests can drive the whole path - timeouts included -
 * without a network or a clock. Everything else about the function is deterministic.
 */
export async function callTool(
  fetchImpl: typeof fetch,
  config: AiProviderConfig,
  options: AiCallOptions,
): Promise<AiToolCall> {
  if (!config.apiKey || !config.model || !config.url) {
    throw new AiError('not_configured', 'no AI provider is configured')
  }

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), options.timeoutMs)

  let response: Response
  try {
    response = await fetchImpl(config.url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${config.apiKey}`,
        'content-type': 'application/json',
      },
      signal: controller.signal,
      body: JSON.stringify({
        model: config.model,
        // Zero for this workload. The input is a fixed list of keys and a fixed shape; a
        // higher temperature only buys variation nobody asked for, and the one retry after
        // a schema failure has to be comparable to the attempt before it.
        temperature: options.temperature ?? 0,
        max_tokens: options.maxOutputTokens,
        tools: [
          {
            type: 'function',
            function: {
              name: options.tool.name,
              description: options.tool.description,
              parameters: toJsonSchema(options.tool.parameters),
            },
          },
        ],
        // The tool is not a choice. `tool_choice` names it outright, and
        // `parallel_tool_calls: false` forbids the alternative failure mode where a model
        // emits the same list twice under different names, which would arrive as a
        // well-formed array of twice the requested length.
        tool_choice: { type: 'function', function: { name: options.tool.name } },
        parallel_tool_calls: false,
        messages: [
          { role: 'system', content: options.system },
          { role: 'user', content: options.user },
        ],
      }),
    })
  } catch (error) {
    // An abort and a connection failure arrive as the same thrown Error, so they are told
    // apart by the flag setTimeout flipped rather than by the message, which differs by
    // runtime and version.
    if (controller.signal.aborted) {
      throw new AiError('timeout', `the AI provider did not answer within ${options.timeoutMs}ms`)
    }
    throw new AiError('transport', 'could not reach the AI provider', errorMessage(error))
  } finally {
    clearTimeout(timer)
  }

  const providerMessage = await readProviderMessage(response)

  if (!response.ok) {
    throw new AiError(
      statusToCode(response.status),
      `the AI provider rejected the request (${response.status})`,
      providerMessage,
      response.status,
    )
  }

  const body = await readJson(response)
  const choice = body?.choices?.[0]

  // Checked before `tool_calls`, because a truncated call is a length problem wearing a
  // tool call's clothes: the arguments are present but cut off, usually mid-array, and the
  // validation error that follows ("items[3] is missing") sends the retry off to fix the
  // wrong thing.
  if (choice?.finish_reason === 'length') {
    throw new AiError(
      'truncated',
      `the answer hit the ${options.maxOutputTokens}-token ceiling`,
      providerMessage,
    )
  }

  const toolCall = choice?.message?.tool_calls?.[0]

  if (!toolCall?.function) {
    // The refusal case `response_format` cannot express. Worth its own code: it usually
    // means the prompt asked for something the provider will not do, and no amount of
    // retrying the same prompt will change that.
    throw new AiError(
      'refused',
      'the model declined to answer in the required shape',
      providerMessage,
    )
  }

  // An absent `arguments` is checked rather than handed to JSON.parse. It arrives as
  // `undefined` on a call some providers emit when the model produced a tool call with no
  // payload, and parsing that reports the confusing "undefined is not valid JSON" instead of
  // the truth.
  const raw = toolCall.function.arguments
  if (typeof raw !== 'string') {
    throw new AiError('invalid_arguments', 'the tool call carried no arguments', providerMessage)
  }

  let args: unknown
  try {
    args = JSON.parse(raw)
  } catch (error) {
    throw new AiError(
      'invalid_arguments',
      'the model returned arguments that are not JSON',
      errorMessage(error),
    )
  }

  return { arguments: args }
}

function statusToCode(status: number): AiErrorCode {
  if (status === 401 || status === 403) return 'unauthorized'
  if (status === 429) return 'rate_limited'
  return 'rejected'
}

async function readProviderMessage(response: Response): Promise<string | null> {
  // Read on failures only. On success the body is consumed by `readJson`, and reading it
  // twice would leave the caller with nothing to parse.
  if (response.ok) return null
  const body = await readJson(response)
  const message = body?.error?.message ?? body?.message
  return typeof message === 'string' ? redact(message) : null
}

/** The shape of a chat completion body, narrowed to what this file reads. */
interface CompletionBody {
  readonly choices?: ReadonlyArray<{
    readonly finish_reason?: string | null
    readonly message?: {
      readonly tool_calls?: ReadonlyArray<{ readonly function?: { readonly arguments?: string } }>
    }
  }>
  readonly error?: { readonly message?: unknown }
  readonly message?: unknown
}

async function readJson(response: Response): Promise<CompletionBody | null> {
  let text: string
  try {
    text = await response.text()
  } catch {
    return null
  }
  try {
    // Validated only as far as it is read: the cast keeps the narrowing above honest at
    // every use site rather than spreading a bare `any` across the file.
    return JSON.parse(text) as CompletionBody
  } catch {
    // A gateway in front of the provider - a proxy, a captive network - answers with HTML.
    // Reporting that as invalid JSON sends the reader looking at their own code.
    return null
  }
}

/**
 * Keeps the provider's own words, loses anything shaped like a credential.
 *
 * Cheap insurance against a specific accident: several providers quote the offending
 * request back in the error, and an `Authorization: Bearer` header quoted into an error
 * message ends up in a log line, an error reporter, or a screenshot of the dashboard. The
 * pattern is deliberately broad - anything long and opaque after `sk`-like prefixes - since
 * a false positive costs nothing on a message nobody reads carefully.
 */
function redact(message: string): string {
  return message.replace(/\b(sk|rk|pk|key|api)[-_][A-Za-z0-9_-]{8,}/gi, '[redacted]').slice(0, 400)
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? redact(error.message) : String(error)
}

/**
 * The retry policy, which is the part of this core worth arguing about.
 *
 * A structured-generation helper is normally written as "call the model, parse, done" with
 * validation as an afterthought. That version is wrong for a shop's live copy, because the
 * alternative to a validated answer is not an error page - it is a half-finished sentence
 * saved over text that was already fine. So the shape here is: attempt, validate, and if the
 * answer is wrong *in a way a second answer could fix*, spend exactly one more call.
 */

import { callTool, AiError, type AiProviderConfig } from './provider.ts'
import { formatIssues, validate, type JsonSchema, type ValidationIssue } from './schema.ts'

export interface AiGenerateRequest {
  readonly system: string
  readonly user: string
  /** The shape both advertised to the model and enforced here. One declaration, two uses. */
  readonly schema: JsonSchema
  /**
   * Caps. Required rather than defaulted, because a default is a decision nobody made:
   * every value here is money and every value here is a worst case that only shows up
   * under load.
   */
  readonly maxOutputTokens: number
  readonly timeoutMs: number
  /** Names the tool in the forced call. Defaults to the conventional one. */
  readonly toolName?: string
  readonly toolDescription?: string
  readonly temperature?: number
  /**
   * Domain rules the schema cannot express, run on the parsed value and reported the same
   * way. "Every requested key came back" is a schema fact in some designs and a domain
   * rule in others; it belongs here either way, because the retry needs to hear about it.
   */
  readonly check?: (value: unknown) => ValidationIssue[]
}

export interface AiGenerateResult<T> {
  readonly value: T
  /** How many network calls it took. One, unless the first answer failed validation. */
  readonly attempts: number
}

/** The total number of calls this core will ever make for one request. */
const MAX_ATTEMPTS = 2

/**
 * Calls the model, validates what comes back, and retries once on a fixable failure.
 *
 * The retry is deliberately narrow. It fires when the answer arrived, parsed, and was
 * wrong - a missing key, a duplicated one, a number where a string belongs. It does not
 * fire on a timeout, a 429, or a truncated answer, because in each of those the second
 * call is being made under conditions that produced the first one: the same ceiling
 * truncates the same way, and a rate-limited provider is not improved by immediate
 * repetition. Retrying those buys a second charge for the same result.
 */
export async function generateStructured<T>(
  fetchImpl: typeof fetch,
  config: AiProviderConfig,
  request: AiGenerateRequest,
): Promise<AiGenerateResult<T>> {
  const tool = {
    name: request.toolName ?? 'submit',
    description: request.toolDescription ?? 'Submit the finished answer. Call this exactly once.',
    parameters: request.schema,
  }

  let user = request.user
  let lastIssues: ValidationIssue[] = []

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    const { arguments: raw } = await callTool(fetchImpl, config, {
      system: request.system,
      user,
      tool,
      maxOutputTokens: request.maxOutputTokens,
      timeoutMs: request.timeoutMs,
      temperature: request.temperature,
    })

    lastIssues = [...validate(request.schema, raw), ...(request.check ? request.check(raw) : [])]

    if (lastIssues.length === 0) {
      return { value: raw as T, attempts: attempt }
    }

    // The last attempt's problems are reported by the throw below rather than fed back.
    // A repair prompt built from an answer the model has not replaced tends to talk it out
    // of the correction.
    user = buildRepairPrompt(request.user, lastIssues, tool.name)
  }

  throw new AiError(
    'schema',
    `the model returned an answer that does not match the required shape after ${MAX_ATTEMPTS} attempts`,
    formatIssues(lastIssues),
  )
}

/**
 * Builds what the second attempt is told.
 *
 * Three things are deliberate. The original request is repeated in full, because a bare list
 * of complaints invites the model to repair the schema and drop the task - it will happily
 * return three valid items when five were asked for, and the fix is invisible unless the
 * count is still in front of it. The instruction to change nothing else is there because
 * the common repair is to rewrite working sentences to satisfy one bad one. And the list is
 * the validator's own output, unedited: paraphrasing it would mean maintaining a second
 * description of what is wrong.
 */
function buildRepairPrompt(
  original: string,
  issues: readonly ValidationIssue[],
  toolName: string,
): string {
  return [
    original,
    '',
    'That answer did not validate. Correct the problems below and call the tool again.',
    'Keep everything that was already correct, and return the same number of items.',
    '',
    'Problems:',
    formatIssues(issues),
    '',
    `Call ${toolName} once, with the corrected answer.`,
  ].join('\n')
}

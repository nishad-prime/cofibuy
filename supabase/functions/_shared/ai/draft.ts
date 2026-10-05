/**
 * Drafting one customer-facing string: the parts that can be decided without a network call.
 *
 * The HTTP entry point is deliberately thin. Everything worth arguing about - what the credential
 * bundle has to contain, how a stored `base_url` becomes a chat-completions endpoint, what the
 * model is told, and what counts as an answer - is in here so it can be tested without a provider,
 * a database, or an operator's afternoon.
 */

import { AiError, type AiProviderConfig } from './provider.ts'
import type { JsonSchema } from './schema.ts'

/** What the operator asked for, and what the shop currently says. */
export interface DraftRequest {
  /** The copy key, e.g. `home.heading`. Sent for the prompt and for the operator's own logs. */
  readonly key: string
  /** The editor's human label for that key. The model writes better prose when it knows the job. */
  readonly label: string
  /** Where the string appears, e.g. "the homepage heading". */
  readonly where: string
  /** Whether the storefront renders this key as markdown. */
  readonly isMarkdown: boolean
  /** The stored override, if any. Null means the shipped wording is in force. */
  readonly currentBn: string | null
  readonly currentEn: string | null
}

/** The finished draft, one string per language. */
export interface CopyDraft {
  readonly value_bn: string
  readonly value_en: string
}

/**
 * The advertised shape.
 *
 * Both languages or neither: a half-drafted pair is the state the copy editor exists to prevent,
 * since one language falls back to the shipped text while the other shows the model's words, and
 * the mismatch reads as a bug in the shop rather than as an unfinished edit.
 */
export const DRAFT_SCHEMA: JsonSchema = {
  type: 'object',
  additionalProperties: false,
  required: ['value_bn', 'value_en'],
  properties: {
    value_bn: {
      type: 'string',
      description: 'The Bangla wording, in natural Bangla rather than transliterated English.',
    },
    value_en: {
      type: 'string',
      description: 'The English wording.',
    },
  },
}

/** The tool the model is forced to call. Named for what it is rather than for the shape. */
export const DRAFT_TOOL = {
  name: 'submit_copy',
  description: 'Submit the finished wording for both languages. Call this exactly once.',
} as const

/**
 * Turns the stored credential into a provider config.
 *
 * `base_url` is the API root the operator copied out of a dashboard, and `AiProviderConfig.url`
 * wants the full chat-completions path. That join happens here, once, so no caller has to remember
 * which of the two it is holding - and so the failure mode is a named error at draft time rather
 * than a 404 from the provider that reads like a bad key.
 *
 * Every field is required and refused loudly. An absent key is a configuration mistake, and
 * quietly substituting an empty string would turn it into a `401` that says nothing about which of
 * the three fields is missing.
 */
export function providerConfigFrom(
  bundle: Record<string, unknown> | null | undefined,
): AiProviderConfig {
  const field = (name: string): string => {
    const value = bundle?.[name]
    if (typeof value !== 'string' || value.trim() === '') {
      throw new AiError('not_configured', `the AI credential has no ${name}`)
    }
    return value.trim()
  }

  // Read in the order `private.auto_providers` declares them, all three, before composing
  // anything. Building the object inline would read `base_url` first because that is where the
  // join happens, so a bundle missing every field would be reported against the URL rather than
  // the key - a deterministic message naming the wrong field is worse than none.
  const apiKey = field('api_key')
  const baseUrl = field('base_url')
  const model = field('model')

  return { url: chatCompletionsUrl(baseUrl), apiKey, model }
}

/**
 * Joins a stored base URL to `/chat/completions`.
 *
 * Idempotent on an already-complete endpoint, because an operator who pasted the full path into
 * the "Base URL" box should get working copy rather than `/chat/completions/chat/completions`.
 * Trailing slashes are trimmed for the same reason. No other normalisation: a base URL with a
 * path prefix (`https://host/openai/v1`) is common and must survive intact.
 */
export function chatCompletionsUrl(baseUrl: string): string {
  const trimmed = baseUrl.trim().replace(/\/+$/, '')
  return /\/chat\/completions$/.test(trimmed) ? trimmed : `${trimmed}/chat/completions`
}

/**
 * The system prompt.
 *
 * Short, and specific about the two things that go wrong most often: a model handed a shop's copy
 * with no constraints will happily return a paragraph for a heading, and it will "translate" into
 * Bangla by transliterating. Both are stated as rules rather than hoped for, because neither shows
 * up in a schema.
 */
export function draftSystemPrompt(request: DraftRequest): string {
  const lines = [
    'You write customer-facing copy for a small shop that sells digital field guides.',
    '',
    'Rules:',
    '- Return exactly one string per language. No labels, no quotation marks around the value, no explanation.',
    '- Bangla must be written in Bangla script, as natural Bangla a reader would accept. Never transliterate the English.',
    `- The two languages must say the same thing. They are translations of each other, not two different messages.`,
    request.isMarkdown
      ? '- This string is rendered as markdown on the storefront. Plain text and simple markdown are fine. No HTML, no headings above level 3, no images, no links.'
      : '- This string is rendered as plain text on the storefront. One line. No markdown, no HTML, no line breaks.',
    '- Keep every `{placeholder}` token exactly as given. Do not translate, reformat or drop one.',
    '- Write for a customer on a phone. Say what the thing is and why it is worth reading.',
    '- No pricing, no guarantees, no urgency, no exclamation marks, and nothing a shop cannot honour.',
    '',
    `The string is the ${request.where}. The operator calls it "${request.label}".`,
  ]

  return lines.join('\n')
}

/**
 * The user message: the operator's current wording when there is any, and an explicit note that
 * there is not when there is not.
 *
 * Passing the current text is what makes this a rewrite rather than a first draft, which is the
 * behaviour an operator expects from a button sitting next to their own sentence - and it is also
 * the only way the model can be asked to improve something specific instead of replacing it with
 * the most average sentence it knows.
 */
export function draftUserPrompt(request: DraftRequest): string {
  const current = [
    request.currentEn ? `Current English: ${request.currentEn}` : null,
    request.currentBn ? `Current Bangla: ${request.currentBn}` : null,
  ].filter((line): line is string => line !== null)

  return [
    `Rewrite the ${request.where} for this shop.`,
    current.length > 0
      ? `Improve the wording below. Keep anything that is already clear and correct.\n${current.join('\n')}`
      : 'There is no override saved for this string yet, so this is a first draft.',
    'Call submit_copy once with both languages.',
  ].join('\n\n')
}

/**
 * Reads the model's answer.
 *
 * `generateStructured` has already validated the shape, so this is the last mile: a value that is
 * an empty string or a stray bit of markdown scaffolding passes the schema and is still not
 * something to put in front of a customer. Raising `schema` here means the one retry has already
 * been spent by the time this runs, which is deliberate - a second attempt would only re-roll the
 * dice on the same prompt.
 */
export function readDraft(answer: unknown): CopyDraft {
  if (typeof answer !== 'object' || answer === null) {
    throw new AiError('schema', 'the model did not return a draft object')
  }

  const { value_bn: bn, value_en: en } = answer as Record<string, unknown>
  const text = (value: unknown, language: string): string => {
    if (typeof value !== 'string' || value.trim() === '') {
      throw new AiError('schema', `the model returned no ${language} wording`)
    }
    // Trimmed here rather than left to the editor: a draft arriving with a trailing newline is a
    // formatting artefact of the tool call, and saving it would make the field look edited.
    return value.trim()
  }

  return { value_bn: text(bn, 'Bangla'), value_en: text(en, 'English') }
}

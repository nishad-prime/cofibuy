/**
 * POST /functions/v1/ai-fill-form
 *
 * Fills a whole form from one paragraph.
 *
 * The caller describes the form it is on - a list of fields, each with a key, a
 * label and what the field is for - plus the operator's paragraph. The model
 * answers with a value for every field, in both languages where the field is
 * bilingual. Nothing is saved: the answer goes back to the form, where the
 * operator reads it, edits it, and saves through the ordinary RPC.
 *
 * The function is deliberately form-agnostic. Which fields exist, and what each
 * one means, is declared by whoever renders the form - the template registry for
 * page forms, the index editor for the index - because a hardcoded field list
 * here would drift from those forms exactly the way `linkBriefFields.ts` used
 * to sit between two implementations that had to agree with it by hand.
 *
 * Owner-only, through the same guard the other AI functions use: the caller's
 * JWT against an owner-guarded RPC, so the credential read only ever happens
 * for a request that has already proven who it is.
 */

import { type ApiClient, serviceClient, userClientFor } from '../_shared/supabase.ts'
import { generateStructured } from '../_shared/ai/generate.ts'
import { providerConfigFrom } from '../_shared/ai/draft.ts'
import { validate, type JsonSchema } from '../_shared/ai/schema.ts'
import { AiError, type AiProviderConfig } from '../_shared/ai/provider.ts'
import { corsHeaders, errorResponse, jsonResponse, readJson } from '../_shared/http.ts'

/** One field of the form being filled, as the caller describes it. */
interface FieldSpec {
  /** The key the answer is returned under. Must be a safe identifier. */
  key?: unknown
  /** What the operator calls the field. Goes into the prompt. */
  label?: unknown
  /** What the field is for. Goes into the prompt verbatim. */
  hint?: unknown
}

interface FillBody {
  paragraph?: unknown
  fields?: unknown
}

/**
 * The two numbers this function states rather than inherits.
 *
 * A form is a dozen or so short strings, so the ceiling matches the link brief.
 * Twenty seconds matches it too: a hung provider should be a message, not a
 * spinner in front of a half-filled form.
 */
const MAX_OUTPUT_TOKENS = 1000
const TIMEOUT_MS = 20_000
const TEMPERATURE = 0.7

const KEY_SHAPE = /^[a-z][a-z0-9_]*$/

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

/**
 * Normalizes the caller's field list.
 *
 * A field with a missing or malformed key is refused rather than skipped,
 * because a skipped field would come back un-filled and the operator would
 * read a partial form as the model forgetting. Every accepted field yields a
 * prompt line and an answer slot, so the two halves cannot disagree.
 */
function readFields(raw: unknown): { key: string; label: string; hint: string }[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new AiError('invalid_fields', 'fields must be a non-empty array')
  }

  return raw.map((entry) => {
    const key = text((entry as FieldSpec | null)?.key)
    if (!KEY_SHAPE.test(key)) {
      throw new AiError('invalid_fields', `field key must match ${KEY_SHAPE.source}`)
    }
    const label = text((entry as FieldSpec).label) || key
    const hint = text((entry as FieldSpec).hint)
    return { key, label, hint }
  })
}

function systemPrompt(fields: { key: string; label: string; hint: string }[]): string {
  const lines = fields.map((f) => `- ${f.key} (${f.label})${f.hint ? `: ${f.hint}` : ''}`)
  return [
    'You fill in forms for a shop operator from what they tell you in one paragraph.',
    '',
    'Rules:',
    '- Answer every field. A field the paragraph gives you nothing for gets your best,',
    '  shortest reading of what the operator probably means - never a question, never a',
    '  placeholder like "N/A".',
    '- Every field is a single string. No markdown headings, no bullet lists, no quotes',
    '  around the value.',
    '- Write for a phone screen: short sentences, no exclamation marks, no urgency, no',
    '  guarantees, no prices or deadlines. The paragraph is the only source: what it does',
    '  not say, do not invent.',
    '- Fields ending in _bn are Bangla. Write them in Bangla script, natural and',
    '  transliteration-free, saying the same thing as their _en twin.',
    '- Fields ending in _en are English.',
    '',
    'The fields:',
    ...lines,
  ].join('\n')
}

function userPrompt(
  paragraph: string,
  fields: { key: string; label: string; hint: string }[],
): string {
  const fieldNames = fields.map((f) => f.key).join(', ')
  return `Fill in these fields: ${fieldNames}\n\nWhat the operator says about it:\n\n${paragraph}`
}

/**
 * The answer's schema, built from the same field list the prompt used.
 *
 * Every field is a required string, so a model that skips one fails validation
 * here and gets one repair round instead of shipping a half-filled form.
 */
function answerSchema(fields: { key: string }[]): JsonSchema {
  const properties: Record<string, JsonSchema> = {}
  for (const f of fields) {
    properties[f.key] = { type: 'string' }
  }
  return { type: 'object', properties, required: fields.map((f) => f.key) }
}

/** Rejects anything that is not a clean string per field, after trimming. */
function readAnswer(fields: { key: string }[], answer: unknown): Record<string, string> {
  const issues = validate(answerSchema(fields), answer)
  if (issues.length > 0) {
    throw new AiError('schema', issues.map((i) => i.message).join('; '))
  }

  const out: Record<string, string> = {}
  for (const f of fields) {
    out[f.key] = ((answer as Record<string, unknown>)[f.key] as string).trim()
  }
  return out
}

async function readProviderConfig(admin: ApiClient): Promise<AiProviderConfig> {
  const { data, error } = await admin.rpc('ai_credential_bundle')
  if (error) {
    throw new AiError('not_configured', error.message)
  }

  const row = (data as { provider?: string; bundle?: string } | null) ?? null
  if (!row?.bundle) {
    throw new AiError('not_configured', 'no AI provider is configured for this shop')
  }

  const { data: bundle, error: openError } = await admin.rpc('secret_bundle_open', {
    p_bundle_id: row.bundle,
  })
  if (openError) {
    throw new AiError('not_configured', openError.message)
  }

  return providerConfigFrom(bundle as Record<string, unknown>)
}

function aiErrorResponse(err: unknown): Response {
  if (err instanceof AiError) {
    const configured = err.code !== 'not_configured'
    const status = err.code === 'invalid_fields' ? 400 : configured ? 502 : 503
    return errorResponse(err.code, err.message, status)
  }

  if (err instanceof SyntaxError) {
    return errorResponse('invalid_request', 'the request body was not JSON', 400)
  }

  return errorResponse('unexpected', err instanceof Error ? err.message : 'filling failed', 500)
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

  const userClient = userClientFor(authorization.replace(/^Bearer\s+/i, ''))
  const admin = serviceClient()

  try {
    const body = await readJson<FillBody>(request)

    // The authorization: `admin_pages` is owner-guarded, so a staff member's
    // request fails here with a `42501` before any credential is read. The
    // returned rows are not used - the form describes itself.
    const { error: authError } = await userClient.rpc('admin_pages')
    if (authError) {
      return errorResponse('forbidden', authError.message, 403)
    }

    const paragraph = text(body?.paragraph)
    if (!paragraph) {
      return errorResponse(
        'missing_paragraph',
        'write what the shop is or what the page sells before asking for a fill',
        400,
      )
    }

    const fields = readFields(body?.fields)
    const config = await readProviderConfig(admin)

    const { value } = await generateStructured<Record<string, string>>(fetch, config, {
      system: systemPrompt(fields),
      user: userPrompt(paragraph, fields),
      schema: answerSchema(fields),
      toolName: 'submit_form',
      toolDescription: 'Submit the filled form. Call this exactly once.',
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      timeoutMs: TIMEOUT_MS,
      temperature: TEMPERATURE,
    })

    return jsonResponse({ values: readAnswer(fields, value) })
  } catch (err) {
    return aiErrorResponse(err)
  }
})

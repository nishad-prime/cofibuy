/**
 * POST /functions/v1/ai-draft-copy
 *
 * Drafts one customer-facing string, in both languages, from the shop's own saved credential.
 *
 * Writes nothing. The answer goes back to the operator, who reads it, edits it if they disagree
 * and saves it through `api.admin_set_copy` like any other override. That is the whole safety
 * model of this feature: a model can propose copy, and only a person can publish it.
 *
 * Owner-only, and the check is the database's rather than this function's: `api.admin_copy` is
 * already owner-guarded, so calling it with the caller's own JWT authorises the request and hands
 * back the strings this key is allowed to be drafted from. A staff member's call fails there with
 * a `42501` before any credential is touched.
 *
 * No credential passes through a response, and none is logged. The bundle is opened on the
 * service-role client, turned into a provider config, and dropped.
 */

import { type ApiClient, serviceClient, userClientFor } from '../_shared/supabase.ts'
import { generateStructured } from '../_shared/ai/generate.ts'
import {
  DRAFT_SCHEMA,
  DRAFT_TOOL,
  draftSystemPrompt,
  draftUserPrompt,
  providerConfigFrom,
  readDraft,
  type CopyDraft,
  type DraftRequest,
} from '../_shared/ai/draft.ts'
import { AiError, type AiProviderConfig } from '../_shared/ai/provider.ts'
import { corsHeaders, errorResponse, jsonResponse, readJson } from '../_shared/http.ts'

interface DraftBody {
  key?: unknown
  /** The editor's own label and location for the key, so the prompt can say what the string is. */
  label?: unknown
  where?: unknown
}

/** One row of `api.admin_copy()`. */
interface CopyRow {
  key: string
  value_bn: string | null
  value_en: string | null
  is_markdown: boolean
}

/**
 * Caps, stated rather than defaulted.
 *
 * A copy string is a sentence or two, so 700 tokens is generous; a heading that comes back at
 * 4,000 tokens is a model that ignored the task and the operator should see a timeout rather than
 * a bill. Twenty seconds is longer than the model needs and short enough that a hung provider is
 * a message rather than a spinner. Retries are the core's business, not this function's.
 */
const MAX_OUTPUT_TOKENS = 700
const TIMEOUT_MS = 20_000

/** Not defaulted, for the same reason: an unconfigured shop should say so, not guess. */
const TEMPERATURE = 0.7

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

  // The caller's own JWT, forwarded unchanged. This client can read nothing of theirs: the only
  // thing it calls is owner-guarded, and every read of the credential happens on the other one.
  const userClient = userClientFor(authorization.replace(/^Bearer\s+/i, ''))

  const admin = serviceClient()

  try {
    const body = await readJson<DraftBody>(request)
    if (typeof body?.key !== 'string' || body.key === '') {
      return errorResponse('invalid_request', 'key is required', 400)
    }

    // The authorisation and the context in one round trip. A non-owner gets the database's own
    // `forbidden` here, which means this function never has to know what a role is.
    const { data: rows, error: copyError } = await userClient.rpc('admin_copy')
    if (copyError) {
      return errorResponse('forbidden', copyError.message, 403)
    }

    const row = (rows ?? []).find((r: CopyRow) => r.key === body.key)
    if (!row) {
      // Not "unknown key" as such: `admin_copy` only ever returns keys the app ships, so this
      // means the caller asked for one that does not exist, and saying so is more useful than a
      // 404 the editor cannot render.
      return errorResponse('unknown_key', `no editable copy key named ${body.key}`, 404)
    }

    const draft: DraftRequest = {
      key: row.key,
      label: typeof body.label === 'string' && body.label !== '' ? body.label : row.key,
      where: typeof body.where === 'string' && body.where !== '' ? body.where : row.key,
      isMarkdown: row.is_markdown,
      currentBn: row.value_bn,
      currentEn: row.value_en,
    }

    const config = await readProviderConfig(admin)
    const { value } = await generateStructured<CopyDraft>(fetch, config, {
      system: draftSystemPrompt(draft),
      user: draftUserPrompt(draft),
      schema: DRAFT_SCHEMA,
      toolName: DRAFT_TOOL.name,
      toolDescription: DRAFT_TOOL.description,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      timeoutMs: TIMEOUT_MS,
      temperature: TEMPERATURE,
    })

    return jsonResponse({ key: row.key, draft: readDraft(value), is_markdown: row.is_markdown })
  } catch (err) {
    return aiErrorResponse(err)
  }
})

/**
 * Resolves the shop's provider credential.
 *
 * Two calls and no alternatives: the lookup says which provider and which bundle, the opener is
 * the only path from a bundle id to plaintext. A shop with no provider gets `not_configured`,
 * which the editor renders as "set one up first" rather than as a failure - it is the expected
 * state for every shop that has not been through /admin/ai yet.
 */
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

/**
 * Maps a failure onto the status the editor can act on.
 *
 * The distinction that matters is `not_configured` (the operator has to visit /admin/ai) versus
 * everything else (the provider is configured and something went wrong talking to it). Provider
 * error codes are passed through as the detail because they are already written for a human and
 * none of them contains the key or any part of it.
 */
function aiErrorResponse(err: unknown): Response {
  if (err instanceof AiError) {
    const configured = err.code !== 'not_configured'
    return errorResponse(err.code, err.message, configured ? 502 : 503)
  }

  if (err instanceof SyntaxError) {
    return errorResponse('invalid_request', 'the request body was not JSON', 400)
  }

  return errorResponse('unexpected', err instanceof Error ? err.message : 'drafting failed', 500)
}

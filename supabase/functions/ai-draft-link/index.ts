/**
 * POST /functions/v1/ai-draft-link
 *
 * Drafts a whole product's bilingual copy from the operator's own description of the guide.
 *
 * Writes nothing. The answer goes back to the link form, where the operator reads each field,
 * applies the ones they agree with, edits them, and saves through `api.admin_upsert_link` like any
 * other link. The slug, the price and the CTA URL are never drafted: the slug is half of a URL
 * customers may already have bookmarked, and the model has no business inventing either of the
 * others.
 *
 * Owner-only. `api.admin_links()` is owner-guarded, so calling it with the caller's own JWT is the
 * authorization and a staff member's request fails there with a `42501` before the credential is
 * touched. It is the same function the link form already uses to load a link, which is why there
 * is no new SQL for this: the guard this needs already exists and is already proven by tests.
 */

import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { generateStructured } from '../_shared/ai/generate.ts'
import { providerConfigFrom } from '../_shared/ai/draft.ts'
import {
  LINK_BRIEF_SCHEMA,
  LINK_BRIEF_TOOL,
  linkBriefSystemPrompt,
  linkBriefUserPrompt,
  readLinkBrief,
  type LinkBrief,
  type LinkBriefRequest,
} from '../_shared/ai/linkBrief.ts'
import { AiError, type AiProviderConfig } from '../_shared/ai/provider.ts'
import { corsHeaders, errorResponse, jsonResponse, readJson } from '../_shared/http.ts'

interface DraftBody {
  /** The operator's description of the guide. The only account of what is in it. */
  subject?: unknown
  slug?: unknown
  title_en?: unknown
  title_bn?: unknown
  teaser_md_en?: unknown
  teaser_md_bn?: unknown
  unlock_body_md_en?: unknown
  unlock_body_md_bn?: unknown
  unlock_cta_label_en?: unknown
  unlock_cta_label_bn?: unknown
}

/**
 * The two numbers this function states rather than inherits.
 *
 * Eight fields across two languages is a longer answer than one string and the fields have to
 * agree with each other, so the ceiling is higher than C9's 700. A thousand tokens is still far
 * more than eight short fields need, and a model that blows past it is ignoring the task. Twenty
 * seconds matches the copy draft: a hung provider should be a message, not a spinner.
 */
const MAX_OUTPUT_TOKENS = 1000
const TIMEOUT_MS = 20_000

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
    const body = await readJson<DraftBody>(request)

    // The authorization. Called for its side effect, which is raising `42501` for anyone who is
    // not the owner; the rows it returns are not used, because the form's current values are
    // sent in the request and are the more recent copy - a staff member with a half-typed link in
    // a second tab would otherwise have those edits overwritten by the saved row.
    const { error: authError } = await userClient.rpc('admin_links')
    if (authError) {
      return errorResponse('forbidden', authError.message, 403)
    }

    const subject = text(body?.subject)
    if (!subject) {
      // Not a missing parameter so much as a missing premise. Without a description of the guide
      // the model has nothing but the slug to go on, and a draft built from a slug is exactly the
      // invented-contents problem the prompt spends its first rule ruling out.
      return errorResponse(
        'missing_subject',
        'describe what the guide is about before asking for a draft',
        400,
      )
    }

    const draft: LinkBriefRequest = {
      subject,
      slug: text(body?.slug) || undefined,
      titleEn: text(body?.title_en) || undefined,
      titleBn: text(body?.title_bn) || undefined,
      teaserMdEn: text(body?.teaser_md_en) || undefined,
      teaserMdBn: text(body?.teaser_md_bn) || undefined,
      unlockBodyMdEn: text(body?.unlock_body_md_en) || undefined,
      unlockBodyMdBn: text(body?.unlock_body_md_bn) || undefined,
      unlockCtaLabelEn: text(body?.unlock_cta_label_en) || undefined,
      unlockCtaLabelBn: text(body?.unlock_cta_label_bn) || undefined,
    }

    const config = await readProviderConfig(admin)
    const { value } = await generateStructured<LinkBrief>(fetch, config, {
      system: linkBriefSystemPrompt(draft),
      user: linkBriefUserPrompt(draft),
      schema: LINK_BRIEF_SCHEMA,
      toolName: LINK_BRIEF_TOOL.name,
      toolDescription: LINK_BRIEF_TOOL.description,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      timeoutMs: TIMEOUT_MS,
      temperature: TEMPERATURE,
    })

    return jsonResponse({ brief: readLinkBrief(value) })
  } catch (err) {
    return aiErrorResponse(err)
  }
})

/** Trims to a string, treating anything else as absent. */
function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

/**
 * Resolves the shop's provider credential: which provider and bundle, then the plaintext that
 * only `secret_bundle_open` can produce. Two calls, no fallback path, and the handle never leaves
 * this function.
 */
async function readProviderConfig(admin: SupabaseClient): Promise<AiProviderConfig> {
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
 * `not_configured` answers with 503 and everything else with 502, because the operator's next step
 * differs: one means go and set a provider up, the other means retry. Provider error codes pass
 * through as the detail - they are already written for a human and none of them carries the key.
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

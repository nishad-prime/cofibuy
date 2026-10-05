/**
 * Drafting a whole product's copy from one description of the product.
 *
 * Different shape from `draft.ts`, on purpose. A single copy string can be judged on its own -
 * "is this heading better?" - so the copy editor drafts one key at a time. A product's copy
 * cannot: a title, a teaser and an unlock body that each read well but disagree with each other
 * is worse than no draft, because the operator has to reconcile them by hand and that is the work
 * the button was supposed to save. So this produces the set in one call, and the fields are
 * written together or not at all.
 *
 * Everything decidable without a network call is here. The one thing this cannot do is read the
 * field guide, which is a PDF in an upload bucket: the operator's `subject` is the only account of
 * what is inside it, and the prompt says so with as much force as the schema can carry.
 */

import { AiError } from './provider.ts'
import type { JsonSchema } from './schema.ts'

/**
 * What the operator knows about the product, and what the form currently says.
 *
 * `subject` is the load-bearing field. Everything else is context: what the form holds now, so
 * this is a rewrite rather than a first draft.
 */
export interface LinkBriefRequest {
  /** The operator's own words for what the guide is and what is in it. */
  subject: string
  /** The slug, for context only. The model is told never to change it and is never asked for it. */
  readonly slug?: string
  readonly titleEn?: string
  readonly titleBn?: string
  readonly teaserMdEn?: string
  readonly teaserMdBn?: string
  readonly unlockBodyMdEn?: string
  readonly unlockBodyMdBn?: string
  readonly unlockCtaLabelEn?: string
  readonly unlockCtaLabelBn?: string
}

/**
 * One string per column, both languages.
 *
 * Named after the `paywall_links` columns rather than after the form fields, so the contract this
 * function speaks is the same vocabulary the database and `LinkView` already use. `save()` holds
 * the one mapping between the two vocabularies, which is the right place for it.
 */
export const LINK_BRIEF_SCHEMA: JsonSchema = {
  type: 'object',
  additionalProperties: false,
  required: [
    'title_en',
    'title_bn',
    'teaser_md_en',
    'teaser_md_bn',
    'unlock_body_md_en',
    'unlock_body_md_bn',
    'unlock_cta_label_en',
    'unlock_cta_label_bn',
  ],
  properties: {
    title_en: { type: 'string', description: 'The product title in English.' },
    title_bn: { type: 'string', description: 'The product title in Bangla.' },
    teaser_md_en: {
      type: 'string',
      description: 'The teaser in English: one or two sentences, plain markdown.',
    },
    teaser_md_bn: { type: 'string', description: 'The teaser in Bangla.' },
    unlock_body_md_en: {
      type: 'string',
      description: 'The post-payment body in English: a short paragraph or two of simple markdown.',
    },
    unlock_body_md_bn: { type: 'string', description: 'The post-payment body in Bangla.' },
    unlock_cta_label_en: {
      type: 'string',
      description: 'The short label on the button the customer clicks to pay. English.',
    },
    unlock_cta_label_bn: { type: 'string', description: 'The pay button label in Bangla.' },
  },
}

/** The tool the model is forced to call. */
export const LINK_BRIEF_TOOL = {
  name: 'submit_link_copy',
  description: 'Submit the finished copy for every field, in both languages. Call this once.',
} as const

/** The eight values, as the caller reads them out of the answer. */
export type LinkBrief = Record<string, string>

/**
 * The system prompt.
 *
 * The rule that matters most is the first one. The model has never seen the guide, so anything
 * specific it adds - "48 species with photographs", "with a full index" - is invention, and a
 * customer pays on the strength of that sentence. Stated as a prohibition with a consequence,
 * because "only use the information provided" reads to a model as a suggestion.
 */
export function linkBriefSystemPrompt(request: LinkBriefRequest): string {
  return [
    'You write the customer-facing copy for a single digital field guide sold by a small shop.',
    '',
    'Rules:',
    '- Describe ONLY what the operator tells you in their description of the guide. You have never seen the file, so every specific detail you add is invented, and a customer pays on the strength of what you write. If you do not know whether it has photographs, an index, maps or a particular number of entries, write around it.',
    '- Return every field. A field left empty is a blank card on the storefront.',
    '- Bangla must be in Bangla script, written as natural Bangla a reader would accept. Never transliterate the English. Each Bangla field is the translation of its English partner, not a different message.',
    '- The fields are rendered as markdown, so plain text and simple markdown are fine. No HTML, no images, no links beyond the pay button, no headings above level 3.',
    '- Write for someone on a phone, in plain Bangla or plain English. No jargon, no exclamation marks.',
    '- Never mention a price, a discount, a deadline, a guarantee, or a delivery date. None of those are yours to promise.',
    '',
    'What each field is for:',
    '- title: the name of the guide, as it appears on the card and in the browser title. Short. No marketing.',
    '- teaser: one or two sentences shown before payment, to say what the guide is about and who it is for. Not a summary of contents.',
    '- unlock_body_md: what the customer gets, shown after they pay. Two or three sentences at most. This is the last thing they read before downloading.',
    '- unlock_cta_label: the label on the pay button. Two or three words, like "Get the guide".',
    '',
    `The operator describes the guide as: "${request.subject.trim()}"`,
  ].join('\n')
}

/**
 * The user message: what the form already says, so the draft can improve on it instead of
 * replacing a carefully written title with the most average one available.
 *
 * Sent as a labelled block rather than prose because the labels are also the model's check that
 * every field it already has should come back in the same slot.
 */
export function linkBriefUserPrompt(request: LinkBriefRequest): string {
  const current = [
    ['title (en)', request.titleEn],
    ['title (bn)', request.titleBn],
    ['teaser (en)', request.teaserMdEn],
    ['teaser (bn)', request.teaserMdBn],
    ['unlock body (en)', request.unlockBodyMdEn],
    ['unlock body (bn)', request.unlockBodyMdBn],
    ['cta label (en)', request.unlockCtaLabelEn],
    ['cta label (bn)', request.unlockCtaLabelBn],
  ].filter(([, value]) => typeof value === 'string' && value.trim() !== '')

  return [
    current.length > 0
      ? `Write the copy for this guide. The form already holds the following, so improve it and keep whatever is already right.\n${current
          .map(([label, value]) => `- ${label}: ${(value as string).trim()}`)
          .join('\n')}`
      : 'Write the copy for this guide. The form is empty, so this is a first draft.',
    `Call ${LINK_BRIEF_TOOL.name} once with all eight fields.`,
  ].join('\n\n')
}

/**
 * Reads the answer.
 *
 * All eight or none. A partial set is the failure this whole design exists to prevent: the teaser
 * describes a guide the unlock body does not, and the operator cannot see the mismatch without
 * reading both. Raising `schema` here is also why this runs after `generateStructured` has
 * already spent its single retry on the shape - re-asking would only re-roll the same answer.
 */
export function readLinkBrief(answer: unknown): LinkBrief {
  if (typeof answer !== 'object' || answer === null) {
    throw new AiError('schema', 'the model did not return a copy set')
  }

  const source = answer as Record<string, unknown>
  const brief: LinkBrief = {}

  for (const key of LINK_BRIEF_SCHEMA.required as string[]) {
    const value = source[key]
    if (typeof value !== 'string' || value.trim() === '') {
      throw new AiError('schema', `the model left ${key} empty`)
    }
    // Trimmed for the same reason as a single draft: a trailing newline is an artefact of the
    // tool call, not a character the operator typed or would want saved into a card.
    brief[key] = value.trim()
  }

  return brief
}

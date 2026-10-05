/**
 * Which customer strings an operator may ask the model to draft.
 *
 * A positive list, for the same reason `MARKDOWN_ALLOWED` is one: the question being answered
 * is "would a rewrite here be an improvement, or a hazard". Answering that with a rule derived
 * from the key's namespace or its length is how `evidence.errMaxSize` ends up rewritten into
 * something vaguer than "5 MB", and the mistake is invisible until a customer uploads a file
 * the form had already promised to reject.
 *
 * So the list is written out, and the criteria are stated rather than encoded:
 *
 *   1. It is prose. A heading, a hint, a body, an empty state - something an operator reads and
 *      judges. Not a button label, not a status token, not a field caption.
 *   2. It carries no hard fact. `evidence.*` is excluded wholesale for this reason: those strings
 *      state limits (sizes, digit counts, formats) and softening one is a functional change
 *      wearing a copy change's clothes.
 *   3. It has no placeholder. Enforced separately, at runtime, in `canDraft` - because which keys
 *      carry `{amount}` is a property of the shipped translations rather than of the key name,
 *      and a rule that read the wrong one would either be wrong or need this list to change every
 *      time a translation did.
 *
 * Every markdown-capable key is in here. That is not a coincidence: `MARKDOWN_ALLOWED` is already
 * this repository's list of standalone prose blocks, and the test asserts the containment so the
 * two cannot drift apart quietly.
 */
import { type CopyKey, allowsMarkdown, placeholdersIn } from '@/config/copyKeys'

/**
 * Typed as `CopyKey[]` rather than `string[]`, so a key that is renamed or removed upstream fails
 * to compile here instead of leaving a button in the copy editor that drafts nothing.
 */
export const AI_WRITABLE = [
  // Shop identity. The name is left out on purpose: a shop's name is not a sentence to improve,
  // and a model asked for one will invent a product.
  'app.tagline',

  'home.heading',
  'home.subheading',
  'home.empty',

  'paywall.chooseMethod',
  'paywall.chooseMethodHint',
  'paywall.noMethods',
  'paywall.deliverable',
  'paywall.closedTitle',
  'paywall.closedBody',

  // The online-payment wording is shown at the moment a customer is most anxious about having
  // paid, which is the strongest argument in this file for letting it be rewritten carefully.
  'order.payOnlinePending',
  'order.payOnlineSandbox',
  'order.payOnlineReturnTitle',
  'order.payOnlineReturnBody',
  'order.payOnlineTestDone',
  'order.payOnlineFailed',
  'order.evidenceHint',
  'order.reminderBody',

  'recovery.title',
  'recovery.body',

  'notFound.title',
  'notFound.body',
] as const satisfies readonly CopyKey[]

export type AiWritableKey = (typeof AI_WRITABLE)[number]

const WRITABLE = new Set<string>(AI_WRITABLE)

/** True when the key is one an operator may draft. */
export function isAiWritable(key: string): boolean {
  return WRITABLE.has(key)
}

/** True when the key may be drafted *and* carries no interpolation the draft could drop. */
export function canDraft(key: string, ...bundled: string[]): boolean {
  return isAiWritable(key) && placeholdersIn(key, ...bundled).length === 0
}

/**
 * Whether the draft may contain markdown, which is the same question `allowsMarkdown` answers.
 * Re-exported here so the copy editor has one import for "may the model write this key", and the
 * two rules cannot be read from different files and assumed to agree.
 */
export function draftAllowsMarkdown(key: string): boolean {
  return isAiWritable(key) && allowsMarkdown(key)
}

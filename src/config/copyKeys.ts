/**
 * The editable-copy registry.
 *
 * This is the single source of truth for which customer strings an operator may
 * override. It is deliberately code rather than a database list, because the
 * question being answered is "does the running app ever ask for this key?" - a
 * question only the app can answer.
 *
 * Three consequences follow, and all of them are the point:
 *
 *   1. `getCopy('home.heading')` is typed. A typo is a compile error, not a
 *      silently dead override that costs an afternoon to find.
 *   2. `mirror.copyKeys()` and `private.copy_keys()` in SQL are checked against
 *      each other by `npm run copy:keys:check`, so the editor cannot offer a key
 *      the database would reject.
 *   3. The overrides are merged *over* the bundled locale messages. A missing key
 *      therefore degrades to the shipped text, which means a stale override can
 *      never blank a screen.
 */

/** Namespaces own a group of related keys. Order here is the admin editor order. */
export const COPY_NAMESPACES = [
  'app',
  'home',
  'paywall',
  'order',
  'evidence',
  'recovery',
  'common',
  'lang',
  'notFound',
] as const

export type CopyNamespace = (typeof COPY_NAMESPACES)[number]

/**
 * Every editable key, grouped so the editor can render sections without walking a
 * flat list. Kept as a literal rather than derived from the JSON at runtime: the
 * bundle is the fallback, not the source of what may be edited, and deriving it
 * would make adding a string automatically editable - including strings meant to
 * stay fixed, like error codes and accessibility labels.
 */
export const COPY_KEYS = {
  app: ['app.name', 'app.tagline'],
  home: ['home.heading', 'home.subheading', 'home.empty', 'home.browse'],
  paywall: [
    'paywall.back',
    'paywall.chooseMethod',
    'paywall.chooseMethodHint',
    'paywall.noMethods',
    'paywall.sendTo',
    'paywall.amount',
    'paywall.amountMin',
    'paywall.amountAny',
    'paywall.amountError',
    'paywall.summary',
    'paywall.summaryLink',
    'paywall.summaryAmount',
    'paywall.submit',
    'paywall.submitting',
    'paywall.refused',
    'paywall.refusedLocked',
    'paywall.deliverable',
    // Maintenance notice. Replaces the order form entirely, so `closedBody` is the
    // only place a customer learns why.
    'paywall.closedTitle',
    'paywall.closedBody',
    'paywall.closedContact',
  ],
  order: [
    'order.title',
    'order.reference',
    'order.rejectReason',
    // Status labels are editable too. An operator may well want to call a
    // rejected order something softer, and these are plain labels rendered
    // through the same `t()` as everything else.
    'order.status.draft',
    'order.status.awaiting_proof',
    'order.status.under_review',
    'order.status.approved',
    'order.status.rejected',
    'order.status.expired',
    'order.status.locked',
    'order.submitEvidence',
    'order.evidenceHint',
    'order.submitEvidenceCta',
    'order.submitting',
    'order.unlocked',
    'order.underReview',
    'order.rejected',
    'order.expired',
    'order.locked',
    'order.newOrder',
    'order.reminder',
    'order.reminderBody',
  ],
  evidence: [
    'evidence.required',
    'evidence.optional',
    'evidence.chooseImage',
    'evidence.maxSize',
    'evidence.errRequired',
    'evidence.errPhone',
    'evidence.errTrxid',
    'evidence.errNumeric',
    'evidence.errMaxLen',
    'evidence.errFileSize',
  ],
  recovery: [
    'recovery.title',
    'recovery.phone',
    'recovery.code',
    'recovery.body',
    'recovery.submit',
    'recovery.submitting',
    'recovery.sent',
    'recovery.back',
    'recovery.disabled',
  ],
  common: [
    'common.loading',
    'common.retry',
    'common.copy',
    'common.copied',
    'common.close',
    'common.optional',
    'common.required',
    'common.back',
    'common.yes',
    'common.no',
  ],
  lang: ['lang.switchTo', 'lang.label'],
  notFound: ['notFound.title', 'notFound.body', 'notFound.cta'],
} as const satisfies Record<CopyNamespace, readonly string[]>

export type CopyKey = (typeof COPY_KEYS)[CopyNamespace][number]

const NAMESPACE_KEYS = new Set<string>(COPY_NAMESPACES)

/** A group of related keys as one editor section. */
export interface CopySection {
  id: string
  keys: readonly string[]
}

/**
 * The copy an operator has an actual reason to change, grouped by where it appears.
 *
 * Every key stays editable and overridable - this is a presentation tier, not a
 * permission. It exists because all 82 keys on one page is 164 inputs, and roughly
 * 56 of them are chrome (`common.yes`, `evidence.errTrxid`, `order.status.*`) that
 * nobody rewords. Putting those in front of someone asking them to fix a typo is how
 * a settings page stops being usable.
 *
 * The tier is a hand-written positive list rather than the complement of
 * `COPY_KEYS`, for the reason `MARKDOWN_ALLOWED` is: a key added tomorrow must not
 * appear in the curated view by accident. If it is worth surfacing, it gets added
 * here on purpose.
 *
 * Grouped by screen rather than by namespace, because the question an operator has
 * is "what does the payment page say?", not "what does the paywall namespace hold?".
 *
 * All six markdown-capable keys fall inside this tier, so formatted prose is
 * available wherever prose actually lives, in both the curated and the full view.
 */
export const SIMPLE_COPY: readonly CopySection[] = [
  {
    id: 'identity',
    keys: ['app.name', 'app.tagline'],
  },
  {
    id: 'home',
    keys: ['home.heading', 'home.subheading', 'home.empty', 'home.browse'],
  },
  {
    id: 'paywall',
    keys: [
      'paywall.chooseMethod',
      'paywall.chooseMethodHint',
      'paywall.submit',
      'paywall.noMethods',
      'paywall.deliverable',
    ],
  },
  {
    id: 'closed',
    keys: ['paywall.closedTitle', 'paywall.closedBody', 'paywall.closedContact'],
  },
  {
    id: 'order',
    keys: ['order.reminder', 'order.reminderBody', 'order.evidenceHint', 'order.submitEvidence'],
  },
  { id: 'notFound', keys: ['notFound.title', 'notFound.body', 'notFound.cta'] },
  { id: 'recovery', keys: ['recovery.title', 'recovery.body'] },
  { id: 'evidence', keys: ['evidence.chooseImage'] },
]

/** Every key the curated view shows, flat. */
export function simpleCopyKeys(): string[] {
  return SIMPLE_COPY.flatMap((section) => [...section.keys])
}

/**
 * A human label for the editor. Shown instead of the raw key so an operator reads
 * "Home heading" rather than `home.heading`. Not itself editable - this is admin
 * chrome, and `adminI18n` is deliberately unreachable from the copy store.
 */
export function copyKeyLabel(key: string): string {
  const leaf = key.slice(key.indexOf('.') + 1)
  const spaced = leaf.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/[_-]+/g, ' ')
  return spaced.charAt(0).toUpperCase() + spaced.slice(1)
}

export function isCopyNamespace(value: string): value is CopyNamespace {
  return NAMESPACE_KEYS.has(value)
}

export function isCopyKey(value: string): value is CopyKey {
  return copyKeyList().includes(value)
}

/** Flat, in editor order. */
export function copyKeyList(): string[] {
  return COPY_NAMESPACES.flatMap((ns) => [...COPY_KEYS[ns]])
}

/**
 * Keys that must never render as markdown, whatever the database says.
 *
 * A label is text that sits inside a button or a heading. Rendering it as
 * markdown turns operator input into markup, and `is_markdown` is a per-row flag
 * the operator can set - so this is the layer that holds the line if the database
 * is ever wrong or an operator is careless. `MarkdownBody` sanitises regardless,
 * but sanitising is a safety net, not a permission.
 *
 * The list is longer than "labels". It also holds keys that could not be rendered
 * as markdown even in principle, which is why they are here rather than handled at
 * the call site:
 *
 *   - Interpolated strings (`paywall.amountMin`, `paywall.amountError`) become a
 *     sentence with a number in it. There is nothing to gain from markdown, and the
 *     value has already been through vue-i18n by the time a renderer would see it.
 *   - Attribute values (`paywall.amountAny` is an input placeholder). Markdown
 *     syntax in a placeholder is shown literally to the customer.
 *   - Strings interpolated into an existing `<p>` or `<section>` (the order status
 *     sentences). A rendered block would nest a `<div>` inside a `<p>`, which the
 *     browser closes early - the same defect that made an alert list in the copy
 *     editor disappear.
 *
 * What is left is exactly the set of keys that are standalone prose blocks, which
 * is what `CopyText` renders through `MarkdownBody`.
 *
 * The exhaustive list is maintained in `MARKDOWN_ALLOWED` below — any key not in
 * that list is implicitly forbidden. Keeping the positive list means a new key
 * added to `COPY_KEYS` is not accidentally markdown-capable until an explicit
 * decision is made.
 */
export const MARKDOWN_ALLOWED = [
  'notFound.body',
  'order.evidenceHint',
  'order.reminderBody',
  'paywall.chooseMethodHint',
  'paywall.deliverable',
  'recovery.body',
] as const satisfies readonly string[]

/**
 * The keys `CopyText` accepts.
 *
 * Narrower than `CopyKey` on purpose. `CopyText` renders through `MarkdownBody`
 * whenever the database says a key is markdown, so passing it a label would put
 * operator input inside a heading. The database already refuses that, and
 * `allowsMarkdown` already refuses it, but this makes it a type error too - the
 * call site cannot be written wrong in the first place.
 */
export type MarkdownCopyKey = (typeof MARKDOWN_ALLOWED)[number]

/** True when a key may be stored and rendered as markdown. */
export function allowsMarkdown(key: string): boolean {
  return (MARKDOWN_ALLOWED as readonly string[]).includes(key)
}

/** Placeholder tokens a value may contain, e.g. `{amount}` in `paywall.amountMin`. */
const PLACEHOLDER = /\{[a-zA-Z0-9_]+\}/g

/**
 * Interpolations a key expects. Compared before saving so a rewritten string
 * cannot silently drop `{amount}` and leave the customer reading "Minimum ".
 *
 * Takes the bundled text for *every* locale the key ships in, and unions the
 * tokens. The old single-bundle signature asked only the English file, so a token
 * present in English but missing from Bangla (or the reverse) was invisible - the
 * `bn` `paywall.amountError` had dropped `{amount}` entirely and no test noticed.
 */
export function placeholdersIn(key: string, ...bundled: string[]): string[] {
  if (!key.startsWith('paywall.') && !key.startsWith('order.') && !key.startsWith('evidence.')) {
    return []
  }
  const found = bundled.flatMap((value) => [...value.matchAll(PLACEHOLDER)].map((m) => m[0]))
  return [...new Set(found)]
}

export function missingPlaceholders(written: string, expected: string[]): string[] {
  return expected.filter((token) => !written.includes(token))
}

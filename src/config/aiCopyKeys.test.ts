import { describe, expect, it } from 'vitest'
import { AI_WRITABLE, canDraft, draftAllowsMarkdown, isAiWritable } from '@/config/aiCopyKeys'
import {
  COPY_KEYS,
  COPY_NAMESPACES,
  MARKDOWN_ALLOWED,
  allowsMarkdown,
  copyKeyList,
  placeholdersIn,
} from '@/config/copyKeys'
import { bundled } from '@/config/copySections'

/**
 * These assertions are about the *rules* behind the list rather than the list itself. A key added
 * to `AI_WRITABLE` is a judgement call and belongs in the file with its reasoning; what must not
 * be possible is the list drifting away from the registry it draws from, or quietly starting to
 * include a key that states a hard fact.
 */

const everyKey = COPY_NAMESPACES.flatMap((ns) => [...COPY_KEYS[ns]])

describe('AI_WRITABLE', () => {
  it('names only keys the app actually asks for', () => {
    const known = new Set(copyKeyList())
    const unknown = AI_WRITABLE.filter((key) => !known.has(key))
    expect(unknown).toEqual([])
  })

  it('has no duplicates', () => {
    expect(new Set(AI_WRITABLE).size).toBe(AI_WRITABLE.length)
  })

  /**
   * The containment that matters. `MARKDOWN_ALLOWED` is this repo's existing list of standalone
   * prose blocks - a key is in it precisely because it is a paragraph rather than a label - so a
   * markdown key missing here would mean the AI list and the prose list disagree about what
   * prose is.
   */
  it('covers every markdown-capable key', () => {
    const missing = MARKDOWN_ALLOWED.filter((key) => !isAiWritable(key))
    expect(missing).toEqual([])
  })

  /**
   * Criterion 2. These strings state a limit or a format, so a rewrite is a functional change.
   * The whole namespace is asserted rather than a sample of it, because the reasoning is per
   * key and a reviewer adding a tenth `evidence.*` string should meet this failure.
   */
  it("leaves out the evidence strings, which carry the form's limits", () => {
    const evidence = COPY_KEYS.evidence.filter((key) => isAiWritable(key))
    expect(evidence).toEqual([])
  })

  it('leaves out shared labels and accessibility strings', () => {
    const chrome = [...COPY_KEYS.common, ...COPY_KEYS.lang].filter((key) => isAiWritable(key))
    expect(chrome).toEqual([])
  })

  it('leaves out the shop name, which is an identity and not a sentence', () => {
    expect(isAiWritable('app.name')).toBe(false)
  })
})

describe('canDraft', () => {
  /**
   * Criterion 3. A draft that drops `{amount}` ships "Minimum " with nothing after it, so the
   * guard reads the shipped translations rather than trusting a naming convention - and the key
   * it refuses is a real one, not a synthetic fixture.
   */
  it('refuses a key whose shipped text carries a placeholder', () => {
    const withPlaceholder = everyKey.find(
      (key) =>
        isAiWritable(key) && placeholdersIn(key, bundled(key, 'en'), bundled(key, 'bn')).length > 0,
    )
    // None today, and that is the point: if one appears the guard has something to refuse and
    // the list needs a look. Asserted so a future translation cannot add one unnoticed.
    expect(withPlaceholder).toBeUndefined()
  })

  it('refuses a key that is not on the list, whatever its text says', () => {
    expect(canDraft('evidence.errMaxSize', 'Up to 5 MB')).toBe(false)
    expect(canDraft('common.close', 'Close')).toBe(false)
  })

  it('refuses a placeholder-bearing key even when it is on the list', () => {
    // `order.payOnlinePending` is listed, so this exercises the second half of the guard on its
    // own. The placeholder is supplied rather than found because `placeholdersIn` reads the
    // shipped text - the test is about the rule, not about today's wording.
    expect(canDraft('order.payOnlinePending', 'Pay now for {amount}')).toBe(false)
    expect(canDraft('order.payOnlinePending', 'Waiting for the provider to confirm')).toBe(true)
  })

  it('accepts every listed key as shipped', () => {
    const refused = AI_WRITABLE.filter(
      (key) => !canDraft(key, bundled(key, 'en'), bundled(key, 'bn')),
    )
    expect(refused).toEqual([])
  })
})

describe('draftAllowsMarkdown', () => {
  it('follows the markdown rule rather than the AI list', () => {
    expect(draftAllowsMarkdown('notFound.body')).toBe(true)
    // Prose, but stored as a single line: a draft here must not come back with a heading in it.
    expect(draftAllowsMarkdown('home.heading')).toBe(false)
    expect(draftAllowsMarkdown('evidence.errMaxSize')).toBe(false)
  })
})

describe('canDraft', () => {
  it('agrees with isAiWritable for every listed key', () => {
    for (const key of AI_WRITABLE) {
      expect(canDraft(key)).toBe(true)
    }
  })

  it('refuses a key that is not on the list, even with clean wording', () => {
    expect(canDraft('evidence.errMaxSize', 'Up to 5 MB', 'সর্বোচ্চ ৫ এমবি')).toBe(false)
    expect(canDraft('common.next', 'Next')).toBe(false)
  })

  /**
   * The half-finished state this whole feature exists to avoid: Bangla comes back with the
   * operator's current sentence and English comes back as a transliteration of it.
   */
  it('refuses a listed key once a translation carries a placeholder', () => {
    expect(canDraft('order.payOnlinePending', 'Pay {amount} online')).toBe(false)
    expect(canDraft('order.payOnlinePending', '', '{amount} দিয়ে পেমেন্ট করুন')).toBe(false)
  })

  it('refuses every markdown key only because of its wording, never because of its namespace', () => {
    for (const key of MARKDOWN_ALLOWED) {
      expect(isAiWritable(key)).toBe(true)
      expect(canDraft(key, 'A **readable** guide to the delta.')).toBe(
        placeholdersIn(key, 'A **readable** guide to the delta.').length === 0,
      )
    }
  })
})

describe('draftAllowsMarkdown', () => {
  it('matches allowsMarkdown for every writable key', () => {
    for (const key of AI_WRITABLE) {
      expect(draftAllowsMarkdown(key)).toBe(allowsMarkdown(key))
    }
  })

  it('refuses markdown for a key that is not on the list', () => {
    expect(draftAllowsMarkdown('common.close')).toBe(false)
  })
})

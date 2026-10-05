import { assert, assertEquals, assertStringIncludes, assertThrows } from '@std/assert'
import { describe, it } from 'node:test'
import { AiError } from './provider.ts'
import {
  LINK_BRIEF_SCHEMA,
  LINK_BRIEF_TOOL,
  linkBriefSystemPrompt,
  linkBriefUserPrompt,
  readLinkBrief,
  type LinkBriefRequest,
} from './linkBrief.ts'

const request: LinkBriefRequest = {
  subject: 'A pocket guide to the birds of the Sundarbans, for people new to birdwatching.',
  titleEn: 'Birds of the Sundarbans',
  titleBn: 'সুন্দরবনের পাখি',
}

/** A complete, valid answer, so each test can spoil exactly one field. */
const complete = {
  title_en: 'Birds of the Sundarbans',
  title_bn: 'সুন্দরবনের পাখি',
  teaser_md_en: 'A pocket guide to the birds of the delta, for people starting out.',
  teaser_md_bn: 'ডেল্টার পাখির পকেট গাইড, নতুনদের জন্য।',
  unlock_body_md_en: 'After payment you can download the guide and keep it offline.',
  unlock_body_md_bn: 'পেমেন্টের পর গাইডটি ডাউনলোড করে অফলাইনে রাখতে পারবেন।',
  unlock_cta_label_en: 'Get the guide',
  unlock_cta_label_bn: 'গাইড নিন',
}

describe('linkBriefSystemPrompt', () => {
  const system = linkBriefSystemPrompt(request)

  /**
   * The rule the rest of this feature is built around. The model cannot see the field guide, so
   * an invented detail is not a stylistic slip - it is a claim a customer pays for and does not
   * receive.
   */
  it('forbids inventing what is inside the guide', () => {
    assertStringIncludes(system, 'every specific detail you add is invented')
    assertStringIncludes(system, 'never seen the file')
  })

  it('passes the operator description through as the source of truth', () => {
    assertStringIncludes(system, request.subject)
  })

  it('explains what each field is for', () => {
    for (const field of ['title', 'teaser', 'unlock_body_md', 'unlock_cta_label']) {
      assertStringIncludes(system, `- ${field}`)
    }
  })

  it("keeps pricing and promises out of the model's reach", () => {
    assertStringIncludes(system, 'Never mention a price')
  })

  it('demands every field, since an empty one is a blank card', () => {
    assertStringIncludes(system, 'A field left empty is a blank card')
  })
})

describe('linkBriefUserPrompt', () => {
  it('passes the current wording so the draft can improve it', () => {
    const user = linkBriefUserPrompt(request)
    assertStringIncludes(user, 'title (en): Birds of the Sundarbans')
    assertStringIncludes(user, 'title (bn): সুন্দরবনের পাখি')
  })

  it('leaves out fields the form does not hold yet', () => {
    const user = linkBriefUserPrompt({ subject: 'A guide.' })
    assertStringIncludes(user, 'first draft')
    assert(!user.includes('teaser (en)'))
  })

  it('names the tool to call', () => {
    assertStringIncludes(linkBriefUserPrompt(request), LINK_BRIEF_TOOL.name)
  })

  it('trims a pasted subject rather than quoting the whitespace', () => {
    assertStringIncludes(linkBriefSystemPrompt({ subject: '  A guide.  ' }), '"A guide."')
  })
})

describe('readLinkBrief', () => {
  it('reads and trims every field', () => {
    const padded = Object.fromEntries(Object.entries(complete).map(([k, v]) => [k, `  ${v}  `]))
    assertEquals(readLinkBrief(padded), complete)
  })

  /**
   * The whole point of the single-call design. A set where the teaser and the unlock body describe
   * different guides is worse than no draft, because the mismatch is invisible until a customer
   * has paid.
   */
  it('refuses a partial set and names the field', () => {
    const { unlock_body_md_bn: _dropped, ...partial } = complete
    const error = assertThrows(() => readLinkBrief(partial), AiError)
    assertEquals(error.code, 'schema')
    assertStringIncludes(error.message, 'unlock_body_md_bn')
  })

  it('refuses an empty or whitespace field', () => {
    for (const blank of ['', '   ']) {
      const error = assertThrows(() => readLinkBrief({ ...complete, title_bn: blank }), AiError)
      assertEquals(error.code, 'schema')
      assertStringIncludes(error.message, 'title_bn')
    }
  })

  it('refuses a non-object answer', () => {
    assertEquals(assertThrows(() => readLinkBrief('done'), AiError).code, 'schema')
    assertEquals(assertThrows(() => readLinkBrief(null), AiError).code, 'schema')
  })
})

describe('LINK_BRIEF_SCHEMA', () => {
  it('requires all eight fields and allows nothing else', () => {
    assertEquals(LINK_BRIEF_SCHEMA.type, 'object')
    assertEquals(LINK_BRIEF_SCHEMA.additionalProperties, false)
    assertEquals((LINK_BRIEF_SCHEMA.required as string[]).length, 8)
    assertEquals(Object.keys(LINK_BRIEF_SCHEMA.properties as object).length, 8)
  })

  /**
   * `readLinkBrief` iterates the required list, so a schema that required a field it does not
   * define - or vice versa - would validate at the provider and then fail here, spending the
   * single retry for a mismatch that is really a bug in this file.
   */
  it('defines exactly the fields it requires', () => {
    const required = (LINK_BRIEF_SCHEMA.required as string[]).slice().sort()
    const defined = Object.keys(LINK_BRIEF_SCHEMA.properties as object).sort()
    assertEquals(defined, required)
  })
})

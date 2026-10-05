import { assert, assertEquals, assertStringIncludes, assertThrows } from '@std/assert'
import { describe, it } from 'node:test'
import { AiError } from './provider.ts'
import {
  DRAFT_SCHEMA,
  DRAFT_TOOL,
  chatCompletionsUrl,
  draftSystemPrompt,
  draftUserPrompt,
  providerConfigFrom,
  readDraft,
  type DraftRequest,
} from './draft.ts'

const request: DraftRequest = {
  key: 'home.heading',
  label: 'Home heading',
  where: 'the heading at the top of the homepage',
  isMarkdown: false,
  currentBn: 'মাঠের গাইড',
  currentEn: 'Field guides from the field',
}

describe('chatCompletionsUrl', () => {
  it('appends the endpoint to a base URL', () => {
    assertEquals(
      chatCompletionsUrl('https://api.openai.com/v1'),
      'https://api.openai.com/v1/chat/completions',
    )
  })

  it('tolerates a trailing slash', () => {
    assertEquals(
      chatCompletionsUrl('https://api.openai.com/v1/'),
      'https://api.openai.com/v1/chat/completions',
    )
  })

  /**
   * The case that costs an afternoon: an operator pastes the full endpoint into a box labelled
   * "Base URL", and the naive join produces a URL that 404s - which the provider reports as an
   * invalid key, sending the operator to rotate a credential that was never wrong.
   */
  it('leaves an already-complete endpoint alone', () => {
    assertEquals(
      chatCompletionsUrl('https://api.openai.com/v1/chat/completions'),
      'https://api.openai.com/v1/chat/completions',
    )
  })

  it('keeps a path prefix, which self-hosted and proxied endpoints use', () => {
    assertEquals(
      chatCompletionsUrl('https://llm.internal/openai/v1'),
      'https://llm.internal/openai/v1/chat/completions',
    )
  })

  it('trims surrounding whitespace from a paste', () => {
    assertEquals(
      chatCompletionsUrl('  https://api.openai.com/v1  '),
      'https://api.openai.com/v1/chat/completions',
    )
  })
})

describe('providerConfigFrom', () => {
  const bundle = {
    api_key: '  sk-test  ',
    base_url: ' https://api.openai.com/v1 ',
    model: ' small-model ',
  }

  it('reads and trims the three fields', () => {
    assertEquals(providerConfigFrom(bundle), {
      url: 'https://api.openai.com/v1/chat/completions',
      apiKey: 'sk-test',
      model: 'small-model',
    })
  })

  /**
   * A missing field is a configuration mistake, and the alternative - passing an empty string and
   * letting the provider answer - turns "you never saved a model" into a 401 that says nothing
   * about which of three fields is blank.
   */
  it('names the field that is missing', () => {
    const cases: [Record<string, unknown>, string][] = [
      [{}, 'api_key'],
      [{ api_key: 'k', base_url: 'https://x/v1' }, 'model'],
      [{ api_key: 'k', model: 'm' }, 'base_url'],
      [{ api_key: '   ', base_url: 'https://x/v1', model: 'm' }, 'api_key'],
    ]

    for (const [input, field] of cases) {
      const error = assertThrows(() => providerConfigFrom(input), AiError)
      assertEquals(error.code, 'not_configured')
      assertStringIncludes(error.message, field)
    }
  })

  it('refuses a missing or empty bundle rather than calling with blanks', () => {
    assertEquals(assertThrows(() => providerConfigFrom(null), AiError).code, 'not_configured')
    assertEquals(assertThrows(() => providerConfigFrom(undefined), AiError).code, 'not_configured')
    assertEquals(assertThrows(() => providerConfigFrom({}), AiError).code, 'not_configured')
  })
})

describe('draftSystemPrompt', () => {
  it('tells the model what the string is for', () => {
    const system = draftSystemPrompt(request)
    assertStringIncludes(system, 'the heading at the top of the homepage')
    assertStringIncludes(system, 'Home heading')
  })

  /**
   * Both of these failures pass a schema, which is why they are rules rather than types:
   * a heading that comes back as a paragraph, and Bangla that is transliterated English.
   */
  it('asks for natural Bangla rather than transliteration', () => {
    assertStringIncludes(draftSystemPrompt(request), 'transliterate')
  })

  it('asks for plain text when the key is not markdown', () => {
    const system = draftSystemPrompt(request)
    assertStringIncludes(system, 'rendered as plain text')
    assert(!system.includes('rendered as markdown'))
  })

  it('allows markdown only when the key is rendered as markdown', () => {
    const system = draftSystemPrompt({ ...request, isMarkdown: true })
    assertStringIncludes(system, 'rendered as markdown')
  })
})

describe('draftUserPrompt', () => {
  it('passes the current wording so this is a rewrite', () => {
    const user = draftUserPrompt(request)
    assertStringIncludes(user, 'Current English: Field guides from the field')
    assertStringIncludes(user, 'Current Bangla: মাঠের গাইড')
  })

  /**
   * Silence here reads as "keep what is there", and the model has no way to tell the difference
   * between a key that has never been overridden and one the operator deliberately cleared.
   */
  it('says so when there is no saved wording', () => {
    const user = draftUserPrompt({ ...request, currentBn: null, currentEn: null })
    assertStringIncludes(user, 'first draft')
    assert(!user.includes('Current English'))
  })

  it('names the tool to call', () => {
    assertStringIncludes(draftUserPrompt(request), DRAFT_TOOL.name)
  })
})

describe('readDraft', () => {
  it('reads and trims both languages', () => {
    assertEquals(readDraft({ value_bn: '  বাংলা  ', value_en: ' English ' }), {
      value_bn: 'বাংলা',
      value_en: 'English',
    })
  })

  /**
   * A whitespace-only string is valid against `type: string`, so the schema cannot catch it. Left
   * unchecked it would be accepted as a draft and blank the field it was meant to fill.
   */
  it('refuses an empty language', () => {
    for (const bad of [
      { value_bn: '', value_en: 'English' },
      { value_bn: 'বাংলা', value_en: '   ' },
    ]) {
      const error = assertThrows(() => readDraft(bad), AiError)
      assertEquals(error.code, 'schema')
    }
  })

  it('refuses a non-object answer', () => {
    assertEquals(assertThrows(() => readDraft('done'), AiError).code, 'schema')
    assertEquals(assertThrows(() => readDraft(null), AiError).code, 'schema')
  })
})

describe('DRAFT_SCHEMA', () => {
  it('requires both languages and allows nothing else', () => {
    assertEquals(DRAFT_SCHEMA.type, 'object')
    assertEquals(DRAFT_SCHEMA.additionalProperties, false)
    assertEquals([...(DRAFT_SCHEMA.required ?? [])].sort(), ['value_bn', 'value_en'])
  })
})

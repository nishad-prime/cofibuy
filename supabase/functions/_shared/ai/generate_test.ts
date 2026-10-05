/**
 * Tests for the retry policy.
 *
 * Every case here is about *how many times the provider is called*, because that is the
 * difference between this core and a loop. A retry that fires on a 429 or a truncated
 * answer spends money to arrive at the same failure; a retry that fires on a missing key
 * arrives somewhere else entirely. The fake fetch counts calls so the distinction is checked
 * rather than assumed.
 */

import { expect } from '@std/expect'
import { generateStructured } from './generate.ts'
import { AiError } from './provider.ts'
import type { JsonSchema, ValidationIssue } from './schema.ts'

const config = {
  url: 'https://ai.test/v1/chat/completions',
  apiKey: 'sk-test-key',
  model: 'test-model',
}

const item: JsonSchema = {
  type: 'object',
  required: ['key', 'bn'],
  properties: {
    key: { type: 'string' },
    bn: { type: 'string' },
  },
}

function twoItems(): JsonSchema {
  return {
    type: 'object',
    required: ['items'],
    properties: { items: { type: 'array', minItems: 2, maxItems: 2, items: item } },
  }
}

const request = {
  system: 'You rewrite shop copy.',
  user: 'Rewrite home.title and home.sub.',
  schema: twoItems(),
  maxOutputTokens: 800,
  timeoutMs: 5000,
}

/** A 200 whose single choice is a tool call carrying `args`. */
function toolCall(args: unknown, finishReason = 'tool_calls'): Response {
  return jsonResponse({
    choices: [
      {
        finish_reason: finishReason,
        message: {
          tool_calls: [{ function: { name: 'submit', arguments: JSON.stringify(args) } }],
        },
      },
    ],
  })
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

/** The single request body these tests ever send. */
interface SentBody {
  tool_choice: unknown
  parallel_tool_calls: boolean
  max_tokens: number
  temperature: number
  tools: Array<{ function: { parameters: unknown } }>
  messages: Array<{ role: string; content: string }>
}

/** Hands out each response in turn, and records every request body it was given. */
function fakeFetch(responses: Response[]): { fetch: typeof fetch; bodies: SentBody[] } {
  const bodies: SentBody[] = []
  let call = 0
  const impl = ((_url: string | URL | Request, init?: RequestInit) => {
    bodies.push(JSON.parse(init?.body as string) as SentBody)
    const response = responses[call] ?? responses[responses.length - 1]
    call += 1
    return Promise.resolve(response)
  }) as unknown as typeof fetch
  return { fetch: impl, bodies }
}

/** Never answers, and rejects when the call is aborted - a real timeout, in miniature. */
const hangingFetch = ((_url: string | URL | Request, init?: RequestInit) =>
  new Promise<Response>((_resolve, reject) => {
    init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
  })) as unknown as typeof fetch

async function expectAiError(run: () => Promise<unknown>, code: string): Promise<AiError> {
  try {
    await run()
  } catch (error) {
    expect(error).toBeInstanceOf(AiError)
    expect((error as AiError).code).toBe(code)
    return error as AiError
  }
  throw new Error(`expected the call to fail with ${code}`)
}

Deno.test('a valid answer is returned from a single call', async () => {
  const value = {
    items: [
      { key: 'home.title', bn: 'হোম' },
      { key: 'home.sub', bn: 'সাব' },
    ],
  }
  const { fetch, bodies } = fakeFetch([toolCall(value)])

  const result = await generateStructured(fetch, config, request)

  expect(result).toEqual({ value, attempts: 1 })
  expect(bodies).toHaveLength(1)
})

Deno.test('the tool call is forced, capped, and singular', async () => {
  const { fetch, bodies } = fakeFetch([
    toolCall({
      items: [
        { key: 'a', bn: 'b' },
        { key: 'c', bn: 'd' },
      ],
    }),
  ])

  await generateStructured(fetch, config, request)

  const sent = bodies[0]
  // Named outright, not offered: this is what makes "the model declined" detectable instead
  // of a well-formed empty object.
  expect(sent.tool_choice).toEqual({ type: 'function', function: { name: 'submit' } })
  expect(sent.parallel_tool_calls).toBe(false)
  // The only place a spend limit is enforced, so it is checked here rather than trusted.
  expect(sent.max_tokens).toBe(800)
  expect(sent.temperature).toBe(0)
  expect(sent.tools).toHaveLength(1)
  // The schema advertised to the model is the one validated locally, so the two halves
  // cannot drift apart.
  expect(sent.tools[0].function.parameters).toEqual(request.schema)
  expect(sent.messages).toEqual([
    { role: 'system', content: request.system },
    { role: 'user', content: request.user },
  ])
})

Deno.test('one validation failure buys exactly one more call', async () => {
  const good = {
    items: [
      { key: 'home.title', bn: 'হোম' },
      { key: 'home.sub', bn: 'সাব' },
    ],
  }
  const { fetch, bodies } = fakeFetch([
    toolCall({ items: [{ key: 'home.title', bn: 'হোম' }] }),
    toolCall(good),
  ])

  const result = await generateStructured(fetch, config, request)

  expect(result).toEqual({ value: good, attempts: 2 })
  expect(bodies).toHaveLength(2)
  // The repair prompt repeats the original request in full. Without it the model repairs
  // the shape and drops the task - three valid items when five were asked for is a
  // perfectly valid answer to the wrong question.
  const repair = bodies[1].messages[1].content as string
  expect(repair).toContain('Rewrite home.title and home.sub.')
  expect(repair).toContain('- items needs at least 2 item(s), got 1')
  // The first attempt's own text must not be quoted back: a model shown its previous
  // answer talks itself out of the correction.
  expect(repair).not.toContain('হোম')
  expect(repair).toContain('Keep everything that was already correct')
})

Deno.test('two failures stop the loop and report the last one', async () => {
  const { fetch, bodies } = fakeFetch([
    toolCall({ items: [{ bn: 'no key' }] }),
    toolCall({ items: [{ bn: 'still no key' }] }),
  ])

  const error = await expectAiError(() => generateStructured(fetch, config, request), 'schema')

  // Two calls, never three. An unbounded retry loop against a paid API is the failure mode
  // this whole file exists to prevent.
  expect(bodies).toHaveLength(2)
  expect(error.providerMessage).toContain('- items[0].key is required but missing')
  // The reported issues are the second attempt's, not the first's. Quoting the earlier
  // failure would point at a problem the model has already replaced.
  expect(error.providerMessage).toContain('- items needs at least 2 item(s), got 1')
})

Deno.test('domain checks drive the same retry as schema failures', async () => {
  // "Every key you asked for came back" cannot be expressed in the shape alone, but the
  // model can fix it, so it belongs on the same retry rather than failing the request.
  let calls = 0
  const missing = (_value: unknown): ValidationIssue[] =>
    calls++ === 0 ? [{ path: 'items[1].key', message: 'was not one of the requested keys' }] : []
  const good = {
    items: [
      { key: 'home.title', bn: 'হোম' },
      { key: 'home.sub', bn: 'সাব' },
    ],
  }
  const { fetch, bodies } = fakeFetch([toolCall(good), toolCall(good)])

  const result = await generateStructured(fetch, config, { ...request, check: missing })

  expect(result).toEqual({ value: good, attempts: 2 })
  expect(bodies[1].messages[1].content).toContain(
    '- items[1].key was not one of the requested keys',
  )
})

Deno.test('a truncated answer is not retried', async () => {
  // The ceiling that truncated it is the ceiling the retry would run under. A second call
  // with the same cap on the same task truncates at the same place, at full price.
  const { fetch, bodies } = fakeFetch([toolCall({ items: [{ key: 'a', bn: 'b' }] }, 'length')])

  await expectAiError(() => generateStructured(fetch, config, request), 'truncated')

  expect(bodies).toHaveLength(1)
})

Deno.test('a refusal is reported as a refusal, not retried', async () => {
  // No tool call at all: the model declined. The alternative - parsing prose - is how a
  // chatty model ends up in a copy field.
  const { fetch, bodies } = fakeFetch([
    jsonResponse({
      choices: [{ finish_reason: 'stop', message: { content: 'I cannot help with that.' } }],
    }),
  ])

  await expectAiError(() => generateStructured(fetch, config, request), 'refused')

  expect(bodies).toHaveLength(1)
})

Deno.test('rate limits and bad keys are surfaced by status, once each', async () => {
  for (const [status, code] of [
    [429, 'rate_limited'],
    [401, 'unauthorized'],
    [500, 'rejected'],
  ] as const) {
    const { fetch, bodies } = fakeFetch([jsonResponse({ error: { message: 'nope' } }, status)])

    await expectAiError(() => generateStructured(fetch, config, request), code)

    // Immediate repetition against a provider that just said no is how a shop's AI budget
    // disappears in an afternoon.
    expect(bodies).toHaveLength(1)
  }
})

Deno.test('an aborted call is a timeout, and is not retried', async () => {
  await expectAiError(
    () => generateStructured(hangingFetch, config, { ...request, timeoutMs: 20 }),
    'timeout',
  )
})

Deno.test('a missing configuration fails before any request is made', async () => {
  const { fetch, bodies } = fakeFetch([toolCall({})])

  await expectAiError(
    () => generateStructured(fetch, { ...config, apiKey: '' }, request),
    'not_configured',
  )

  expect(bodies).toHaveLength(0)
})

Deno.test('provider error text is scrubbed of anything key-shaped', async () => {
  // A provider that quotes the offending request back would otherwise put the credential
  // into a log line, an error reporter, or a screenshot of the dashboard.
  const { fetch } = fakeFetch([
    jsonResponse({ error: { message: 'bad key sk-live-9f2a1b3c4d5e6f70 sent' } }, 401),
  ])

  const error = await expectAiError(
    () => generateStructured(fetch, config, request),
    'unauthorized',
  )

  expect(error.providerMessage).toBe('bad key [redacted] sent')
})

Deno.test('an html error page is not reported as a parse failure', async () => {
  // A proxy or captive network in front of the provider answers with markup. Describing
  // that as broken JSON sends the reader looking at their own code.
  const { fetch } = fakeFetch([new Response('<html>gateway</html>', { status: 502 })])

  const error = await expectAiError(() => generateStructured(fetch, config, request), 'rejected')

  expect(error.providerMessage).toBe(null)
})

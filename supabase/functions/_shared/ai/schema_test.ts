/**
 * Tests for the schema subset.
 *
 * The property worth protecting is the first test below: a validator that reports one
 * problem at a time cannot be used as a repair prompt, and the whole retry in generate.ts
 * depends on getting the full list.
 */

import { expect } from '@std/expect'
import { formatIssues, toJsonSchema, validate, type JsonSchema } from './schema.ts'

const copyItem: JsonSchema = {
  type: 'object',
  required: ['key', 'bn'],
  properties: {
    key: { type: 'string', minLength: 1, maxLength: 80 },
    bn: { type: 'string', minLength: 1, maxLength: 240 },
    en: { type: 'string', maxLength: 240 },
  },
}

/** The shape a copy-rewrite call advertises: a fixed-length list of fixed-shape items. */
function suggestionsSchema(count: number): JsonSchema {
  return {
    type: 'object',
    required: ['items'],
    properties: {
      items: { type: 'array', minItems: count, maxItems: count, items: copyItem },
    },
  }
}

function issuesFor(schema: JsonSchema, value: unknown) {
  // Rendered the way `formatIssues` renders them, minus the bullet, so the expectations
  // below read as the lines the retry prompt is actually made of.
  return validate(schema, value).map((issue) =>
    issue.path === '' ? issue.message : `${issue.path} ${issue.message}`,
  )
}

Deno.test('accepts a well-formed answer', () => {
  expect(
    validate(suggestionsSchema(2), {
      items: [
        { key: 'home.title', bn: 'হোম' },
        { key: 'home.sub', bn: 'সাব' },
      ],
    }),
  ).toEqual([])
})

Deno.test('reports every problem in one pass, each with a path', () => {
  // Three separate mistakes across three items. The retry prompt is built from exactly this
  // output, so a validator that stopped at the first would leave two of them in place and
  // then fail the retry for a different reason.
  const issues = issuesFor(suggestionsSchema(2), {
    items: [
      { key: 'home.title', bn: '' },
      { en: 'missing the key entirely' },
      { key: 'home.' + 'x'.repeat(90), bn: 'a third item nobody asked for' },
    ],
  })

  expect(issues).toEqual([
    'items allows at most 2 item(s), got 3',
    'items[0].bn must be at least 1 character(s)',
    'items[1].key is required but missing',
    // Both missing keys on the same item, not just the first: the retry needs the lot.
    'items[1].bn is required but missing',
    'items[2].key must be at most 80 character(s)',
  ])
})

Deno.test('array bounds are checked on both sides', () => {
  expect(issuesFor(suggestionsSchema(2), { items: [{ key: 'a', bn: 'b' }] })).toEqual([
    'items needs at least 2 item(s), got 1',
  ])
  expect(
    issuesFor(suggestionsSchema(1), {
      items: [
        { key: 'a', bn: 'b' },
        { key: 'c', bn: 'd' },
      ],
    }),
  ).toEqual(['items allows at most 1 item(s), got 2'])
})

Deno.test('validates every item, not just the first', () => {
  // A bad fifth sentence must not pass on the strength of a good first one.
  const issues = issuesFor(suggestionsSchema(2), {
    items: [
      { key: 'a', bn: 'fine' },
      { key: 7, bn: 'key is a number' },
    ],
  })

  expect(issues).toContain('items[1].key expected string, got number')
})

Deno.test('rejects NaN as a number', () => {
  // `NaN` is typeof number and satisfies every bound, so it would otherwise pass and then
  // land in a payload as a value that is neither usable nor renderable.
  expect(issuesFor({ type: 'number', minimum: 0 }, Number.NaN)).toEqual([
    'expected number, got number',
  ])
  expect(validate({ type: 'number', minimum: 0 }, 0)).toEqual([])
})

Deno.test('names null, arrays and objects precisely', () => {
  // `typeof []` is object, so an array in an object slot would otherwise be described as the
  // thing it is not.
  expect(issuesFor({ type: 'object' }, [])).toEqual(['expected object, got array'])
  expect(issuesFor({ type: 'object' }, null)).toEqual(['expected object, got null'])
})

Deno.test('enforces enums and string bounds', () => {
  expect(issuesFor({ type: 'string', enum: ['live', 'sandbox'] }, 'staging')).toEqual([
    'must be one of live, sandbox',
  ])
  expect(issuesFor({ type: 'string', maxLength: 5 }, 'sixsix')).toEqual([
    'must be at most 5 character(s)',
  ])
})

Deno.test('ignores unknown keys by default and refuses them on request', () => {
  const loose: JsonSchema = { type: 'object', properties: { a: { type: 'string' } } }
  const strict: JsonSchema = { ...loose, additionalProperties: false }

  expect(validate(loose, { a: 'x', b: 'surprise' })).toEqual([])
  expect(issuesFor(strict, { a: 'x', b: 'surprise' })).toEqual(['b is not an expected key'])
})

Deno.test('toJsonSchema keeps descriptions and drops everything it cannot express', () => {
  const wire = toJsonSchema({
    type: 'object',
    description: 'The finished answer',
    required: ['items'],
    properties: {
      items: {
        type: 'array',
        description: 'One per requested key',
        maxItems: 2,
        items: {
          type: 'object',
          required: ['key'],
          properties: {
            // The description is the payload for the model, not documentation: it is what
            // separates "bn means Bangla" from two copies of the same sentence.
            bn: { type: 'string', description: 'Bangla' },
            key: { type: 'string', description: 'Copy key' },
          },
        },
      },
    },
  })

  expect(wire).toEqual({
    type: 'object',
    description: 'The finished answer',
    required: ['items'],
    properties: {
      items: {
        type: 'array',
        description: 'One per requested key',
        maxItems: 2,
        items: {
          type: 'object',
          required: ['key'],
          properties: {
            bn: { type: 'string', description: 'Bangla' },
            key: { type: 'string', description: 'Copy key' },
          },
        },
      },
    },
  })
})

Deno.test('formatIssues renders a list the model can act on', () => {
  // The root is labelled, because "is required but missing" with no path is unreadable once
  // it is one line in a longer prompt.
  expect(
    formatIssues([
      { path: '', message: 'expected object, got null' },
      { path: 'items[1].bn', message: 'is required but missing' },
    ]),
  ).toBe(['- (root) expected object, got null', '- items[1].bn is required but missing'].join('\n'))
})

/**
 * A small JSON Schema subset, and a validator that speaks it.
 *
 * Written rather than pulled in because the alternative was a 40 kB dependency in the
 * deploy bundle of two functions, for a shape that is four types deep. What is here is the
 * part that earns its keep:
 *
 *   1. It reports *every* problem at once, each with a JSON path.
 *
 *      A validator that stops at the first error is fine for a form. It is actively
 *      harmful here, because the one retry this core is allowed re-sends the failures to
 *      the model as instructions. "items[2].bn is missing" lets the model fix three
 *      sentences; "the output was invalid" makes it guess, and the retry then fails in a
 *      different place. That is the entire reason this is hand-written: the error list is
 *      the retry's only input.
 *
 *   2. `toJsonSchema` produces what goes on the wire.
 *
 *      The same declaration is the validator and the provider's schema, so they cannot
 *      disagree. A schema that validates `minLength` locally while advertising none of it
 *      to the model is the kind of drift that only shows up as a rejected request.
 *
 * Deliberately absent: `anyOf`, `oneOf`, `$ref`, formats, and numeric `multipleOf`. A
 * subset is a subset because it can be read in one sitting, and every feature left out is
 * one fewer way for the two halves to diverge.
 */

export type SchemaType = 'string' | 'number' | 'boolean' | 'array' | 'object'

export interface JsonSchema {
  type: SchemaType
  description?: string
  enum?: readonly string[]
  minLength?: number
  maxLength?: number
  minimum?: number
  maximum?: number
  maxItems?: number
  minItems?: number
  required?: readonly string[]
  properties?: Readonly<Record<string, JsonSchema>>
  items?: JsonSchema
  additionalProperties?: boolean
}

/** One thing wrong with a value, located precisely enough to be quoted back at the model. */
export interface ValidationIssue {
  /** `items[2].bn`, or the empty string for the root. */
  path: string
  message: string
}

/** Renders a path the way the issues themselves do, so a missing key reads consistently. */
const join = (path: string, key: string): string => (path === '' ? key : `${path}.${key}`)

const joinIndex = (path: string, index: number): string => `${path}[${index}]`

/**
 * Validates `value` against `schema`, collecting everything wrong with it.
 *
 * Order is stable and depth-first, so the same bad output always produces the same message
 * list. That matters more than it sounds: the list goes back to the model, and a retry whose
 * instructions differ between runs is a retry nobody can debug.
 */
export function validate(schema: JsonSchema, value: unknown, path = ''): ValidationIssue[] {
  const issues: ValidationIssue[] = []

  if (!matchesType(schema.type, value)) {
    // Reported on its own and not descended into: telling a model that
    // `items[2].bn` is a number when `items[2]` is a string is noise, and the fix is at the
    // outer value.
    return [{ path, message: `expected ${schema.type}, got ${describe(value)}` }]
  }

  switch (schema.type) {
    case 'object': {
      const record = value as Record<string, unknown>

      for (const key of schema.required ?? []) {
        if (record[key] === undefined) {
          issues.push({ path: join(path, key), message: 'is required but missing' })
        }
      }

      for (const [key, child] of Object.entries(schema.properties ?? {})) {
        if (record[key] !== undefined) {
          issues.push(...validate(child, record[key], join(path, key)))
        }
      }

      // Unknown keys are dropped rather than refused by default. A model that adds a
      // helpful extra field has still done the job, and refusing the whole call over it
      // would spend the one retry on nothing. A caller that wants strictness says so.
      if (schema.additionalProperties === false) {
        for (const key of Object.keys(record)) {
          if (!(key in (schema.properties ?? {}))) {
            issues.push({ path: join(path, key), message: 'is not an expected key' })
          }
        }
      }
      break
    }

    case 'array': {
      const items = value as unknown[]
      const min = schema.minItems ?? 0
      const max = schema.maxItems ?? Number.POSITIVE_INFINITY

      // Array length is checked here rather than relying on `max_tokens` to bound it. A
      // model asked for five suggestions has no reason to return four; when it does, the
      // fix is to ask again, and the retry needs to know the count was wrong.
      if (items.length < min) {
        issues.push({ path, message: `needs at least ${min} item(s), got ${items.length}` })
      }
      if (items.length > max) {
        issues.push({ path, message: `allows at most ${max} item(s), got ${items.length}` })
      }

      if (schema.items) {
        // Every item is validated, not just the first. Stopping early would let a bad
        // fifth sentence through on the strength of a good first one, which is exactly the
        // output that gets pasted onto a live page.
        items.forEach((item, index) => {
          issues.push(...validate(schema.items as JsonSchema, item, joinIndex(path, index)))
        })
      }
      break
    }

    case 'string': {
      const text = value as string

      if (schema.enum && !schema.enum.includes(text)) {
        issues.push({ path, message: `must be one of ${schema.enum.join(', ')}` })
      }
      if (schema.minLength !== undefined && text.length < schema.minLength) {
        issues.push({ path, message: `must be at least ${schema.minLength} character(s)` })
      }
      if (schema.maxLength !== undefined && text.length > schema.maxLength) {
        issues.push({ path, message: `must be at most ${schema.maxLength} character(s)` })
      }
      break
    }

    case 'number': {
      const num = value as number
      if (schema.minimum !== undefined && num < schema.minimum) {
        issues.push({ path, message: `must be ${schema.minimum} or more` })
      }
      if (schema.maximum !== undefined && num > schema.maximum) {
        issues.push({ path, message: `must be ${schema.maximum} or less` })
      }
      break
    }

    case 'boolean':
      break
  }

  return issues
}

/** How a value is named in an error message. `null`, `array` and `object` are worth saying. */
function describe(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  return typeof value
}

function matchesType(type: SchemaType, value: unknown): boolean {
  switch (type) {
    case 'string':
      return typeof value === 'string'
    case 'number':
      // `NaN` is typeof number and satisfies every bound, so it has to be excluded here
      // rather than in the `number` case above - otherwise it passes validation and lands
      // in the database as a non-numeric-looking token.
      return typeof value === 'number' && Number.isFinite(value)
    case 'boolean':
      return typeof value === 'boolean'
    case 'array':
      return Array.isArray(value)
    case 'object':
      return typeof value === 'object' && value !== null && !Array.isArray(value)
  }
}

/**
 * Flattens the declaration into the JSON Schema object the provider expects.
 *
 * `description` survives because it is not decoration: a model writes to the field
 * descriptions, so `bn` described as "Bangla" and `en` described as "English" is what makes
 * the difference between two translations and one text copied twice. Anything not in the
 * subset above is dropped rather than passed through, since the provider would reject an
 * unknown keyword on some models and ignore it on others.
 */
export function toJsonSchema(schema: JsonSchema): Record<string, unknown> {
  const out: Record<string, unknown> = { type: schema.type }

  if (schema.description !== undefined) out.description = schema.description
  if (schema.enum !== undefined) out.enum = [...schema.enum]
  if (schema.minLength !== undefined) out.minLength = schema.minLength
  if (schema.maxLength !== undefined) out.maxLength = schema.maxLength
  if (schema.minimum !== undefined) out.minimum = schema.minimum
  if (schema.maximum !== undefined) out.maximum = schema.maximum
  if (schema.minItems !== undefined) out.minItems = schema.minItems
  if (schema.maxItems !== undefined) out.maxItems = schema.maxItems
  if (schema.required !== undefined) out.required = [...schema.required]
  if (schema.additionalProperties !== undefined) {
    out.additionalProperties = schema.additionalProperties
  }
  if (schema.properties) {
    const properties: Record<string, unknown> = {}
    for (const [key, child] of Object.entries(schema.properties)) {
      properties[key] = toJsonSchema(child)
    }
    out.properties = properties
  }
  if (schema.items !== undefined) out.items = toJsonSchema(schema.items)

  return out
}

/**
 * Renders issues as the instruction the retry sends back.
 *
 * Written as a list rather than prose because a model repairs a list more reliably than a
 * paragraph, and because the caller can log exactly what was sent without having to parse
 * English out of it.
 */
export function formatIssues(issues: readonly ValidationIssue[]): string {
  return issues
    .map((issue) => `- ${issue.path === '' ? '(root)' : issue.path} ${issue.message}`)
    .join('\n')
}

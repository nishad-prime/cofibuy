import { readdirSync, readFileSync, type Dirent } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parse } from '@vue/compiler-sfc'
import { describe, expect, it } from 'vitest'

/**
 * The storefront's wording comes from `t()`. That is only true by hand, and a hardcoded
 * string does not fail a build - it ships, and the operator who edits the wording in
 * `/admin/copy` cannot change it, with nothing on screen to say so. This test is what
 * makes the rule hold instead of decaying.
 *
 * It parses each template with the same compiler the app builds with rather than
 * matching text, so an interpolation, a bound attribute or a comment cannot be
 * mistaken for copy. Every violation is collected before asserting, because a guard
 * that reports one problem per run is a guard people stop running.
 */

const here = dirname(fileURLToPath(import.meta.url))
const srcRoot = join(here, '..')

/** Everything a customer can see. Admin is excluded on purpose - see `ALLOWED`. */
const CUSTOMER_DIRS = ['views/customer', 'components/customer']
const CUSTOMER_FILES = ['layouts/CustomerLayout.vue']

/**
 * Static attributes that put a literal string in front of a customer. Bound versions
 * (`:aria-label="t(...)"`) are not a violation: the check only reads static values.
 */
const TEXT_ATTRIBUTES = [
  'alt',
  'aria-label',
  'aria-placeholder',
  'aria-roledescription',
  'placeholder',
  'title',
]

/**
 * Strings that are deliberately not copy, allowed verbatim anywhere in a template.
 *
 * `C` is the wordmark in the customer header, the same literal the admin chrome uses.
 * It is a brand mark, not wording: it is not in the bundles, and deriving it from
 * `app.name` is not an option either - Bengali does not decompose, so the first code
 * point of a Bengali name renders as a bare consonant without its vowel sign.
 *
 * `01XXXXXXXXX` is the Bangladeshi mobile pattern shown in the two phone fields. It is
 * a format hint, not a sentence - there is no English or Bangla wording in it to
 * translate, and routing it through `t()` would only let someone break the format.
 */
const ALLOWED = new Set(['C', '01XXXXXXXXX'])

/** A letter of any script. Digits, punctuation and symbols are not prose. */
const HAS_LETTER = /\p{L}/u

function vueFiles(dir: string): string[] {
  let found: string[] = []
  let entries: Dirent[]
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return []
  }
  for (const entry of entries) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) found = found.concat(vueFiles(full))
    else if (entry.name.endsWith('.vue')) found.push(full)
  }
  return found
}

/** Template AST node types, from `@vue/compiler-core`. Named here so the intent reads. */
const enum Node {
  Element = 1,
  Text = 2,
  Attribute = 6,
}

interface AstNode {
  type: number
  loc?: { start: { line: number } }
  tag?: string
  content?: string
  children?: AstNode[]
  branches?: AstNode[]
  props?: Array<{ type: number; name?: string; value?: { content: string } }>
}

function collect(nodes: AstNode[] | undefined, out: AstNode[]): void {
  for (const node of nodes ?? []) {
    out.push(node)
    collect(node.children, out)
    collect(node.branches, out)
  }
}

interface Scan {
  violations: string[]
  /** Allowlist entries actually seen, so a stale entry can be reported. */
  allowed: string[]
}

function scan(file: string): Scan {
  const rel = relative(srcRoot, file).replace(/\\/g, '/')
  const { descriptor, errors } = parse(readFileSync(file, 'utf8'), { filename: file })

  // A template that does not compile cannot be scanned, and silently passing here
  // would let a broken file count as clean.
  if (errors.length > 0) {
    return { violations: [`${rel}: template did not parse (${errors[0]?.message})`], allowed: [] }
  }
  if (!descriptor.template) return { violations: [], allowed: [] }

  const nodes: AstNode[] = []
  collect(descriptor.template.ast?.children as unknown as AstNode[], nodes)

  const violations: string[] = []
  const allowed: string[] = []

  const check = (literal: string, where: string): void => {
    if (ALLOWED.has(literal)) {
      allowed.push(literal)
      return
    }
    violations.push(`${rel}:${where} "${literal}" should come from t()`)
  }

  for (const node of nodes) {
    const line = node.loc?.start.line ?? 0

    if (node.type === Node.Text && node.content && HAS_LETTER.test(node.content)) {
      // `{{ ... }}` is the interpolated part, and a string that is nothing else is
      // how a value is rendered without a key.
      const literal = node.content.replace(/\{\{[\s\S]*?\}\}/g, '').trim()
      if (HAS_LETTER.test(literal)) {
        check(literal, `${line} text`)
      }
    }

    if (node.type === Node.Element) {
      for (const attr of node.props ?? []) {
        if (attr.type !== Node.Attribute) continue
        const name = attr.name ?? ''
        if (!TEXT_ATTRIBUTES.includes(name)) continue
        const value = attr.value?.content ?? ''
        if (!HAS_LETTER.test(value)) continue
        check(value, `${line} <${node.tag} ${name}>`)
      }
    }
  }

  return { violations, allowed }
}

function customerTemplates(): string[] {
  return [
    ...CUSTOMER_DIRS.flatMap((dir) => vueFiles(join(srcRoot, dir))),
    ...CUSTOMER_FILES.map((file) => join(srcRoot, file)),
  ]
}

describe('customer copy is translated, not hardcoded', () => {
  it('has no raw user-visible strings in a customer template', () => {
    const files = customerTemplates()

    // Guards against the guard: an empty file set would make every assertion below
    // pass without looking at anything.
    expect(files.length).toBeGreaterThan(0)
    expect(files.flatMap((file) => scan(file).violations)).toEqual([])
  })

  it('has no allowlist entry that is no longer used', () => {
    // An allowlist entry nobody needs is a loophole with a comment attached. This fails
    // the moment the string becomes a `t()` call, at which point it should be deleted
    // rather than left to quietly excuse whatever is written there next.
    const used = new Set(customerTemplates().flatMap((file) => scan(file).allowed))
    expect([...ALLOWED].filter((value) => !used.has(value))).toEqual([])
  })
})

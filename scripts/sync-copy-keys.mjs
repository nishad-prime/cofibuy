/**
 * Copies the app-side copy registry into the SQL mirror.
 *
 * `private.copy_registry` is the database's answer to two questions the app is the
 * only authority on: which keys may be edited at all, and which of those may be
 * stored as markdown. The database cannot import a TypeScript file and still refuse
 * an unknown key, so the list is mirrored here - once, as rows, so the two questions
 * cannot be answered inconsistently by two separately generated arrays.
 *
 * The block is found by sentinel comments rather than by parsing SQL. An earlier
 * version searched for `create or replace function ...` followed by
 * `select array[`, which is a fragile thing to depend on: it silently read only the
 * first namespace of `COPY_KEYS`, and it computed splice offsets against the
 * original text while writing into a copy, so a two-block file corrupted itself.
 *
 *   npm run copy:keys:sync
 *   npm run copy:keys:check   # what CI runs
 *
 * Plain .mjs on purpose: this runs under bare node before any build step, so it must
 * not depend on the TypeScript toolchain being up.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const migration = join(here, '..', 'supabase', 'migrations', '20261004130000_copy_registry.sql')
const registry = join(here, '..', 'src', 'config', 'copyKeys.ts')

const BEGIN = '-- copy-registry:begin'
const END = '-- copy-registry:end'

/**
 * Drop comments before looking for quoted strings.
 *
 * Necessary because the registry's declarations are commented, and English comments
 * contain apostrophes - "the registry's contract" parses as the string
 * `'s contract'` and lands in the SQL as a key. Stripping is the fix; avoiding
 * apostrophes in prose would only postpone the same corruption to the next comment.
 */
function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
}

/**
 * Read the registry as `{ key, markdown }` pairs.
 *
 * Keys are read straight out of the source rather than imported. Node can strip types
 * from a `.ts` import, but not depending on the loader's behaviour across versions is
 * worth more than the convenience - and both declarations are plain string data.
 */
function readRegistry() {
  const source = stripComments(readFileSync(registry, 'utf8'))

  const keysLiteral = source.indexOf('export const COPY_KEYS')
  if (keysLiteral === -1) throw new Error('COPY_KEYS not found in src/config/copyKeys.ts')
  const keysEnd = source.indexOf('} as const satisfies', keysLiteral)
  if (keysEnd === -1) throw new Error('could not find the end of the COPY_KEYS literal')

  const allowedAt = source.indexOf('const MARKDOWN_ALLOWED')
  if (allowedAt === -1) throw new Error('MARKDOWN_ALLOWED not found in src/config/copyKeys.ts')
  const allowedEnd = source.indexOf('] as const satisfies', allowedAt)
  if (allowedEnd === -1) throw new Error('could not find the end of the MARKDOWN_ALLOWED literal')

  const keys = [...source.slice(keysLiteral, keysEnd).matchAll(/'([^']+)'/g)].map((m) => m[1])
  const allowed = new Set(
    [...source.slice(allowedAt, allowedEnd).matchAll(/'([^']+)'/g)].map((m) => m[1]),
  )

  if (keys.length === 0) throw new Error('COPY_KEYS contained no keys')
  return keys.map((key) => ({ key, markdown: allowed.has(key) }))
}

function buildBlock(entries) {
  const rows = entries.map((e) => `  ('${e.key}', ${e.markdown})`).join(',\n')
  return `insert into private.copy_registry (key, markdown_allowed) values\n${rows};`
}

/**
 * The region between the sentinels, exclusive.
 *
 * The markers themselves are hand-written and never replaced. Splicing them into the
 * generated text - the first attempt did - means one run deletes the markers and the
 * next run cannot find them.
 */
function region(source) {
  const from = source.indexOf(BEGIN)
  if (from === -1) throw new Error(`${BEGIN} not found in the migration`)

  const fromEnd = from + BEGIN.length
  const to = source.indexOf(END, fromEnd)
  if (to === -1) throw new Error(`${END} not found in the migration`)

  return { fromEnd, to, text: source.slice(fromEnd, to) }
}

function currentBlock(source) {
  return region(source).text
}

/** Report what differs, so a stale mirror says which key moved rather than just that it did. */
function report(entries, block) {
  const sqlKeys = [...block.matchAll(/\('([^']+)',\s*(true|false)\)/g)].map((m) => ({
    key: m[1],
    markdown: m[2] === 'true',
  }))

  const appByKey = new Map(entries.map((e) => [e.key, e.markdown]))
  const sqlByKey = new Map(sqlKeys.map((e) => [e.key, e.markdown]))

  for (const [key, markdown] of appByKey) {
    if (!sqlByKey.has(key)) console.error(`  in copyKeys.ts but not SQL: ${key}`)
    else if (sqlByKey.get(key) !== markdown) {
      console.error(
        `  markdown_allowed differs for ${key}: app=${markdown} sql=${sqlByKey.get(key)}`,
      )
    }
  }
  for (const key of sqlByKey.keys()) {
    if (!appByKey.has(key)) console.error(`  in SQL but not in copyKeys.ts: ${key}`)
  }

  return appByKey.size === sqlByKey.size && entries.every((e) => sqlByKey.get(e.key) === e.markdown)
}

function main() {
  const check = process.argv.includes('--check')
  const entries = readRegistry()
  const source = readFileSync(migration, 'utf8')
  const expected = `\n${buildBlock(entries)}\n`

  if (currentBlock(source) === expected) {
    console.log(
      `copy key mirror is up to date (${entries.length} keys, ${entries.filter((e) => e.markdown).length} markdown-capable)`,
    )
    return
  }

  if (check) {
    console.error('copy key mirror is stale')
    report(entries, currentBlock(source))
    console.error('  run: npm run copy:keys:sync')
    process.exit(1)
  }

  const { fromEnd, to } = region(source)
  writeFileSync(migration, source.slice(0, fromEnd) + expected + source.slice(to), 'utf8')
  console.log(`updated ${entries.length} keys in ${migration}`)
}

main()

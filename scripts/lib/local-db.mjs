/**
 * The local PostgreSQL both `test-db.mjs` and `generate-types.mjs` run against.
 *
 * The Supabase CLI wants Docker, and a project wants a network round trip. An
 * in-process cluster built from the same migrations is neither, so the database
 * suite and the generated types cannot disagree about what the schema is.
 */
import { existsSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import EmbeddedPostgres from 'embedded-postgres'

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
export const migrationsDir = join(root, 'supabase', 'migrations')
export const testsDir = join(root, 'supabase', 'tests')

const DATA_DIR = join(root, '.tmp', 'pgdata')
const PORT = Number(process.env.PGTEST_PORT ?? 55_433)

/**
 * Splits a SQL file into statements, ignoring dollar-quoted bodies and comments.
 *
 * Hand-rolled because there is no SQL parser in the toolchain, and a driver
 * cannot take a multi-statement string in this configuration.
 */
export function splitStatements(sql) {
  const statements = []
  let current = ''
  let inSingle = false
  let inLineComment = false
  let inBlockComment = false
  let dollarTag = null

  for (let i = 0; i < sql.length; i++) {
    const char = sql[i]
    const next = sql[i + 1]

    if (inLineComment) {
      current += char
      if (char === '\n') inLineComment = false
      continue
    }

    if (inBlockComment) {
      current += char
      if (char === '*' && next === '/') {
        current += next
        i++
        inBlockComment = false
      }
      continue
    }

    if (dollarTag) {
      current += char
      if (char === '$' && sql.startsWith(dollarTag, i)) {
        current += sql.slice(i + 1, i + dollarTag.length)
        i += dollarTag.length - 1
        dollarTag = null
      }
      continue
    }

    if (!inSingle && char === '-' && next === '-') {
      inLineComment = true
      current += char
      continue
    }

    if (!inSingle && char === '/' && next === '*') {
      inBlockComment = true
      current += char + next
      i++
      continue
    }

    if (char === "'") {
      // A doubled quote is an escaped quote, not the end of the string. Without
      // this, `'... ''proofs'''` closes and reopens three times and swallows the
      // rest of the file, which surfaces as a syntax error on a bare `)`.
      if (inSingle && next === "'") {
        current += char + next
        i++
        continue
      }
      inSingle = !inSingle
      current += char
      continue
    }

    if (!inSingle && char === '$') {
      const match = /^\$[A-Za-z_]*\$/.exec(sql.slice(i))
      if (match) {
        dollarTag = match[0]
        current += dollarTag
        i += dollarTag.length - 1
        continue
      }
    }

    if (char === ';' && !inSingle) {
      const trimmed = current.trim()
      if (trimmed.length > 0) statements.push(trimmed)
      current = ''
      continue
    }

    current += char
  }

  const tail = current.trim()
  if (tail.length > 0) statements.push(tail)
  return statements
}

/** Runs one file, reporting which statement failed rather than a bare code. */
export async function applyFile(client, file) {
  const sql = readFileSync(file, 'utf8')
  const statements = splitStatements(sql)
  let applied = 0

  for (const statement of statements) {
    try {
      await client.query(statement)
      applied++
    } catch (error) {
      const relative = file.replace(`${root}/`, '')
      throw new Error(
        `${relative}\n\nStatement ${applied + 1} failed:\n${statement}\n\n${error.message}`,
        { cause: error },
      )
    }
  }

  return applied
}

export function listMigrations() {
  if (!existsSync(migrationsDir)) return []
  return readdirSync(migrationsDir)
    .filter((name) => name.endsWith('.sql'))
    .sort()
    .map((name) => join(migrationsDir, name))
}

/**
 * Starts a cluster with the environment shim applied, and hands back the client.
 *
 * The shim stands in for the Supabase-managed schemas (`auth`, `storage`) that
 * the migrations expect to exist and that a fresh database has none of. The
 * migrations themselves are left to the caller, which usually wants to report
 * them as it goes.
 */
export async function startDatabase({ onLog } = {}) {
  const sysrootLib = join(root, '.tmp', 'sysroot', 'usr', 'lib', 'x86_64-linux-gnu')
  if (existsSync(sysrootLib)) {
    process.env.LD_LIBRARY_PATH = [sysrootLib, process.env.LD_LIBRARY_PATH]
      .filter(Boolean)
      .join(':')
  }

  // A crashed or killed run leaves the cluster directory behind, and `initdb`
  // refuses to start on a directory that already exists and is not empty. That
  // turned one interrupted test run into a hard failure for every run after it,
  // with an error about the data directory rather than about the crash. The
  // cluster is disposable and `persistent: false` means nothing here is worth
  // keeping, so a leftover is always safe to clear.
  rmSync(DATA_DIR, { recursive: true, force: true })

  const pg = new EmbeddedPostgres({
    databaseDir: DATA_DIR,
    user: 'postgres',
    password: 'postgres',
    port: PORT,
    persistent: false,
    initdbFlags: ['--encoding=UTF8', '--locale=C'],
    postgresFlags: ['-c', 'log_min_messages=warning'],
    // The server is chatty about start and shutdown; only surface it on request.
    onLog: (message) => {
      if (process.env.PGTEST_VERBOSE && onLog) onLog(message)
    },
    onError: (message) => {
      if (process.env.PGTEST_VERBOSE && onLog) onLog(String(message))
    },
  })

  await pg.initialise()
  await pg.start()

  const client = pg.getPgClient()
  client.on('notice', (notice) => onLog?.(notice.message))
  await client.connect()

  // Mirrors a Supabase project, where pgcrypto lives in the `extensions` schema
  // and our SQL qualifies it as extensions.crypt(...).
  await client.query('create schema if not exists extensions')
  await client.query('create extension if not exists pgcrypto with schema extensions')

  await applyFile(client, join(testsDir, '00_environment.sql'))

  return { pg, client }
}

export async function stopDatabase({ pg, client }) {
  try {
    if (client && !client.ended) await client.end()
  } catch {
    // The cluster is going away regardless; a failed disconnect is noise.
  }
  try {
    if (pg) await pg.stop()
  } catch {
    // Same here: report the result, not the teardown.
  }
}

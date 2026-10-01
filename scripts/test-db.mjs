/**
 * Local database test runner.
 *
 * `supabase test db` needs Docker, which is not always available. This runner
 * executes the *same* migrations and the *same* test files against a real
 * PostgreSQL started in-process by `embedded-postgres`, so the database suite
 * is runnable anywhere Node is.
 *
 *   node scripts/test-db.mjs              run migrations then the test suite
 *   node scripts/test-db.mjs --keep       leave the cluster running afterwards
 *   node scripts/test-db.mjs --migrate    apply migrations and stop
 *
 * pgtap is used when installed. When it is not, `supabase/tests/_pgtap_shim.sql`
 * supplies the same assertion surface, so a test file is written once.
 */
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import EmbeddedPostgres from 'embedded-postgres'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const migrationsDir = join(root, 'supabase', 'migrations')
const testsDir = join(root, 'supabase', 'tests')

const DATA_DIR = join(root, '.tmp', 'pgdata')
const PORT = Number(process.env.PGTEST_PORT ?? 55_433)
const KEEP = process.argv.includes('--keep')
const MIGRATE_ONLY = process.argv.includes('--migrate')

// The bundled PostgreSQL build links against these, and a minimal container may
// not have them. A locally extracted copy under .tmp/sysroot is used if present.
const sysrootLib = join(root, '.tmp', 'sysroot', 'usr', 'lib', 'x86_64-linux-gnu')
if (existsSync(sysrootLib)) {
  process.env.LD_LIBRARY_PATH = [sysrootLib, process.env.LD_LIBRARY_PATH].filter(Boolean).join(':')
}

const bold = (s) => `[1m${s}[0m`
const dim = (s) => `[2m${s}[0m`
const red = (s) => `[31m${s}[0m`
const green = (s) => `[32m${s}[0m`

function listFiles(dir, suffix) {
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter((name) => name.endsWith(suffix))
    .sort()
    .map((name) => join(dir, name))
}

// Files prefixed with `_` are support, not tests: fixtures and the assertion
// shim. They are applied once, outside the per-file transaction, and never
// reported as passing suites of their own.
const isSupport = (file) => file.split('/').pop().startsWith('_')
const isEnvironment = (file) => file.endsWith('00_environment.sql')

let pg

/** Splits a SQL file into statements, ignoring dollar-quoted bodies and comments. */
function splitStatements(sql) {
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

async function applyFile(client, file) {
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

async function bootstrap(client) {
  console.log(dim('  applying test environment shim'))
  await applyFile(client, join(testsDir, '00_environment.sql'))
}

async function migrate(client) {
  const files = listFiles(migrationsDir, '.sql')
  if (files.length === 0) throw new Error('no migrations found')

  for (const file of files) {
    const count = await applyFile(client, file)
    console.log(dim(`  ${file.replace(`${root}/`, '')}  (${count} statements)`))
  }
}

/** @returns {Promise<boolean>} whether the compatibility shim is in use */
async function installShimIfNeeded(client) {
  const { rows } = await client.query(
    `select count(*)::int as n from pg_available_extensions where name = 'pgtap'`,
  )
  const available = rows[0].n > 0

  if (available) {
    await client.query('create extension if not exists pgtap')
    console.log(dim('  using the real pgtap extension'))
    return false
  }

  await applyFile(client, join(testsDir, '_pgtap_shim.sql'))
  console.log(dim('  pgtap unavailable, using the compatibility shim'))
  return true
}

// Session-level defaults, not transaction-local. A file's own `test_data.as_user`
// calls are transaction-local and revert at the end, so the next file starts from
// these instead of inheriting the previous file's identity.
async function impersonate(client, { userId, role, email }) {
  await client.query('select set_config($1, $2, false)', ['request.jwt.claim.sub', userId ?? ''])
  await client.query('select set_config($1, $2, false)', ['request.jwt.claim.role', role ?? 'anon'])
  await client.query('select set_config($1, $2, false)', ['request.jwt.claim.email', email ?? ''])
}

async function runTestFile(client, file, { useShim }) {
  const sql = readFileSync(file, 'utf8')
  const relative = file.replace(`${root}/`, '')
  const name = relative.split('/').pop()

  await client.query('begin')
  if (useShim) await client.query('select _shim_reset()')

  // A savepoint, so a failing statement only aborts this file rather than the
  // whole run. Without one, the first `finish()` that raises would poison the
  // transaction and no later file could even be read for reporting.
  await client.query('savepoint test_file')

  let failure = null
  let assertions = 0

  try {
    const statements = splitStatements(sql)
    for (const [index, statement] of statements.entries()) {
      try {
        await client.query(statement)
      } catch (error) {
        // Report the failing statement, not just its message: a bare SQLSTATE
        // from a test file is otherwise impossible to act on.
        error.message = `Statement ${index + 1} of ${statements.length}:\n${statement}\n\n${error.message}`
        throw error
      }
    }
  } catch (error) {
    failure = error
  }

  // Clears the aborted state, but only when something failed: rolling back to the
  // savepoint would also discard the assertions the file had recorded so far. A
  // failed file's message already carries the report, so losing the tally is fine.
  if (failure) await client.query('rollback to savepoint test_file')

  if (useShim) {
    const { rows } = await client.query(
      `select
         count(*) filter (where kind <> all (array['diag', 'note']))::int as assertions,
         count(*) filter (where kind <> all (array['diag', 'note']) and not ok)::int as failed
       from _shim_results`,
    )
    assertions = rows[0].assertions
    if (!failure && rows[0].failed > 0) {
      // A file that never called `finish()` still has failures worth reading.
      const {
        rows: [report],
      } = await client.query('select _shim_report() as report')
      failure = {
        message: `${rows[0].failed} assertion(s) failed`,
        detail: report.report ?? null,
      }
    }
  }

  await client.query('rollback')

  return { name, failure, assertions }
}

async function main() {
  console.log(bold('\ncofibuy database suite'))

  pg = new EmbeddedPostgres({
    databaseDir: DATA_DIR,
    user: 'postgres',
    password: 'postgres',
    port: PORT,
    persistent: false,
    initdbFlags: ['--encoding=UTF8', '--locale=C'],
    postgresFlags: ['-c', 'log_min_messages=warning'],
    // The server is chatty about start and shutdown; only surface it on request.
    onLog: (message) => {
      if (process.env.PGTEST_VERBOSE) process.stderr.write(message)
    },
    onError: (message) => {
      if (process.env.PGTEST_VERBOSE) process.stderr.write(String(message))
    },
  })

  console.log(dim('  starting an ephemeral PostgreSQL'))
  await pg.initialise()
  await pg.start()

  const client = pg.getPgClient()

  // Notices are how the shim's `diag` reports commentary. Collected per file and
  // printed alongside it, which also works when the file failed: the table of
  // results would be unreadable by then.
  let notices = []
  client.on('notice', (notice) => notices.push(notice.message))
  await client.connect()

  // Mirrors a Supabase project, where pgcrypto lives in the `extensions` schema
  // and our SQL qualifies it as extensions.crypt(...).
  await client.query('create schema if not exists extensions')
  await client.query('create extension if not exists pgcrypto with schema extensions')

  let exitCode = 0

  try {
    await bootstrap(client)
    await migrate(client)

    if (MIGRATE_ONLY) {
      console.log(green('\n  migrations applied cleanly\n'))
      await client.end()
      if (!KEEP) await pg.stop()
      return
    }

    const useShim = await installShimIfNeeded(client)

    const all = listFiles(testsDir, '.sql').filter((file) => !isEnvironment(file))

    for (const file of all.filter(isSupport)) {
      await applyFile(client, file)
    }

    const files = all.filter((file) => !isSupport(file))

    if (files.length === 0) throw new Error('no test files found')

    console.log(bold(`\n  running ${files.length} test file(s)\n`))

    for (const file of files) {
      // Each file gets a clean identity context.
      await impersonate(client, { role: 'anon' })
      notices = []
      const result = await runTestFile(client, file, { useShim })
      const { name, failure, assertions } = result

      for (const note of notices) {
        console.log(dim(`        · ${note}`))
      }

      if (failure) {
        exitCode = 1
        console.log(`  ${red('FAIL')}  ${name}`)
        // pg_errors carry a DETAIL line; the shim puts its report there. Without
        // it a failure is just a count, which is not enough to act on.
        const detail = failure.detail ? `\n${failure.detail}` : ''
        console.log(
          [failure.message, detail]
            .join('')
            .split('\n')
            .map((line) => `        ${line}`)
            .join('\n'),
        )
      } else {
        const suffix = useShim && assertions > 0 ? dim(`  ${assertions} assertions`) : ''
        console.log(`  ${green('PASS')}  ${name}${suffix}`)
      }
    }
  } catch (error) {
    exitCode = 1
    console.error(`\n${red('ERROR')}  ${error.message}\n`)
  } finally {
    if (!KEEP) {
      try {
        if (!client.ended) await client.end()
      } catch {
        // The cluster is going away regardless; a failed disconnect is noise.
      }
      try {
        await pg.stop()
      } catch {
        // Same here: report the test result, not the teardown.
      }
    } else {
      console.log(dim(`\n  cluster left running on port ${PORT} (--keep)\n`))
    }
  }

  process.exit(exitCode)
}

await main()

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
import { readFileSync, readdirSync } from 'node:fs'
import { join, resolve } from 'node:path'
import {
  applyFile,
  listMigrations as listMigrationsFromDisk,
  splitStatements,
  startDatabase,
  testsDir,
} from './lib/local-db.mjs'

const root = resolve(import.meta.dirname, '..')
const KEEP = process.argv.includes('--keep')
const MIGRATE_ONLY = process.argv.includes('--migrate')

const bold = (s) => `\u001b[1m${s}\u001b[0m`
const dim = (s) => `\u001b[2m${s}\u001b[0m`
const red = (s) => `\u001b[31m${s}\u001b[0m`
const green = (s) => `\u001b[32m${s}\u001b[0m`

// Files prefixed with `_` are support, not tests: fixtures and the assertion
// shim. They are applied once, outside the per-file transaction, and never
// reported as passing suites of their own.
const isSupport = (file) => file.split('/').pop().startsWith('_')
const isEnvironment = (file) => file.endsWith('00_environment.sql')

let pg

async function migrate(client) {
  const files = listMigrationsFromDisk()
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

  // Notices are how the shim's `diag` reports commentary. Collected per file and
  // printed alongside it, which also works when the file failed: the table of
  // results would be unreadable by then.
  let notices = []
  console.log(dim('  starting an ephemeral PostgreSQL'))

  const database = await startDatabase({ onLog: (message) => notices.push(String(message)) })
  pg = database.pg
  const client = database.client

  let exitCode = 0

  try {
    await migrate(client)

    if (MIGRATE_ONLY) {
      console.log(green('\n  migrations applied cleanly\n'))
      await client.end()
      if (!KEEP) await pg.stop()
      return
    }

    const useShim = await installShimIfNeeded(client)

    const all = readdirSync(testsDir)
      .filter((name) => name.endsWith('.sql') && !isEnvironment(name))
      .sort()
      .map((name) => join(testsDir, name))

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
      console.log(dim(`\n  cluster left running for inspection (--keep)\n`))
    }
  }

  process.exit(exitCode)
}

await main()

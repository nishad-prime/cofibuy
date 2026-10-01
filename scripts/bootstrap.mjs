/**
 * Pre-flight check: is this checkout able to run?
 *
 * Answers "why is nothing working" without reading three config files. Every
 * check prints the exact command that fixes it, because a setup script that only
 * says "not configured" makes the reader go looking.
 *
 * Exits non-zero when the app cannot reach a database, since `vite` will boot
 * happily and then fail on the first real request.
 */
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { root } from './lib/local-db.mjs'

const REQUIRED_NODE_MAJOR = 22
const ENV_FILES = ['.env.local', '.env']

const bold = (s) => `\u001b[1m${s}\u001b[0m`
const dim = (s) => `\u001b[2m${s}\u001b[0m`
const red = (s) => `\u001b[31m${s}\u001b[0m`
const green = (s) => `\u001b[32m${s}\u001b[0m`
const yellow = (s) => `\u001b[33m${s}\u001b[0m`

const results = []
const record = (level, label, detail) => results.push({ level, label, detail })

/** Reads a `.env` file without depending on the process environment. */
function readEnvFile(name) {
  const path = join(root, name)
  if (!existsSync(path)) return null

  const values = {}
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line)
    if (!match) continue
    values[match[1]] = match[2].trim().replace(/^["']|["']$/g, '')
  }
  return values
}

const nodeMajor = Number(process.versions.node.split('.')[0])
if (nodeMajor >= REQUIRED_NODE_MAJOR) {
  record('ok', `Node ${process.versions.node}`, 'satisfies engines.node')
} else {
  record('fail', `Node ${process.versions.node}`, `needs >= ${REQUIRED_NODE_MAJOR}`)
}

if (existsSync(join(root, 'node_modules'))) {
  record('ok', 'dependencies installed', 'npm ci')
} else {
  record('fail', 'dependencies missing', 'npm ci')
}

if (existsSync(join(root, 'supabase', 'config.toml'))) {
  record('ok', 'supabase/config.toml', 'local stack and db push will work')
} else {
  record('fail', 'supabase/config.toml missing', 'npx supabase init')
}

const migrations = join(root, 'supabase', 'migrations')
if (existsSync(migrations)) {
  const count = readdirSync(migrations).filter((name) => name.endsWith('.sql')).length
  record('ok', `${count} migration(s)`, 'supabase db push applies these')
}

if (existsSync(join(root, 'src', 'lib', 'database.types.ts'))) {
  record('ok', 'database.types.ts', 'npm run db:types regenerates it')
}

// The app reads these through Vite, so they can come from .env.local or from the
// shell. Either is fine; having neither is the failure worth catching.
const envFiles = ENV_FILES.map(readEnvFile).filter(Boolean)
const missing = ['VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY'].filter((key) => {
  const inFile = envFiles.some((file) => file[key])
  return !inFile && !process.env[key]
})

if (missing.length === 0) {
  const where =
    envFiles.length > 0
      ? envFiles.map((f) => ENV_FILES[envFiles.indexOf(f)]).join(', ')
      : 'process environment'
  record('ok', 'Supabase URL and anon key', `from ${where}`)
} else {
  record(
    'fail',
    `${missing.join(' and ')} not set`,
    `cp .env.example ${ENV_FILES[0]} and fill it in`,
  )
}

// Not fatal: the checkout can be used for tests and typechecking without a
// project, which is most of what CI does.
if (!existsSync(join(root, 'supabase', 'seed.sql'))) {
  record('warn', 'supabase/seed.sql missing', 'no demo gateway, link or first owner')
}

console.log(bold('\ncofibuy setup check\n'))

for (const { level, label, detail } of results) {
  const mark = level === 'ok' ? green('ok  ') : level === 'warn' ? yellow('warn') : red('fail')
  console.log(`  ${mark}  ${label.padEnd(28)} ${dim(detail)}`)
}

const failed = results.filter((r) => r.level === 'fail')

if (failed.length > 0) {
  console.log(`\n  ${failed.length} thing(s) to fix. Full walkthrough in README.md.\n`)
  process.exit(1)
}

console.log(
  `\n  ${green('ready.')} npm run dev, then apply the migrations:\n` +
    `    ${dim('npx supabase link --project-ref <ref>   # once, for a hosted project')}\n` +
    `    ${dim('npx supabase db push')}\n`,
)

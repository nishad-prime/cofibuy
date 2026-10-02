# Cofibuy

A static-first paywall for selling a single file or link per order, paid by hand
through bKash, Nagad or bank transfer in Bangladesh. There is no payment
processor: the customer sends money to an account number, uploads proof, and a
human approves it.

Bilingual customer-facing (Bangla and English), English-only admin. The customer
pages are static HTML that poll for order status; the database owns every rule
that matters.

**Status: the database is finished and tested. The customer and admin interfaces
are now implemented and functional** — the app includes customer checkout/recovery
flows and a full admin interface for managing links, gateways, orders, team, and
settings. The Telegram OTP worker remains in a separate repository (worker RPCs
exist in the schema).

## Requirements

- Node 22 or newer (`engines.node` in `package.json`)
- A Supabase project. The local stack needs Docker; everything else does not.

The Supabase CLI is already a devDependency, so `npx supabase ...` works without
installing anything globally. `psql` is not needed for anything documented here.

## Quick start

```bash
npm ci
cp .env.example .env.local      # then fill in the two values
npm run bootstrap               # tells you what is still missing
npx supabase link --project-ref <your-project-ref>
npx supabase db push            # applies supabase/migrations/
npm run dev
```

`npx supabase link` asks for the project's **database password** (Dashboard →
Settings → Database), not the anon key. It is a one-time step and the result is
remembered in `supabase/.temp`, which is gitignored.

`npm run bootstrap` is a pre-flight check, not an installer. It prints what is
wrong and the command that fixes it, and exits non-zero if the app could not
reach a database.

### Filling in `.env.local`

| Variable                 | Where to find it                                |
| ------------------------ | ----------------------------------------------- |
| `VITE_SUPABASE_URL`      | Project Settings → API → Project URL            |
| `VITE_SUPABASE_ANON_KEY` | Project Settings → API → anon / publishable key |

Both are safe in the browser. The anon key is constrained entirely by row level
security, which is what the database tests in `supabase/tests/07_rls.sql` exist
to prove. The other values in `.env.example` are server-side only and nothing in
this repository reads them yet.

If you put a privileged value in `.env.local` anyway, the build fails rather than
shipping it: `vite/plugins/guard-service-role.ts` refuses to start if a
`VITE_`-prefixed variable looks privileged, and refuses to emit a bundle
containing a service-role JWT.

### Expose the `api` schema

**This is the step that is easy to skip and hard to debug.** Every RPC lives in
the `api` schema, and PostgREST will not serve a schema it has not been told
about. Migrations grant `usage on schema api`, which is necessary and not
sufficient.

- Hosted: Project Settings → API → **Exposed schemas** → add `api`, so it reads
  `public, graphql_public, api`
- Local: already correct, see `schemas` in `supabase/config.toml`

Get this wrong and every call fails with a 404 on the function name while the
grants all look fine.

### Create the first admin

`api.admin_set_staff` refuses anyone who is not already an owner, so the first
owner cannot be created through the API. Use `supabase/seed.sql`, which creates
the first owner plus a demo gateway and a demo link:

- Local: `npx supabase db reset` runs it automatically
- Hosted: paste it into the dashboard's SQL editor, after changing the
  `v_owner_email` value at the top

```bash
# local stack, wipes and replays everything including the seed
npx supabase start
npx supabase db reset
npx supabase studio        # http://127.0.0.1:54323
```

### The local stack

```bash
npx supabase start         # needs Docker; prints the local keys
```

`supabase start` prints a local anon key and URL, which you can put in
`.env.local` to develop against the container instead of a hosted project.

To apply migrations to a hosted project by hand instead, the dashboard's SQL
editor works, but `npx supabase db push` is better: it records what it applied.

## Commands

| Command                        | What it does                                               |
| ------------------------------ | ---------------------------------------------------------- |
| `npm run dev`                  | Vite dev server on :5173                                   |
| `npm run build`                | typecheck, then production build                           |
| `npm run bootstrap`            | pre-flight check on the checkout                           |
| `npm run check`                | format, lint, typecheck, unit tests                        |
| `npm run check:all`            | `check` plus the database suite and the generated types    |
| `npm test`                     | Vitest unit tests                                          |
| `npm run test:db`              | database suite against an in-process PostgreSQL            |
| `npm run test:db -- --migrate` | apply the migrations and stop                              |
| `npm run test:db -- --keep`    | leave the cluster running to poke at it                    |
| `npm run format`               | Prettier, write                                            |
| `npm run db:types`             | regenerate `src/lib/database.types.ts` from the migrations |
| `npm run db:types:check`       | fail if the generated types are stale                      |
| `npx supabase start`           | local stack                                                |
| `npx supabase db reset`        | local stack: wipe, replay migrations, run seed             |
| `npx supabase db push`         | apply migrations to the linked project                     |
| `npx supabase studio`          | dashboard for the local stack                              |

`npm run test:db` needs neither Docker nor a project. It downloads nothing at run
time: `embedded-postgres` starts a real PostgreSQL in a child process, the
migrations are applied to it, and each test file runs in its own transaction
that is rolled back afterwards.

## How it fits together

```
src/                    Vue 3 + Tailwind 4 app
  lib/                  domain helpers, generated types, the Supabase client
  i18n/                 customer strings (bn + en), admin strings (en only)
  views/                one file per screen
supabase/
  config.toml           CLI config, including the exposed schema list
  migrations/           the schema, and every rule, in SQL
  seed.sql              first owner + demo gateway + demo link
  tests/                the database suite
scripts/
  bootstrap.mjs         pre-flight check
  generate-types.mjs    database.types.ts from the migrations
  test-db.mjs           the database suite runner
  lib/local-db.mjs      the ephemeral cluster both of the above start
```

The split worth knowing: **the database is the application.** Business rules live
in SQL and are reached through `api.*` functions; the Vue side renders and
submits. That is why the database suite is the larger half of the tests, and why
`api` functions return `jsonb` — the payloads are not typed by the generator.

### Rules that live in SQL, not in the UI

- Phone and reference-code normalisation, and TrxID normalisation for admin
  duplicate checks
- The minimum amount, and whether it is hidden. A customer who guesses below it
  gets an identical `below_minimum` answer whether or not they were right, and
  the sixth attempt locks the order
- One open order per user per link, enforced by an index rather than by a check
- Evidence rules: required fields, validator types, that a file path lives under
  `{user_id}/{order_id}/{field_key}/`, that it belongs to the submitting customer,
  and that evidence is append-only
- Recovery: bcrypt-only OTP codes, five wrong guesses consumes the challenge, a
  resend supersedes the previous code for that phone number

## Deploying

The build is a static bundle in `dist/`, so any static host works. Set the two
`VITE_*` variables at build time — they are inlined into the bundle, so changing
them requires a rebuild, not just a restart.

The database is applied with `npx supabase db push`. Do not run the seed against
production; it exists to get a local or preview project into a usable state.

## What remains

- The Telegram worker that sends recovery OTPs (`supabase/migrations/20260101000004_rpc_recovery.sql`
  has the customer and worker RPCs; the worker process itself is a separate
  repository that does not exist yet)
- Email sign-in screens (admin uses email/password; customer flow uses anonymous
  sign-ins as configured in `supabase/config.toml`)

The customer UI (link pages, checkout, evidence upload, status polling, recovery
flow) and full admin UI (queue, order review, links, gateways, team, settings) are
now implemented. All UI calls verified RPCs from the tested database layer.

## Deployment\n\n### Prerequisites\n\n- Supabase project\n- Static hosting\n- Node.js 22+\n\n### Quick Deploy\n\n\ash\nnpm ci\ncp .env.example .env.local\nnpm run build\n\\

\nDeploy dist/ to any static host. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY at build time.\n

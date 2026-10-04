# Roadmap

Five phases. This file exists because the plan used to live only in conversation,
which made it impossible to answer "how far along are we?" without reconstructing
it from git history.

Status legend: **done** / **partial** / **not started**.

## Phase 1 — Link index visibility

**Status: done.** `supabase/migrations/20261004100000_link_index_visibility.sql`
adds `paywall_links.is_listed`, so a link can be reachable by URL without
appearing in the public index. `api.list_public_links()` filters on it and RLS
carries the same predicate, so an unlisted link is not merely hidden from the
listing — it is unreachable through it.

## Phase 2 — Bilingual customer copy store

**Status: done.** An operator rewrites every customer-facing string from
`/admin/copy`, in both languages, without editing the bundle or rebuilding.

Delivered:

- `src/config/copyKeys.ts` — the single source of truth. `COPY_KEYS` lists the
  editable keys per namespace; `MARKDOWN_ALLOWED` lists the six standalone prose
  blocks that may contain markdown. `scripts/sync-copy-keys.mjs` mirrors both into
  `private.copy_registry` inside a migration between sentinels, and
  `npm run copy:keys:check` fails the build when they drift.
- `api.get_public_copy()` — public read, `security definer`, no table grant.
- `api.admin_copy()` / `api.admin_set_copy()` — owner-only. The setter raises on
  an unknown key and refuses markdown on anything that is not a prose block,
  which is why it validates against the table rather than a generated array.
- `src/composables/useCopyOverrides.ts` — fetches once, merges deep into
  vue-i18n's message store. Deep rather than shallow, because overrides arrive
  nested (`home.heading` becomes `{ home: { heading } }`) and a shallow spread of
  the `customer` branch would replace the whole bundled namespace with a one-key
  stub, blanking every sibling string.
- Bounded first paint. `FIRST_PAINT_BUDGET_MS` races the network; either outcome
  renders something correct. Accepted consequence: on a slow connection the
  customer may read the shipped wording briefly before it changes.
- `src/views/admin/CopyView.vue` and `src/components/CopyText.vue` — the editor
  and the render path for markdown-flagged keys.

Verified by `supabase/tests/09_copy.sql` (29 assertions) and
`src/composables/useCopyOverrides.test.ts` (19 tests).

## Phase 3 — Settings the browser can read, maintenance mode

**Status: not started.**

The blocker to design around: `public.site_settings` has RLS enabled with **zero
policies and zero grants**, and `api.admin_settings()` is owner-only. Nothing
global can reach the browser today. Any global flag needs a new public RPC,
modelled on `api.get_public_copy()`.

Planned:

- `api.get_public_settings()` returning only customer-safe fields. Never owner or
  staff data.
- `maintenance_mode` on `site_settings`, enforced **in SQL** in both
  `api.get_public_link()` and `api.create_order()` — the server is the only
  trustworthy gate — **and communicated in the UI** so the order form is replaced
  by a notice before a customer can fill it in. Server enforcement alone would
  let someone type a phone number into a form that is going to be rejected.
- Wire the two settings that currently do nothing:
  - `default_lang` is editable in the admin panel and read by nothing. The locale
    comes from `?lang=`, localStorage, geo, then `navigator.language`. It should
    become the fallback when no stored preference exists.
  - `recovery_enabled` is enforced server-side only, and the customer UI infers it
    by substring-matching an error string. Read it properly so the feature can be
    hidden before submit.
- `api.admin_set_settings()` performs no whitelist validation — unknown keys are
  silently dropped, unlike `admin_set_copy` which raises. Add the same raise.
- `site_settings.contact` is a write-only dead column: setter, generated types
  and an orphan label in `admin.json`, but no UI and no reader.

## Phase 4 — Branding and currency

**Status: not started.**

- Currency is a compile-time constant (`const BDT = 'BDT'` in `src/lib/money.ts`).
  Make it a setting, defaulting to BDT.
- The `৳` symbol is _also_ hardcoded in four customer copy strings. A currency
  change would leave it baked into the wording, so the symbol must be
  single-sourced in `money.ts` and removed from the copy.
  `bn/customer.json` `paywall.amountError` is missing `{amount}` entirely, and
  required placeholders are derived from the **English** bundle only, so that
  mismatch is currently untested.
- No branding model exists. `app.tagline` is registered as editable but rendered
  nowhere.
- `index.html` references `/favicon.svg`, which does not exist — there is no
  `public/` directory, so every page load 404s.
- Admin wordmarks stay literal. Admin chrome is deliberately not
  operator-overridable: merging overrides into `adminI18n` would let the copy
  editor rewrite the panel that edits it.

## Phase 5 — Validation and removing hardcoded copy

**Status: not started.**

- Validate brand colours server-side (hex or `oklch()` only) if they become
  settings, rejecting anything else the way `admin_set_copy` rejects unknown keys.
- Reject empty or oversized CTA copy at `admin_set_copy`.
- Add a regression test that fails when a customer view contains a raw
  user-visible string instead of `t()`. This is what stops the rest of the phase
  from silently regressing.

## Known loose ends

- `supabase/migrations/20260101000006_cron.sql` contains two `-- cron skipped`
  placeholders, so `private.sweep()` is never scheduled outside Supabase.
- `npm run check` fails on a large pre-existing lint baseline, which makes
  `check:all` unusable as a single command. Worth a dedicated pass, or an
  explicit decision to grandfather it.
- Six registered copy keys are never rendered: `app.tagline`,
  `footer.builtWith`, `setup.title`, `setup.body`, `setup.see`.

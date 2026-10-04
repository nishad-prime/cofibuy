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

**Status: done.** `supabase/migrations/20261004160000_public_settings_maintenance.sql`
adds `api.get_public_settings()` and a `maintenance_mode` flag that is enforced in
SQL and surfaced in the storefront.

Delivered:

- `api.get_public_settings()` returns only customer-safe fields:
  `maintenance_mode`, `recovery_enabled`, `default_lang`, `contact`, and the global
  minimum withheld whenever `hide_min_amount` is set. That last point is the same
  no-read-path rule `api.get_public_link()` applies per link: the settings projection
  must not become a side door to a hidden minimum.
- `maintenance_mode` is enforced in `api.create_order()` (SQLSTATE `P0001`,
  `shop temporarily closed`) and reported by `api.get_public_link()`. The order form
  is replaced by a notice in `src/views/customer/LinkView.vue`, so a customer never
  fills in a form that is going to be refused.
- `src/composables/useSiteSettings.ts` fetches the projection once from
  `CustomerLayout`, resolves to safe defaults on failure, and never gates first
  paint. It decides what is _shown_; `create_order()` decides what is _allowed_.
- `recovery_enabled` is read from the projection instead of substring-matching an
  error string, so rephrasing the server message can no longer re-open a closed form.
- `default_lang` is applied only when the visitor has no explicit preference
  (`applySiteDefaultLocale`), replacing the hardcoded final fallback.
- `src/views/admin/SettingsView.vue` gains the maintenance toggle and the `contact`
  field, so the previously write-only column now has both a reader and a writer.
- `api.admin_set_settings()` now raises on unknown keys, matching `admin_set_copy`.

The renames behind the gate needed explicit revokes: renaming a function carries its
grants with it and `create or replace` restores `PUBLIC EXECUTE`, so the inner
`get_public_link`/`create_order` bodies are revoked from `anon` and `authenticated`
by name. `supabase/tests/07_rls.sql` is what caught the missing revoke.

Verified by `supabase/tests/10_settings.sql` (27 assertions) and
`src/composables/useSiteSettings.test.ts` (13 tests).

## Phase 4 — Branding and currency

**Status: done.**

Delivered:

- Currency is now `public.site_settings.currency`, defaulting to `BDT`. A curated
  eleven-code allowlist is the check constraint; `api.get_public_settings()`
  publishes it, and `api.admin_set_settings()` validates a code before the update
  (raising `22023` for anything outside the list) so an operator typo cannot print
  a bogus symbol to customers. `src/lib/currency.ts` mirrors the list and a unit
  test reads the migration to keep the two in lockstep.
- The currency symbol is single-sourced in `formatMoney` and removed from every
  customer copy string. The four hardcoded `৳` in the bundle are gone, and `bn`
  `paywall.amountError` now carries `{amount}` (it had none).
- `formatMoney` gained an optional currency argument that falls back to BDT for an
  unknown code rather than handing `Intl` something it may reject.
- The admin queue, order detail and links views format with the stored currency via
  `src/composables/useAdminCurrency.ts`, so operator-facing and customer-facing
  totals never disagree.
- Branding: `public/favicon.svg` now exists (the old `index.html` reference had no
  file and every load 404'd), and the editable `app.tagline` renders in the customer
  footer. Admin wordmarks stay literal: merging overrides into `adminI18n` would let
  the copy editor rewrite the panel that edits it.
- The four keys that were editable but rendered nowhere — `footer.builtWith` and
  `setup.title|body|see` — were deregistered. `app.tagline` had been in that group
  and is now rendered, so it stays.

Verified by `supabase/tests/10_settings.sql` (33 assertions), plus unit tests in
`money.test.ts`, `currency.test.ts`, `useSiteSettings.test.ts` and
`copyKeys.test.ts`.

## Phase 5 — Validation and removing hardcoded copy

**Status: not started.** The currency-symbol half landed early: Phase 4 added a
`copyKeys.test.ts` guard that fails if any customer copy embeds a currency glyph,
so a symbol cannot creep back into the wording.

- Decide whether brand colour becomes a setting. Phase 4 deliberately deferred it:
  the palette is eleven `oklch()` shades in `main.css`, so a colour setting needs a
  generated ramp, not one column. If it happens, validate server-side (hex or
  `oklch()` only) the way `admin_set_copy` rejects unknown keys.
- Reject empty or oversized CTA copy at `admin_set_copy`.
- Add a regression test that fails when a customer view contains a raw
  user-visible string instead of `t()`. This is what stops the rest of the phase
  from silently regressing.

## Known loose ends

- `supabase/migrations/20260101000006_cron.sql` still carries two `-- cron skipped`
  placeholders (it is applied history and cannot be edited), but
  `20261004150000_install_cron_schedules.sql` installs the real schedules on any
  database that applied the stub. Both are now applied to the hosted project.
- `npm run check` fails on a large pre-existing lint baseline, which makes
  `check:all` unusable as a single command. Worth a dedicated pass, or an
  explicit decision to grandfather it.
- The typed `SupabaseClient<Database, 'api'>` return on `getSupabase()` is still
  `any`, which is why `supabase.rpc` is cast at each call site and why the lint
  baseline exists.

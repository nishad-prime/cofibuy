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

**Status: partial.**

Delivered:

- Copy is length-capped in the database. `api.admin_set_copy` refuses a value over
  400 characters with `22023`, measured in both languages, before the write. The
  editor is a trust boundary for the same reason markdown is refused on a label: a
  reviewer who can approve orders has no business rewriting what the shopfront says
  about taking payment. Per-key limits would be tighter but would mean eighty numbers
  to keep in step with the bundles, so instead `copyKeys.test.ts` reads the cap out of
  the migration and asserts every shipped string fits inside it — the number can never
  be set below copy that already exists.
- Copy that renders as nothing is refused. `private.tidy_blank_to_null` normalises a
  space-only value, but `btrim`'s one-argument form trims the space alone, so a value
  made of a tab or a zero-width space was stored as an override that displays nothing:
  the editor showed the field as filled in and the button came out with no label.
  Rejected rather than normalised, since normalising would silently revert what the
  operator saved.
- `src/config/rawCustomerCopy.test.ts` parses every customer template with
  `@vue/compiler-sfc` and fails on a raw user-visible string — a text node or a static
  `alt`/`aria-label`/`placeholder`/`title` containing a letter. It parses rather than
  pattern-matches so an interpolation, a bound attribute or a comment cannot be
  mistaken for copy, and it collects every violation before asserting so one run
  reports all of them. An allowlist carries two entries with reasons, and a second
  assertion fails when an entry is no longer used, so it cannot quietly become a
  loophole.
- The guard immediately paid for itself: it found three hardcoded English labels —
  "Phone number" and "Verification code" — in the middle of a Bangla-first
  storefront. Both are now `recovery.phone` and `recovery.code`, editable in both
  languages.

Remaining:

- Decide whether brand colour becomes a setting. Deferred again, deliberately: the
  palette is eleven `oklch()` shades in `main.css` whose hue walks 82.7→55.6, so a
  colour setting needs a generated ramp rather than one column, and a half-correct
  one would let an operator break button contrast. If it happens, validate
  server-side the way `admin_set_copy` rejects an unknown key.
- `tidy_blank_to_null` still normalises only what one-argument `btrim` considers
  blank. The visible-copy rule now refuses those values at the API, but any other
  write path to `copy_strings` would still store them.

## Phase 6 — Shrinking the admin surface

**Status: delivered.**

The complaint that started this was that the system had too many settings. Counting
them honestly, the site settings were not the problem — seven fields, all load-bearing.
The problem was the copy editor: 82 overridable keys rendered as 164 inputs on one
page, each labelled with its raw name, and about 56 of those keys are chrome nobody
rewords.

Delivered:

- **The copy editor opens on 24 keys instead of 82**, grouped by the screen the text
  appears on rather than by namespace, so the operator asks "what does the payment page
  say?" instead of "what does the paywall namespace hold?". 48 inputs instead of 164.
  One toggle reveals all 82 with a search box. Nothing is removed — every key stays
  overridable, and the tier is presentation only, so it needed no migration.
- **One component with a filter, not two components with a mode switch.** Two
  renderings over 82 keys is a consistency problem, and its failure mode is silent: a
  key that stops being listed still saves, still counts as dirty, and simply becomes
  unreachable, with nothing reporting an error. One path cannot drift from itself.
- **The section builder moved out of the SFC** into `src/config/copySections.ts`,
  because logic inside a `.vue` file cannot be tested. `buildCopySections` is asserted
  to list every key in the full view and never to show one twice — verified by
  mutating the full view to skip a namespace and watching the test fail.
- **The copy store's lockdown is now pinned rather than assumed.** `api.admin_set_copy`
  validates every value, which is decoration if a role can write `public.copy_strings`
  directly and skip it. `07_rls.sql` asserts zero RLS policies on the table, no write
  privilege for `anon`/`authenticated`, and the function ACL in both directions. The
  policy-count assertion is itself guarded by a second assertion asking the same
  `pg_policies` query about a table that _does_ have policies — a typo in the
  schemaname would otherwise make the count zero forever while the table sat open.
- **The length cap is enforced at the layer every writer passes through.** It is now
  also a CHECK constraint, because `api.get_public_copy` is granted to `anon` and ships
  every override to every visitor uncapped, so one unbounded value is a bandwidth
  cost paid by the whole storefront. The cap therefore appears twice in SQL, so
  `copyKeys.test.ts` reads both and fails if they disagree.
- **Three migrations that claimed `create or replace` resets grants were corrected.**
  It does not; only `drop function` does, to the creating role's defaults, which in an
  exposed schema means `PUBLIC` gets execute. The claim was a live hazard: a reader
  who believed it could conclude a `drop function` was needed to make a schema change
  cleanly, and that is the one action that would have handed execute to anon.
- Search matches the shipped wording in both languages, not just the key, because the
  operator reads the storefront and will paste the phrase they want changed.

Deliberately not done:

- **No setting or key was deleted.** `hide_min_amount` looks redundant next to
  `min_amount` and is not: it is a _secret_ minimum, enforced at `p_amount < v_min`
  and withheld from the customer, whereas `min_amount = 0` means no minimum at all.
- **Markdown was kept.** It costs a column, a flag, a checkbox, a preview and two
  dependencies, and it serves the six prose fields the curated view surfaces.
- **The seven site settings were left as they are.** They are few, and each is
  load-bearing. Regrouping them into fewer blocks was considered and deferred as the
  weakest value-to-risk item here: it touches the settings round-trip, whose comment
  records that a bad merge once made the form write back nothing at all, in exchange
  for a cosmetic gain.

## Phase 7 — One prompt in, one pasteable answer out

**Status: done.** `supabase/functions/_shared/ai/` is the whole of the AI client, and it is not
tied to copy.

Delivered:

- `provider.ts` — one OpenAI-compatible chat-completions call. The model is **forced** to call a
  named tool with a JSON schema, so a reply is read from the tool call rather than scraped out of
  prose. `AiProviderConfig.url` is the complete endpoint; nothing upstream guesses it.
- `schema.ts` — the array-shaped JSON Schema subset actually expressible in `tools`, with the
  non-expressible parts (`maxLength`, enums rendered faithfully) dropped rather than approximated.
- `generate.ts` — validation with **one** retry, and only after a validation or domain-check
  failure. A timeout, a 429, or a `finish_reason` of `length` is not retried: those are the
  provider saying something about capacity or prompt size, and asking again wastes the answer.
- Per-attempt `max_tokens` and a timeout, both stated at the call site rather than defaulted,
  because a shared default is a number nobody chose.

Verified by `schema_test.ts` (10 cases) and `generate_test.ts` (12 cases). The latter drives
`provider.ts` through a fake `fetch` that counts calls, so every case there is really about _how
many times the provider was called_. That is what makes the _absence_ of a retry testable: a
mutation that retries a timeout has to fail a test, not merely look untidy. `provider.ts` has no
test file of its own by design — it is exercised only as the thing under a stubbed `fetch`, and a
separate file for it would assert the same requests twice.

## Phase 8 — One credential writer for every subject that has credentials

**Status: done.** bKash gateways, and now AI providers, are stored the same way.

Delivered:

- `private.store_credential_bundle(p_kind, p_subject, p_kind_name, p_payload)` — one writer.
  `auto_providers` gained an `ai_provider` kind, so a new subject type is a registry row and not a
  second Vault policy.
- `private.secret_bundles` carries `subject_kind` / `subject_id`, so a bundle cannot be resolved
  without knowing both. That is what makes `api.gateway_credential_bundle(id)` and its AI
  equivalent answerable without a second lookup table.
- Subject-named lookup RPCs return a **bundle id**. Nothing on the request path returns plaintext;
  `api.secret_bundle_open(p_bundle_id)` is the single path from id to plaintext, and it is
  service-role only.
- Grant Token may be called at most twice an hour, so `_shared/token.ts` takes a **lease**
  (`bkash_claim_refresh` / `bkash_store_token` / `bkash_release_refresh`) instead of caching in an
  isolate. A traffic spike otherwise spends the whole allowance and then refuses to take money.

Verified by `supabase/tests/17_credential_bundle_kinds.sql` (31 assertions).

## Phase 9 — Point the shop at a model without printing its key

**Status: done.** `/admin/ai` is a settings page, not a credential vault.

Delivered:

- `private.ai_settings` is a singleton with a CHECK, so a second provider cannot exist by
  accident. `guard_ai_provider_known` refuses a provider the registry does not define — the
  settings row cannot name a credential kind that no writer understands.
- The credential is written through the Phase 8 writer, so rotating an AI key and rotating a
  bKash key are the same operation with the same guarantees.
- **Switching providers requires every declared field of the incoming provider in the same save**
  (SQLSTATE `22023`). A partial switch would leave a live `base_url` paired with the previous
  provider's key, which fails as a `401` that reads like a wrong key rather than a half-completed
  form. Same-provider partial saves are still allowed, because that is how a key is rotated. Blank
  counts as missing.
- `api.admin_ai_settings()` returns the provider and whether a credential exists — never the
  credential. The page therefore has nothing to leak, rather than promising not to print it.
- Clearing the provider deletes the bundle. An orphaned credential is a secret nobody will rotate.
- `api.ai_credential_bundle()` is service-role only and returns `(provider, bundle)`, zero rows
  when unconfigured. An Edge Function gets a bundle id and asks `secret_bundle_open` for the
  plaintext itself.

Verified by `supabase/tests/18_ai_credentials.sql` (33 assertions), which pins the switch guard,
the rotation path, the retirement path, and that a staff member sees neither the provider list nor
the settings.

## Phase 10 — A person takes a model's draft and decides

**Status: done.** `/admin/copy` gained a Draft button per string, owner-only.

Delivered:

- `src/config/aiCopyKeys.ts` — a **positive** list of 22 keys, written out rather than derived,
  with the reasons it excludes things. `evidence.*` is excluded wholesale: those strings state hard
  limits, and "Up to 5 MB" rewritten as something vaguer is a functional change wearing a copy
  change's clothes. `common.*` and `lang.*` are labels and status tokens, where a rewrite is churn.
- Placeholder-bearing keys are refused at render time by `canDraft`. Which keys carry `{amount}` is
  a property of the shipped translations, not of the key name, so the rule reads the actual bundled
  wording rather than guessing from the key.
- A draft lands in a preview panel, **not** in the textareas, until the operator accepts it. It
  becomes an ordinary unsaved edit at that point — still subject to the placeholder guard, still
  waiting on the page's own save. The function writes nothing and returns no credential.
- `supabase/functions/_shared/ai/draft.ts` holds everything decidable without a network call, so
  the credential join, the prompts and the shape of the answer are tested without a provider or a
  database.
- `chatCompletionsUrl` is idempotent: an operator who pastes the full endpoint into a box labelled
  "Base URL" gets working copy instead of a 404 that reads like a bad key.
- Authorisation is `api.admin_copy()` called with the caller's own JWT — owner-guarded, so the
  check is the database's and never the function's.

Verified by `src/config/aiCopyKeys.test.ts` (17 tests) and `draft_test.ts` (19 cases).

## Phase 11 — A product's copy, drafted in one call

**Status: done.** The link form drafts all eight prose fields at once, owner-only.

Delivered:

- One call, not eight. A title, a teaser and an unlock body that each read well but disagree with
  each other is worse than no draft, because reconciling them by hand is the work the button was
  meant to save. `readLinkBrief` refuses a partial set for the same reason.
- **The model never sees the guide.** It is a PDF in an upload bucket and this function does not
  open it. The operator's description is the only account of what is inside, and the first rule of
  the system prompt is that any specific detail the model adds is invented — because a customer
  pays on the strength of what it writes. The description is required rather than optional for the
  same reason: with only a slug to go on, invention is all that is available.
- `src/config/linkBriefFields.ts` — the eight columns, the form field each fills, and which need a
  textarea. Outside the SFC for the reason `buildCopySections` is: logic inside a `.vue` file
  cannot be tested.
- **The link form had no inputs for `teaser_md_*`, `unlock_body_md_*` or `unlock_cta_label_*`.** It
  loaded them, re-saved them verbatim and never showed them, so an operator editing a link could
  not see or change the prose customers read. Those fields have textareas now, rendered from the
  same list the draft panel reads, so a field cannot gain an input in one place and be missing from
  the other.
- Excluded on purpose: `slug`, `unlock_cta_url`, `min_amount_override`, `sort_order`, `is_active`,
  `is_listed`. A slug is half of a URL a customer may have bookmarked, and the rest are facts the
  operator owns.
- Owner-only via `api.admin_links()`, which is already owner-guarded and already raises for staff,
  so there is no new SQL. It is called for the raise, not for its rows: the form's current values
  travel in the request, because they are the more recent copy.
- The proposal stays open after a field is applied. The usual outcome is keeping most of a draft and
  rejecting one line, and closing the panel would mean drafting again for the rest.

Verified by `src/config/linkBriefFields.test.ts` (9 tests) and `linkBrief_test.ts` (15 cases). The
field-mapping assertions were checked by renaming one form field and watching them fail.

## Known loose ends

- `supabase/migrations/20260101000006_cron.sql` still carries two `-- cron skipped`
  placeholders (it is applied history and cannot be edited), but
  `20261004150000_install_cron_schedules.sql` installs the real schedules on any
  database that applied the stub. Both are now applied to the hosted project.
- Resolved in the pages refactor: `getSupabase()` now returns the typed
  `SupabaseClient<Database, 'api'>`, payloads are typed in `src/lib/rpc.ts`, and
  the lint baseline is gone — `npm run check` passes clean.
- `PageFormView.vue` still has no input for `sort_order` or `min_amount_override`.
  Both are loaded and re-saved verbatim, and `hide_min` is checkable without any
  value to hide, so a page can be marked "hide the minimum" and keep the shop-wide
  one. Left deliberately: they are numeric controls rather than copy, and fixing
  them is not the same change as anything shipped here.

## Further reading

- `docs/payment-flow.md` — the bKash return leg, why `status` is never read, and why a
  sandbox payment cannot settle an order. Read it before touching
  `bkash-execute`, `PaymentReturnView.vue` or either settlement RPC.
- `supabase/migrations/20261005040000_ai_credentials.sql` — the AI provider registry, the
  settings singleton, and the guard that refuses a partial provider switch.

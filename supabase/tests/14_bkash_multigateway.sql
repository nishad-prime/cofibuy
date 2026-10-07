-- Two bKash merchants on one shop.
--
-- This is the file that justifies the whole commit. Before it, bKash credentials came
-- from the deployment environment and the id_token cache was keyed by environment alone,
-- so the shop could run exactly one bKash merchant. Adding a second meant either a second
-- app or an unset of undocumented special cases; the token of one merchant would be
-- handed to the other, and the resulting failure would surface as an intermittent bKash
-- auth error rather than as anything that points at the cache.
--
-- The invariants, in the order they matter:
--
--   1. Credentials are per gateway. Two merchants are two bundles.
--   2. The token cache is per bundle. A token minted for one merchant is never served to
--      another, which is the specific cross-contamination this file exists to prevent.
--   3. The refresh lease is per bundle too, so two merchants cannot race for one lease and
--      starve the other's token refresh.
--   4. The environment is a second axis within a bundle: one merchant may be mid
--      migration to live while the other is not, and their caches must not collide.
--   5. Rotating one merchant's secret invalidates that merchant's cached token and leaves
--      every other merchant's alone.
--
-- Everything runs as service_role, which is the role the Edge Functions hold. The
-- interesting failures here are cross-merchant bleed-through, so the assertions are
-- written to be specific about *which* merchant is being asked, never "the token is
-- non-null".

select plan(32);

select test_data.reset();

select test_data.as_user(test_data.owner());

-- ---------------------------------------------------------------------------
-- Two merchants, two bundles
-- ---------------------------------------------------------------------------

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (merchant A)',
        'credential_bundle', jsonb_build_object(
          'app_key', 'key-a', 'app_secret', 'secret-a',
          'username', 'merchant-a', 'password', 'pw-a')))$$,
  'the owner can register the first automatic merchant'
);

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (merchant B)',
        'credential_bundle', jsonb_build_object(
          'app_key', 'key-b', 'app_secret', 'secret-b',
          'username', 'merchant-b', 'password', 'pw-b')))$$,
  'and the second automatic merchant, on the same kind'
);

select is(
  (select count(*) from private.secret_bundles),
  2::bigint,
  'each merchant has its own credential bundle'
);

select is(
  (select count(distinct decrypted_secret::jsonb ->> 'username') from vault.decrypted_secrets),
  2::bigint,
  'the two bundles hold different credentials rather than one shared secret'
);

-- ---------------------------------------------------------------------------
-- Caches do not bleed between merchants
-- ---------------------------------------------------------------------------

select test_data.as_service();

select is(
  api.bkash_claim_refresh(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'sandbox'),
  true,
  'merchant A takes its refresh lease, which store_token requires'
);

select lives_ok(
  $$select api.bkash_store_token(
      (select b.id from private.secret_bundles b
       join public.payment_gateways g on g.id = b.subject_id
       where g.name_en = 'bKash (merchant A)'),
      'sandbox', 'a-id', 'a-refresh', 3600)$$,
  'merchant A can cache a token'
);

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'sandbox') ->> 'id_token',
  'a-id',
  'merchant A is served its own cached token'
);

-- The assertion the entire commit exists for. Keyed by environment alone, this call would
-- have returned A's token for B, and B would then present A's id_token to bKash.

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant B)'), 'sandbox') ->> 'bootstrap',
  'true',
  'merchant B is told to bootstrap instead of being handed merchant A''s token'
);

select ok(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant B)'), 'sandbox') ->> 'id_token' is null,
  'and merchant B is handed no token at all'
);

select is(
  (select count(*) from private.bkash_tokens),
  1::bigint,
  'only merchant A''s token is cached'
);

-- ---------------------------------------------------------------------------
-- Refresh leases are per bundle
-- ---------------------------------------------------------------------------
-- Grant/Token may be called twice an hour per merchant. A shared lease would let one
-- merchant's refresh consume the other's budget and stop the other taking payments.

select is(
  api.bkash_claim_refresh(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'sandbox'),
  true,
  'merchant A takes its own refresh lease'
);

select is(
  api.bkash_claim_refresh(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'sandbox'),
  false,
  'and a second caller for merchant A does not get it'
);

select is(
  api.bkash_claim_refresh(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant B)'), 'sandbox'),
  true,
  'merchant B can still take a refresh lease while A holds one'
);

select is(
  api.bkash_claim_refresh(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant B)'), 'sandbox'),
  false,
  'and B is subject to the same once-only rule'
);

-- ---------------------------------------------------------------------------
-- Both merchants settle with their own credentials
-- ---------------------------------------------------------------------------

select lives_ok(
  $$select api.bkash_store_token(
      (select b.id from private.secret_bundles b
       join public.payment_gateways g on g.id = b.subject_id
       where g.name_en = 'bKash (merchant A)'),
      'sandbox', 'a-id-2', 'a-refresh-2', 3600)$$,
  'the lease winner for merchant A stores what it fetched'
);

select lives_ok(
  $$select api.bkash_store_token(
      (select b.id from private.secret_bundles b
       join public.payment_gateways g on g.id = b.subject_id
       where g.name_en = 'bKash (merchant B)'),
      'sandbox', 'b-id', 'b-refresh', 3600)$$,
  'merchant B stores its own token, under its own lease'
);

select is(
  (select count(*) from private.bkash_tokens),
  2::bigint,
  'the cache holds one row per merchant per environment'
);

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'sandbox') ->> 'id_token',
  'a-id-2',
  'merchant A still reads back its own token'
);

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant B)'), 'sandbox') ->> 'id_token',
  'b-id',
  'merchant B reads back its own token'
);

select isnt(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'sandbox') ->> 'id_token',
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant B)'), 'sandbox') ->> 'id_token',
  'the two merchants are demonstrably not sharing a token'
);

-- ---------------------------------------------------------------------------
-- Environment is a second axis, not a global
-- ---------------------------------------------------------------------------
-- A shop migrating one merchant to live while the other stays on sandbox is ordinary,
-- and a cache keyed by environment alone would make those two merchants collide again.

-- A cache row is per bundle *and* environment, so the live environment needs its own
-- lease claimed separately from the sandbox one. That is the intended shape: a merchant
-- mid-migration to live holds two independent caches, and neither one's refresh lease
-- can consume the other's.

select is(
  api.bkash_claim_refresh(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'live'),
  true,
  'the live environment has its own refresh lease'
);

select lives_ok(
  $$select api.bkash_store_token(
      (select b.id from private.secret_bundles b
       join public.payment_gateways g on g.id = b.subject_id
       where g.name_en = 'bKash (merchant A)'),
      'live', 'a-live-id', 'a-live-refresh', 3600)$$,
  'merchant A can hold a live token while its sandbox token is still cached'
);

select is(
  (select count(*) from private.bkash_tokens),
  3::bigint,
  'the live token is a third row rather than an overwrite'
);

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'live') ->> 'id_token',
  'a-live-id',
  'the live environment serves the live token'
);

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'sandbox') ->> 'id_token',
  'a-id-2',
  'and the sandbox environment still serves the sandbox token'
);

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant B)'), 'sandbox') ->> 'id_token',
  'b-id',
  'merchant B is unaffected by merchant A going live'
);

-- ---------------------------------------------------------------------------
-- Rotating one merchant leaves the other alone
-- ---------------------------------------------------------------------------
-- Purge-on-rotation has to be scoped to the bundle that changed. A global purge would
-- look correct in a shop with one merchant and would quietly evict every other
-- merchant's token whenever an operator rotated a key, which would spend bKash's
-- two-per-hour budget that merchant had not used.

select test_data.as_user(test_data.owner());

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'id', (select id from public.payment_gateways where name_en = 'bKash (merchant A)'),
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (merchant A)',
        'credential_bundle', jsonb_build_object('app_secret', 'secret-a-rotated')))$$,
  'merchant A can rotate its app_secret'
);

select is(
  (select count(*) from private.bkash_tokens),
  1::bigint,
  'only merchant A tokens were purged'
);

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant A)'), 'sandbox') ->> 'bootstrap',
  'true',
  'merchant A must bootstrap again with its new credential'
);

select test_data.as_service();

select is(
  api.bkash_token_state(
    (select b.id from private.secret_bundles b
     join public.payment_gateways g on g.id = b.subject_id
     where g.name_en = 'bKash (merchant B)'), 'sandbox') ->> 'id_token',
  'b-id',
  'merchant B''s token survived merchant A''s rotation'
);

select is(
  (select decrypted_secret::jsonb ->> 'app_secret'
   from vault.decrypted_secrets d
   join private.secret_bundles b on b.vault_secret_id = d.id
   join public.payment_gateways g on g.id = b.subject_id
   where g.name_en = 'bKash (merchant A)'),
  'secret-a-rotated',
  'merchant A is running on the rotated secret'
);

select is(
  (select decrypted_secret::jsonb ->> 'app_secret'
   from vault.decrypted_secrets d
   join private.secret_bundles b on b.vault_secret_id = d.id
   join public.payment_gateways g on g.id = b.subject_id
   where g.name_en = 'bKash (merchant B)'),
  'secret-b',
  'merchant B''s credential was not touched by merchant A''s rotation'
);

select * from finish();

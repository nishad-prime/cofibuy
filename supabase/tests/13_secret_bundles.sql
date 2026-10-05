-- Credential bundles and the automatic provider registry.
--
-- Commit 2 moves bKash's app_key/app_secret/username/password off the deployment
-- environment and onto the gateway row, so one shop can run two bKash merchants. That
-- move is what this file is about; the settlement behaviour it enables lives in
-- 14_bkash_multigateway.sql.
--
-- The invariants, in the order they matter:
--
--   1. Secrets are write-only over the API. Nothing a logged-in role can reach reads a
--      stored credential back, because the one surface that shows a credential is the
--      admin form and it renders a mask instead.
--   2. Saving the form must not destroy a secret the form never saw. Credentials are
--      masked with no read-back, so an edit-save that touches no credential field sends
--      an empty payload. That is a no-op, never a wipe.
--   3. Only declared keys are stored, and a bundle created from scratch must supply all
--      of them, so a typo fails loudly at setup rather than silently at payment time.
--   4. Rotating a credential invalidates that bundle's cached id_token, because the
--      cached token was minted from the secret that was just replaced.
--
-- A note on how grants are asserted here. The harness runs every statement as a
-- superuser, so `throws_ok` cannot be used to prove a privilege boundary: superuser
-- bypasses the revokes outright and the call would simply succeed. These assertions
-- therefore ask `has_function_privilege` about the role directly, which is also a more
-- honest statement of intent than "somebody happened not to call it".

select plan(44);

select test_data.reset();

select test_data.link('s13', 500, false);

select test_data.as_user(test_data.owner());

-- ---------------------------------------------------------------------------
-- The provider registry
-- ---------------------------------------------------------------------------
-- Providers live in a table rather than as a hardcoded list so that adding one later is
-- a seed insert. That means the database has to enforce the set on writes, not merely
-- describe it to the admin UI, or anything holding a direct connection can create a
-- gateway whose provider nothing will ever settle.

select is(
  (select count(*) from api.admin_auto_providers()),
  1::bigint,
  'the registry starts with the one provider the shop actually runs'
);

select is(
  (select slug from api.admin_auto_providers()),
  'bkash_pgw',
  'bKash PGW is the registered automatic provider'
);

select is(
  (select jsonb_array_length(fields) from api.admin_auto_providers()),
  4,
  'the registry declares the four credentials bKash PGW authenticates with'
);

-- A gateway the settlement code has no implementation for would accept a customer's
-- money and then never capture it, so the provider column is guarded by a trigger rather
-- than by convention. The SQLSTATE stays 23514 because callers already branch on check
-- violation there.

select throws_ok(
  $$insert into public.payment_gateways (
      kind, provider, name_en, account_number, account_name, account_fields, evidence_fields
    ) values (
      'bkash', 'not_a_provider', 'Bogus', '01700000000', 'Cofibuy', '[]'::jsonb, '[]'::jsonb)$$,
  '23514',
  'unknown payment provider: not_a_provider',
  'a gateway cannot be created for an unregistered provider'
);

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
        'account_fields', '[]'::jsonb, 'evidence_fields', '[]'::jsonb,
        'credential_bundle', jsonb_build_object(
          'app_key', 'key-one', 'app_secret', 'secret-one',
          'username', 'merchant-one', 'password', 'pw-one')))$$,
  'the owner can set up an automatic method with its credentials'
);

-- The same guard on payment_sessions. That column decides which backend a live
-- settlement runs against, so an unregistered value there is worth refusing just as
-- much as on the gateway.

select throws_ok(
  $$insert into public.payment_sessions (order_id, provider, provider_payment_id, amount)
    values (
      test_data.pgw_order('s13'), 'not_a_provider', 'pi-' || gen_random_uuid()::text, 500)$$,
  '23514',
  'unknown payment provider: not_a_provider',
  'a payment session cannot be opened against an unregistered provider either'
);

-- ---------------------------------------------------------------------------
-- What the write produced
-- ---------------------------------------------------------------------------
-- The bundle is keyed by (subject_kind, subject_id) instead of carrying a nullable
-- foreign key on payment_gateways, so a gateway row never exposes a handle on its own
-- secret and deleting a gateway cannot leave a dangling pointer behind.

select is(
  (select count(*) from private.secret_bundles),
  1::bigint,
  'exactly one bundle exists for the one automatic method'
);

select ok(
  (select api.gateway_credential_bundle(id) is not null
   from public.payment_gateways where provider = 'bkash_pgw'),
  'the bundle resolves for the Edge Function that will spend it'
);

select is(
  (select secret::jsonb ->> 'app_secret' from vault.decrypted_secrets),
  'secret-one',
  'the credential reached Vault rather than a plain column'
);

select is(
  (select environment from public.payment_gateways where provider = 'bkash_pgw'),
  'sandbox',
  'a new automatic method defaults to the sandbox environment'
);

-- ---------------------------------------------------------------------------
-- Secrets are write-only over the API
-- ---------------------------------------------------------------------------
-- This is the reason the bundle lives in a private schema at all. If a logged-in role
-- can call the open function, every merchant credential in the shop is readable by
-- anyone with a session, so these four assertions matter more than any other in the file.

select test_data.can_execute('authenticated', 'api.secret_bundle_open(uuid)'),
  false,
  'a customer cannot open a credential bundle';

select test_data.can_execute('anon', 'api.secret_bundle_open(uuid)'),
  false,
  'nor can an anonymous visitor';

select test_data.can_execute('authenticated', 'api.gateway_credential_bundle(uuid)'),
  false,
  'a customer cannot resolve which bundle a gateway uses';

select test_data.can_execute('anon', 'api.gateway_credential_bundle(uuid)'),
  false,
  'nor can an anonymous visitor resolve a bundle';

select test_data.can_execute('service_role', 'api.secret_bundle_open(uuid)'),
  true,
  'service_role, which runs the Edge Functions, can read the bundle it needs to settle'
  ;

-- ---------------------------------------------------------------------------
-- Declared keys only
-- ---------------------------------------------------------------------------
-- A key the provider does not declare is either a typo or an attempt to park something
-- the settlement code will never send. Storing it quietly would leave an operator
-- believing a secret is configured when it is inert.

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bkash', 'provider', 'not_a_provider', 'name_en', 'Bogus'))$$,
  '22023',
  'unknown payment provider: not_a_provider',
  'the owner cannot register an unknown provider through the admin RPC'
);

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'nagad', 'provider', 'bkash_pgw', 'name_en', 'Nagad (instant)',
        'credential_bundle', jsonb_build_object('app_key', 'k')))$$,
  '22023',
  'credential username is required for bkash_pgw',
  'a new bundle must supply every declared credential'
);

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
        'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
        'credential_bundle', jsonb_build_object(
          'app_key', 'k', 'app_secret', 's', 'username', 'u', 'password', 'p',
          'api_version', 'v3')))$$,
  '22023',
  'credential api_version is not part of bkash_pgw',
  'a key the provider does not declare is refused'
);

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
        'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
        'credential_bundle', jsonb_build_object(
          'app_key', 'k', 'app_secret', '   ', 'username', 'u', 'password', 'p')))$$,
  '22023',
  'credential app_secret cannot be blank',
  'a credential that is present but blank is a setup error, not a value'
);

-- ---------------------------------------------------------------------------
-- Saving the form does not destroy what the form could not see
-- ---------------------------------------------------------------------------
-- The admin UI masks stored secrets and never reads them back, by design. The
-- consequence, which is easy to get wrong, is that an edit-save touching no credential
-- field submits an empty credential payload. If an empty payload meant "replace with
-- nothing", then every unrelated save of an automatic method would silently erase the
-- merchant password and the shop would stop taking payments some time later, with
-- nothing in the logs to explain it.

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
        'account_fields', '[]'::jsonb, 'evidence_fields', '[]'::jsonb,
        'is_active', true,
        'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1)))$$,
  'an edit-save that sends no credentials at all succeeds'
);

select is(
  (select secret::jsonb ->> 'app_secret' from vault.decrypted_secrets),
  'secret-one',
  'an empty credential payload leaves the stored secret alone'
);

select is(
  (select secret::jsonb ->> 'username' from vault.decrypted_secrets),
  'merchant-one',
  'and leaves every other stored credential alone too'
);

select is(
  (select count(*) from vault.secrets),
  1::bigint,
  'a no-op save does not create a second Vault secret'
);

-- A partial payload is the other half of the same rule: the form sends the one field the
-- operator actually retyped, and everything else has to survive it.

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
        'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
        'credential_bundle', jsonb_build_object('app_secret', 'secret-two')))$$,
  'an edit-save that retypes one credential succeeds'
);

select is(
  (select secret::jsonb ->> 'app_secret' from vault.decrypted_secrets),
  'secret-two',
  'the retyped credential is the one that changed'
);

select is(
  (select secret::jsonb ->> 'username' from vault.decrypted_secrets),
  'merchant-one',
  'the credentials the operator never saw are still there afterwards'
);

select is(
  (select secret::jsonb ->> 'password' from vault.decrypted_secrets),
  'pw-one',
  'merge semantics hold for every untouched key, not just the first'
);

select is(
  (select count(*) from vault.secrets),
  1::bigint,
  'an update writes through the existing Vault secret rather than replacing it'
);

-- ---------------------------------------------------------------------------
-- Rotation invalidates the cached token
-- ---------------------------------------------------------------------------
-- Grant/Token returns an id_token signed with app_secret. Replacing app_secret without
-- dropping the cached token leaves the next request authenticating with a token from a
-- retired credential, and bKash reports that as an opaque auth failure rather than as
-- "you changed your key".
--
-- Caching a token is a two-step protocol: the caller wins the refresh lease, then writes
-- what it fetched. `store_token` refuses to write without the lease, which is why the
-- claim below is not incidental setup.

select test_data.as_service();

select is(
  api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'sandbox'),
  true,
  'the caller takes the refresh lease before storing'
);

select lives_ok(
  $$select api.bkash_store_token(
      (select id from private.secret_bundles limit 1), 'sandbox',
      'token-abc', 'refresh-abc', 3600)$$,
  'a token can then be cached against the bundle'
);

select is(
  (select count(*) from private.bkash_tokens),
  1::bigint,
  'the token is cached for the bundle rather than for the environment'
);

-- The environment-keyed overloads have to be gone, not merely superseded. `create or
-- replace` matches on the argument list, so defining the bundle-keyed versions leaves the
-- old ones callable, and they resolve a cached token by environment alone — which now
-- means "whichever merchant sorts first". Left in place they would hand one merchant's
-- id_token to another, which is the precise failure this migration exists to prevent, so
-- the absence of the old signatures is asserted directly.

select ok(
  to_regprocedure('api.bkash_token_state(text)') is null,
  'the environment-keyed token reader is gone, not just superseded'
);

select ok(
  to_regprocedure('api.bkash_claim_refresh(text)') is null,
  'and so is the environment-keyed refresh lease'
);

select ok(
  to_regprocedure('api.bkash_store_token(text, text, text, integer)') is null,
  'and the environment-keyed token writer'
);

select test_data.as_user(test_data.owner());

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
        'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
        'credential_bundle', jsonb_build_object('app_secret', 'secret-three')))$$,
  'the owner can rotate a credential'
);

select is(
  (select count(*) from private.bkash_tokens),
  0::bigint,
  'rotating a credential purges the token minted from the old one'
);

-- The converse is the assertion that would catch an over-eager implementation. If every
-- save dropped the token, nothing would look wrong in the shop until bKash's
-- two-per-hour Grant/Token budget ran out, which is exactly the kind of failure that gets
-- discovered by customers rather than by us.

select test_data.as_service();

select is(
  api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'sandbox'),
  true,
  'the lease can be taken again once the purged row is gone'
);

select lives_ok(
  $$select api.bkash_store_token(
      (select id from private.secret_bundles limit 1), 'sandbox',
      'token-def', 'refresh-def', 3600)$$,
  'a fresh token can be cached after the rotation'
);

select test_data.as_user(test_data.owner());

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
        'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
        'credential_bundle', jsonb_build_object(
          'app_key', 'key-one', 'app_secret', 'secret-three',
          'username', 'merchant-one', 'password', 'pw-one')))$$,
  're-saving the same credential values succeeds'
);

select is(
  (select count(*) from private.bkash_tokens),
  1::bigint,
  'a save that changes no credential keeps the cached token'
);

-- ---------------------------------------------------------------------------
-- Telling "has credentials" from "leave blank to keep"
-- ---------------------------------------------------------------------------
-- The admin form masks credentials with no read-back, so on opening an automatic gateway
-- it cannot tell a bundle that exists from one that never did. The two states look
-- identical on screen - four password boxes showing placeholders - yet they mean opposite
-- things: one keeps working, the other fails at payment time for want of a bundle.
-- `api.admin_gateway_has_credentials` is the boolean that separates them.
--
-- It exists only because `api.gateway_credential_bundle` is service_role only. That
-- restriction is correct and stays: a bundle id is a pointer to the store holding the
-- plaintext, and a boolean's not. What is asserted below is that the narrower answer is
-- exposed to exactly who needs it and no wider.

select is(
  api.admin_gateway_has_credentials(
    (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1)),
  true,
  'the owner is told an automatic method with a stored bundle has credentials'
);

select is(
  api.admin_gateway_has_credentials(gen_random_uuid()),
  false,
  'and an id that matches no gateway reads as false rather than raising'
);

select ok(
  test_data.can_execute('authenticated', 'api.admin_gateway_has_credentials(uuid)'),
  'a logged-in role may ask the question'
);

select ok(
  not test_data.can_execute('anon', 'api.admin_gateway_has_credentials(uuid)'),
  'anon may not'
);

select ok(
  not test_data.can_execute('public', 'api.admin_gateway_has_credentials(uuid)'),
  'and it is not left on public'
);

-- Owner-only, matching `admin_upsert_gateway`. Whether a merchant credential exists is
-- itself owner-only configuration: a staff account that could enumerate it could probe for
-- a merchant account being onboarded, and the function returns false rather than raising so
-- that enumeration cannot be told apart from an absent row.
select test_data.as_user(test_data.new_staff('staff'));

select is(
  api.admin_gateway_has_credentials(
    (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1)),
  false,
  'staff asking about an existing bundle is told no'
);

select test_data.as_user(test_data.owner());

-- ---------------------------------------------------------------------------
-- Going back to manual
-- ---------------------------------------------------------------------------
-- An automatic method carries a live merchant credential. Turning it into a manual method
-- is the operator saying that credential is no longer in use, so the bundle goes with it
-- rather than lingering as an orphan holding a secret nobody will ever revoke at bKash.

select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
        'kind', 'bkash', 'provider', null, 'name_en', 'bKash (screenshot)',
        'account_fields', '[]'::jsonb, 'evidence_fields', '[]'::jsonb))$$,
  'an automatic method can be turned back into a manual one'
);

select is(
  (select count(*) from private.secret_bundles),
  0::bigint,
  'turning it manual retires the credential bundle'
);

select test_data.as_service();

select ok(
  api.gateway_credential_bundle(
    (select id from public.payment_gateways where kind = 'bkash' limit 1)) is null,
  'and the Edge Function lookup then reports nothing configured'
);

select * from finish();

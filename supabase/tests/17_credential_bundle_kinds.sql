-- One credential writer for every subject that has credentials.
--
-- The claims in `20261005030000_credential_bundle_kinds.sql`, asserted directly.
--
-- This file exists because the reserved kind was untestable while it was reserved.
-- `private.secret_bundles` has accepted `subject_kind = 'ai_provider'` since the second
-- commit, and nothing could write one - `store_credential_bundle` hardcoded `'gateway'`.
-- The CHECK constraint was therefore asserting a capability the system did not have, and no
-- test could tell the difference between "the schema allows it" and "it works".
--
-- The invariants, in the order they matter:
--
--   1. A second kind cannot become a payment provider. This is the bug the discriminator
--      closes: one registry, one slug namespace, so registering an AI provider would
--      otherwise make its slug a valid `payment_gateways.provider` and a gateway would
--      accept money it has no capture code for.
--   2. The same writer validates, merges and trims for both kinds. That is the whole point
--      of generalising it - one place where "a blank value is refused" is true.
--   3. A gateway bundle and an AI bundle can coexist without colliding, because the unique
--      key is (kind, subject) and not subject alone.
--   4. Storing an AI credential does not purge a payment token cache.
--
-- A note on how privileges are asserted. The harness runs statements as a superuser, so
-- `throws_ok` cannot prove a boundary - superuser bypasses the revokes. These ask about the
-- role's ability to execute instead, which is also the more honest statement of intent.

select plan(31);

select test_data.reset();

select test_data.link('kind7', 500, false);

select test_data.as_service();

-- ---------------------------------------------------------------------------
-- The registry learns what kind it is registering
-- ---------------------------------------------------------------------------

insert into private.auto_providers (slug, subject_kind, name_en, fields, sort_order)
values (
  'test_ai_provider', 'ai_provider', 'Test model provider',
  '[
    {"key":"api_key","label_en":"API key","secret":true},
    {"key":"base_url","label_en":"Base URL","secret":false},
    {"key":"model","label_en":"Model","secret":false}
  ]'::jsonb,
  10
);

select is(
  (select subject_kind from private.auto_providers where slug = 'bkash_pgw'),
  'gateway',
  'the payment provider that already existed is a gateway provider'
);

select is(
  (select subject_kind from private.auto_providers where slug = 'test_ai_provider'),
  'ai_provider',
  'the new row declares the kind it supplies credentials for'
);

select throws_ok(
  $$insert into private.auto_providers (slug, subject_kind, name_en, fields)
  values ('nope', 'wallet', 'Wrong kind', '[]'::jsonb)$$,
  '23514',
  'new row for relation "auto_providers" violates check constraint "auto_providers_subject_kind_known"',
  'the kinds are closed, so a typo cannot invent a third'
);

-- ---------------------------------------------------------------------------
-- The collision this closes
-- ---------------------------------------------------------------------------
-- A gateway row pointed at an AI provider would take a customer's money and route it, by
-- weight, to a kind with no settlement code. The failure lands at capture time, on a live
-- order, which is the worst place to find out a slug was valid in the wrong registry.

select throws_ok(
  $$insert into public.payment_gateways (
      kind, provider, name_en, account_number, account_name, account_fields, evidence_fields
    ) values (
      'bkash', 'test_ai_provider', 'Bogus', '01700000000', 'Cofibuy',
      '[]'::jsonb, '[]'::jsonb)$$,
  '23514',
  'unknown payment provider: test_ai_provider',
  'a registered AI provider is still not a valid payment provider'
);

-- Needed as a real row rather than a bare insert, because an UPDATE that matches nothing
-- fires no trigger and would prove nothing.
select test_data.pgw_gateway(true, 'bkash_instant', 'sandbox') as clash_gateway;

select throws_ok(
  $$update public.payment_gateways set provider = 'test_ai_provider'
    where provider = 'bkash_pgw'$$,
  '23514',
  'unknown payment provider: test_ai_provider',
  'nor can an existing gateway be repointed at one'
);

-- The same refusal on the RPC, because the trigger only fires for a direct write and this is
-- the path the admin form actually takes.
select test_data.as_user(test_data.owner());

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bkash', 'provider', 'test_ai_provider', 'name_en', 'Bogus',
        'account_fields', '[]'::jsonb, 'evidence_fields', '[]'::jsonb))$$,
  '22023',
  'unknown payment provider: test_ai_provider',
  'and the admin form cannot do it either'
);

-- The gateway form reads this, and it must not start offering a way to take money from a
-- language model. Two AI providers are registered by now - this file's own and the seeded one -
-- and the form must still see exactly the gateway.
select is(
  (select count(*) from api.admin_auto_providers()),
  1::bigint,
  'the registry holds AI providers and the gateway form still sees one'
);

select is(
  (select slug from api.admin_auto_providers()),
  'bkash_pgw',
  'and it is still the payment provider'
);

select test_data.as_service();

-- ---------------------------------------------------------------------------
-- Writing the second kind
-- ---------------------------------------------------------------------------
-- Called directly rather than through an RPC: this commit generalises the writer, and the
-- surface that will call it for an AI provider is the next one. Testing it through the
-- private function is what lets the writer be correct before anything depends on it.
--
-- The write is asserted with `lives_ok` and then read back, rather than by comparing the
-- returned id against a lookup of the row just written: argument evaluation order inside one
-- expression is not guaranteed, so that subquery can legitimately read the table before the
-- insert has happened.

select lives_ok(
  $$select private.store_credential_bundle(
      'ai_provider', '11111111-1111-4111-8111-111111111111'::uuid, 'test_ai_provider',
      jsonb_build_object(
        'api_key', '  sk-live-abc123  ', 'base_url', 'https://api.example.test/v1',
        'model', 'small-model'))$$,
  'an AI provider bundle is written where the constraint always said it could be'
);

select is(
  (select subject_kind from private.secret_bundles where subject_id =
    '11111111-1111-4111-8111-111111111111'::uuid),
  'ai_provider',
  'and it is keyed by the kind it was written for'
);

select is(
  (select secret::jsonb ->> 'api_key' from vault.decrypted_secrets
    where id = (select vault_secret_id from private.secret_bundles
                where subject_kind = 'ai_provider')),
  'sk-live-abc123',
  'the key is stored trimmed, by the same code that trims a merchant password'
);

select is(
  (select secret::jsonb ->> 'base_url' from vault.decrypted_secrets
    where id = (select vault_secret_id from private.secret_bundles
                where subject_kind = 'ai_provider')),
  'https://api.example.test/v1',
  'a non-secret field survives alongside the secret one'
);

-- Named for the kind, so a bundle is identifiable in the vault's own listing and not only
-- through this table.
select is(
  (select name from vault.secrets
    where id = (select vault_secret_id from private.secret_bundles
                where subject_kind = 'ai_provider')),
  'ai_provider:11111111-1111-4111-8111-111111111111',
  'the vault entry carries the kind in its name'
);

-- ---------------------------------------------------------------------------
-- The same rules as a gateway
-- ---------------------------------------------------------------------------
-- Merge semantics, trimming and refusal are the point of one writer. Each of these would
-- have been a separate implementation to get right, and a second implementation is a second
-- set of bugs.

-- The exact mistake the discriminator exists to catch: the right slug, the wrong kind.
select throws_ok(
  $$select private.store_credential_bundle(
      'gateway', '11111111-1111-4111-8111-111111111111'::uuid, 'test_ai_provider',
      '{}'::jsonb)$$,
  '22023',
  'unknown payment provider: test_ai_provider',
  'a registered AI provider is refused when asked for as a payment provider'
);

select throws_ok(
  $$select private.store_credential_bundle(
      'ai_provider', '22222222-2222-4222-8222-222222222222'::uuid, 'test_ai_provider',
      jsonb_build_object('api_key', 'sk-live-abc123', 'base_url', 'https://x.test'))$$,
  '22023',
  'credential model is required for test_ai_provider',
  'a new bundle must supply every declared key'
);

select throws_ok(
  $$select private.store_credential_bundle(
      'ai_provider', '22222222-2222-4222-8222-222222222222'::uuid, 'test_ai_provider',
      jsonb_build_object(
        'api_key', 'sk-live-abc123', 'base_url', 'https://x.test', 'model', 'm',
        'temperature', '0.7'))$$,
  '22023',
  'credential temperature is not part of test_ai_provider',
  'an undeclared key is refused rather than stored quietly'
);

select throws_ok(
  $$select private.store_credential_bundle(
      'ai_provider', '22222222-2222-4222-8222-222222222222'::uuid, 'test_ai_provider',
      jsonb_build_object(
        'api_key', '   ', 'base_url', 'https://x.test', 'model', 'm'))$$,
  '22023',
  'credential api_key cannot be blank',
  'and whitespace is not a value'
);

select throws_ok(
  $$select private.store_credential_bundle(
      'ai_provider', '22222222-2222-4222-8222-222222222222'::uuid, 'test_ai_provider',
      jsonb_build_object(
        'api_key', 42, 'base_url', 'https://x.test', 'model', 'm'))$$,
  '22023',
  'credential api_key must be a string',
  'and a number is not silently coerced into one'
);

select throws_ok(
  $$select private.store_credential_bundle(
      'wallet', '22222222-2222-4222-8222-222222222222'::uuid, 'test_ai_provider', '{}'::jsonb)$$,
  '22023',
  'unknown credential subject kind: wallet',
  'an unknown kind names itself, rather than being reported as an unknown provider'
);

-- Merge, not replace: a partial save keeps what it did not mention, exactly as the gateway
-- form depends on, because the form renders a mask and cannot read a secret back.
select lives_ok(
  $$select private.store_credential_bundle(
      'ai_provider', '11111111-1111-4111-8111-111111111111'::uuid, 'test_ai_provider',
      jsonb_build_object('model', 'bigger-model'))$$,
  'a partial save is accepted against an existing bundle'
);

select is(
  (select secret::jsonb ->> 'api_key' from vault.decrypted_secrets
    where id = (select vault_secret_id from private.secret_bundles
                where subject_kind = 'ai_provider')),
  'sk-live-abc123',
  'a save that mentions one key does not erase the others'
);

select is(
  (select secret::jsonb ->> 'model' from vault.decrypted_secrets
    where id = (select vault_secret_id from private.secret_bundles
                where subject_kind = 'ai_provider')),
  'bigger-model',
  'and does write the one it did'
);

select is(
  (select count(*) from private.secret_bundles where subject_kind = 'ai_provider'),
  1::bigint,
  'the second save updated the bundle rather than adding one'
);

-- ---------------------------------------------------------------------------
-- Both kinds, side by side
-- ---------------------------------------------------------------------------
-- The unique key is (subject_kind, subject_id), so one row id cannot be a gateway and an AI
-- provider at once. Worth asserting rather than assuming, because the writer selects on both
-- columns and a bug there would silently read another kind's secret.

select test_data.as_user(test_data.owner());

-- No `id`, so this inserts rather than updates: the gateway row that exists here was made by
-- the fixture without credentials, and this is the form path that supplies them.
select api.admin_upsert_gateway(
  jsonb_build_object(
    'kind', 'bkash_instant', 'provider', 'bkash_pgw', 'name_en', 'bKash',
    'environment', 'sandbox',
    'account_fields', '[]'::jsonb, 'evidence_fields', '[]'::jsonb,
    'credential_bundle', jsonb_build_object(
      'app_key', 'merchant-key', 'app_secret', 'merchant-secret',
      'username', 'merchant-user', 'password', 'merchant-pw'))
);

select is(
  (select count(*) from private.secret_bundles where subject_kind = 'gateway'),
  1::bigint,
  'the gateway row got its own bundle, written through the form'
);

select is(
  (select secret::jsonb ->> 'app_secret' from vault.decrypted_secrets
    where id = (select vault_secret_id from private.secret_bundles
                where subject_kind = 'gateway')),
  'merchant-secret',
  'the merchant secret landed in the gateway bundle'
);

select is(
  (select secret::jsonb ->> 'api_key' from vault.decrypted_secrets
    where id = (select vault_secret_id from private.secret_bundles
                where subject_kind = 'ai_provider')),
  'sk-live-abc123',
  'and the AI secret is untouched by a gateway write'
);

-- ---------------------------------------------------------------------------
-- A token cache is a gateway concern
-- ---------------------------------------------------------------------------

select test_data.as_service();

-- A token only exists once a refresh has been claimed, so the cache is populated the way
-- production populates it rather than by reaching past the handshake.
select api.bkash_claim_refresh(
  (select id from private.secret_bundles where subject_kind = 'gateway'), 'sandbox');

select api.bkash_store_token(
  (select id from private.secret_bundles where subject_kind = 'gateway'),
  'sandbox', 'cached-id-token', 'cached-refresh', 3600);

select is(
  (select count(*) from private.bkash_tokens),
  1::bigint,
  'the gateway bundle has a cached token'
);

select lives_ok(
  $$select private.store_credential_bundle(
      'ai_provider', '11111111-1111-4111-8111-111111111111'::uuid, 'test_ai_provider',
      jsonb_build_object('model', 'third-model'))$$,
  'an AI credential can be rotated afterwards'
);

select is(
  (select count(*) from private.bkash_tokens),
  1::bigint,
  'and rotating it leaves the payment token cache alone'
);

-- ---------------------------------------------------------------------------
-- Still write-only
-- ---------------------------------------------------------------------------
-- The vault indirection survives generalization: no role that can reach a bundle can read
-- what is in it, whichever kind it belongs to.

select is(
  test_data.as_role('authenticated', $$select api.secret_bundle_open(
      (select id from private.secret_bundles where subject_kind = 'ai_provider'))$$) ->> 'state',
  '42501',
  'a signed-in user cannot read an AI credential back'
);

select is(
  test_data.as_role('anon', $$select api.secret_bundle_open(
      (select id from private.secret_bundles where subject_kind = 'ai_provider'))$$) ->> 'state',
  '42501',
  'nor can an anonymous caller'
);

select * from finish();

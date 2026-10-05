-- The owner's AI credentials.
--
-- The claims in `20261005040000_ai_credentials.sql`, asserted directly.
--
-- This file is about the *surface*, and the surface has three claims worth testing that the
-- writer's tests could not make:
--
--   1. A provider cannot be switched to without its credentials in the same save. The writer
--      would otherwise half-apply the change - merge the old secret, keep only the new
--      provider's declared keys, and hand back a bundle that looks configured and is not.
--   2. Nothing that reads the form can read a secret. `admin_ai_settings` returns existence,
--      never values, and the providers list is field labels.
--   3. Staff cannot reach any of it. The gateway form is staff-readable on purpose; the AI
--      credential page is not, and these assertions are what keep that a decision rather
--      than an oversight.
--
-- As in the previous file, privileges are asserted by asking the role's ability to execute,
-- because the harness runs statements as a superuser and `throws_ok` would prove nothing.

select plan(33);

select test_data.reset();

select test_data.link('model7', 500, false);

select test_data.as_user(test_data.owner());

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------
-- One AI provider, seeded, with a field schema the form renders. Not a hardcoded list in the
-- RPC: a second provider later is a seed insert rather than a deploy.

select is(
  (select count(*) from api.admin_ai_providers()),
  1::bigint,
  'the shop starts with one model provider to choose from'
);

select is(
  (select slug from api.admin_ai_providers()),
  'openai_compatible',
  'and it is the OpenAI-compatible one, which covers the hosted APIs and a local server'
);

select is(
  (select jsonb_array_length(fields) from api.admin_ai_providers()),
  3,
  'it declares a key, a base URL and a model'
);

select is(
  (select count(*) from api.admin_ai_providers() where fields @> '[{"key":"api_key","secret":true}]'),
  1::bigint,
  'and the API key is the one field the form masks'
);

select is(
  (select count(*) from api.admin_auto_providers()),
  1::bigint,
  'while the gateway form still sees only the payment provider'
);

-- ---------------------------------------------------------------------------
-- Before anything is configured
-- ---------------------------------------------------------------------------

select is(
  (select provider from api.admin_ai_settings()),
  null,
  'no provider is chosen to begin with'
);

select is(
  (select has_credentials from api.admin_ai_settings()),
  false,
  'and no credentials exist'
);

-- The Edge Function lookup answers null rather than raising, because "not configured" has to
-- be a thing the caller can tell apart from "the key was rejected".
select test_data.as_service();

select is(
  (select count(*) from api.ai_credential_bundle()),
  0::bigint,
  'the Edge Function lookup returns no row at all when nothing is configured'
);

select throws_ok(
  $$select api.admin_upsert_ai_settings(
      jsonb_build_object('provider', 'stripe', 'credential_bundle', '{}'::jsonb))$$,
  '42501',
  'forbidden',
  'service_role cannot configure a model, only spend one'
);

select test_data.as_user(test_data.owner());

-- ---------------------------------------------------------------------------
-- Saving credentials
-- ---------------------------------------------------------------------------

select lives_ok(
  $$select api.admin_upsert_ai_settings(jsonb_build_object(
      'provider', 'openai_compatible',
      'credential_bundle', jsonb_build_object(
        'api_key', '  sk-live-secret  ', 'base_url', 'https://api.example.test/v1',
        'model', 'small-model')))$$,
  'the owner can configure a provider and its credentials'
);

select is(
  (select provider from api.admin_ai_settings()),
  'openai_compatible',
  'the provider is selected'
);

select is(
  (select has_credentials from api.admin_ai_settings()),
  true,
  'and the form can tell a credential exists'
);

select test_data.as_service();

select ok(
  (select bundle from api.ai_credential_bundle()) is not null,
  'the Edge Function can now resolve a bundle'
);

select is(
  (select provider from api.ai_credential_bundle()),
  'openai_compatible',
  'and is told which provider the bundle belongs to, which it cannot read for itself'
);

-- Read back through the two RPCs an Edge Function has, rather than by selecting from
-- `vault.decrypted_secrets` directly. That table is the vault owner's, not the reader's, and
-- going around the sanctioned path would make this file assert something the function cannot
-- actually do.
select is(
  api.secret_bundle_open((select bundle from api.ai_credential_bundle())) ->> 'api_key',
  'sk-live-secret',
  'the key is stored trimmed by the shared writer'
);

select is(
  (select subject_kind
   from private.secret_bundles
   where id = (select bundle from api.ai_credential_bundle())),
  'ai_provider',
  'and the bundle is keyed by the kind, not by a gateway'
);

-- ---------------------------------------------------------------------------
-- Switching provider is the trap
-- ---------------------------------------------------------------------------
-- The writer merges into the existing secret and then keeps only the new provider's declared
-- keys. Switching without resending therefore drops the old provider's fields and never adds
-- the new provider's required ones - a bundle that reads as configured and fails at the first
-- request. Refused here, where the message can name the problem.
--
-- Registered here rather than seeded, to make the point that the guard reads the new provider's
-- own field list: this one declares different keys, so it is a real switch and not a re-save.

select test_data.as_user(test_data.owner());

insert into private.auto_providers (slug, subject_kind, name_en, fields, sort_order)
values (
  'anthropic_direct', 'ai_provider', 'Anthropic direct', '[{"key":"api_key","secret":true}]'::jsonb,
  20
);

select throws_ok(
  $$select api.admin_upsert_ai_settings(jsonb_build_object('provider', 'anthropic_direct'))$$,
  '22023',
  'changing the AI provider requires sending all of its credentials in the same save',
  'switching provider without its credentials is refused rather than half-applied'
);

select throws_ok(
  $$select api.admin_upsert_ai_settings(jsonb_build_object(
      'provider', 'anthropic_direct',
      'credential_bundle', jsonb_build_object('model', 'claude')))$$,
  '22023',
  'changing the AI provider requires sending all of its credentials in the same save',
  'and a payload that is not empty is not enough: the new provider asks for a key this one does not have'
);

select is(
  (select provider from api.admin_ai_settings()),
  'openai_compatible',
  'so the old provider is still selected'
);

select test_data.as_service();

select is(
  api.secret_bundle_open((select bundle from api.ai_credential_bundle())) ->> 'api_key',
  'sk-live-secret',
  'with its credential untouched by the refused change'
);

-- ---------------------------------------------------------------------------
-- Rotation, and the merge the form depends on
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.owner());

select lives_ok(
  $$select api.admin_upsert_ai_settings(jsonb_build_object(
      'provider', 'openai_compatible',
      'credential_bundle', jsonb_build_object('model', 'bigger-model')))$$,
  'a save that changes one field is accepted'
);

select test_data.as_service();

select is(
  api.secret_bundle_open((select bundle from api.ai_credential_bundle())) ->> 'api_key',
  'sk-live-secret',
  'the key survives a save that never mentioned it, which is what the masked form relies on'
);

select is(
  api.secret_bundle_open((select bundle from api.ai_credential_bundle())) ->> 'model',
  'bigger-model',
  'and the one field it did mention is written'
);

select is(
  (select count(*) from private.secret_bundles where subject_kind = 'ai_provider'),
  1::bigint,
  'still one bundle, not a second one'
);

-- ---------------------------------------------------------------------------
-- Staff cannot reach any of this
-- ---------------------------------------------------------------------------
-- A provider and its credential are saved at this point, so these assertions are about a real
-- configuration and not about an empty table that happens to be hidden.
--
-- `test_data.admin_auto_providers` is staff-readable on purpose: rendering the automatic-gateway
-- form needs the field schema and staff already reach the gateway pages. The AI credential page
-- is a different question, and these are the assertions that keep it answered deliberately.

select test_data.as_user(test_data.new_staff('staff'));

select is(
  (select provider from api.admin_ai_settings()),
  null,
  'a staff member sees no provider, even though one is configured'
);

select is(
  (select has_credentials from api.admin_ai_settings()),
  false,
  'and no hint that a credential exists'
);

select is(
  (select count(*) from api.admin_ai_providers()),
  0::bigint,
  'or even the list of providers to pick from'
);

select throws_ok(
  $$select api.admin_upsert_ai_settings(
      jsonb_build_object('provider', 'openai_compatible'))$$,
  '42501',
  'forbidden',
  'but they cannot write through it either'
);

-- Privileges rather than behaviour, because the harness runs the statements above as a superuser
-- and a raised exception alone would not prove which role is stopped.
select test_data.can_execute('authenticated', 'api.admin_upsert_ai_settings(jsonb)'),
  true,
  'a signed-in user can execute the writer, so the owner check has to be inside it'
;

select test_data.can_execute('anon', 'api.admin_upsert_ai_settings(jsonb)'),
  false,
  'and an anonymous caller cannot execute it at all'
;

select test_data.can_execute('authenticated', 'api.ai_credential_bundle()'),
  false,
  'a signed-in user cannot resolve the bundle the Edge Function needs'
;

select test_data.can_execute('anon', 'api.ai_credential_bundle()'),
  false,
  'nor can an anonymous one'
;

select test_data.can_execute('service_role', 'api.ai_credential_bundle()'),
  true,
  'service_role, which runs the function, can'
;

-- ---------------------------------------------------------------------------
-- Turning it off
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.owner());

select lives_ok(
  $$select api.admin_upsert_ai_settings(jsonb_build_object('provider', null))$$,
  'the owner can clear the provider'
);

select is(
  (select has_credentials from api.admin_ai_settings()),
  false,
  'and the credential is retired rather than orphaned in the vault'
);

select test_data.as_service();

select is(
  (select count(*) from api.ai_credential_bundle()),
  0::bigint,
  'so the Edge Function lookup has no row again'
);

select is(
  (select count(*) from private.secret_bundles where subject_kind = 'ai_provider'),
  0::bigint,
  'the bundle row is gone, not left holding a live key'
);

-- ---------------------------------------------------------------------------
-- The registry guards the setting
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.owner());

select throws_ok(
  $$update private.ai_settings set provider = 'bkash_pgw'$$,
  '23514',
  'unknown ai_provider provider: bkash_pgw',
  'a payment provider is not a model provider, even though it is registered'
);

select * from finish();

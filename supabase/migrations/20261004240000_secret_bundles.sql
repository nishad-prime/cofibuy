-- Per-gateway credentials, a provider registry, and a token cache that follows them.
--
-- This reverses one decision recorded in 20261004230000: API credentials were
-- deliberately *not* per-gateway, because they lived in environment settings and the
-- form never asked for a key. That was the right call for a single merchant, and it
-- does not survive wanting a second one. Credentials now live in Supabase Vault, one
-- bundle per gateway, which means adding a merchant is a row rather than a redeploy.
--
-- It also fixes a bug the reversal would otherwise introduce. `private.bkash_tokens`
-- was keyed by `environment` alone, so two bKash gateways on different merchant
-- accounts shared one cached id_token - and a bKash token is bound to the app_key it
-- was granted with. Gateway B would have authenticated with gateway A's credentials.
-- The cache is re-keyed here to (credential_bundle, environment), deliberately on the
-- bundle rather than the gateway so two gateways sharing one merchant share one token
-- instead of duplicating it.
--
-- What is *not* changed: `api.bkash_payment_start` and the bKash session projection
-- still compare against 'bkash_pgw' literally. Those are bKash-specific functions, and
-- the check they want is "is this order's gateway the bKash one", not "is this some
-- provider". Widening them to "any registered provider" would let a Nagad gateway start
-- a bKash payment. Only the three places that validate *arbitrary input* - the two
-- table constraints and `admin_upsert_gateway` - become registry lookups.

-- ---------------------------------------------------------------------------
-- The provider registry
-- ---------------------------------------------------------------------------

-- A row per automatic capture backend. `fields` is the fixed detail schema that drives
-- the admin form, so adding a provider with its own credentials is a row here plus
-- settlement code, not a new Vue form.
create table private.auto_providers (
  slug text primary key,
  name_en text not null,
  name_bn text,
  fields jsonb not null default '[]'::jsonb,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Slugs are lower_snake_case because they end up in function names and in the
  -- settlement RPC's dispatch, not because they are shown to anybody.
  constraint auto_providers_slug_shape check (slug ~ '^[a-z][a-z0-9_]{1,39}$'),
  constraint auto_providers_name_en_present check (btrim(name_en) <> ''),
  constraint auto_providers_fields_is_array check (jsonb_typeof(fields) = 'array')
);

comment on table private.auto_providers is
  'Registry of automatic payment backends. A gateway row points at one with '
  'provider = slug; fields describes the credentials that backend needs.';

create trigger auto_providers_touch
  before update on private.auto_providers
  for each row
  execute function private.touch_updated_at();

insert into private.auto_providers (slug, name_en, name_bn, fields, sort_order)
values (
  'bkash_pgw',
  'bKash Payment Gateway',
  null,
  '[
    {"key":"username","label_en":"Username","secret":false},
    {"key":"password","label_en":"Password","secret":true},
    {"key":"app_key","label_en":"App key","secret":true},
    {"key":"app_secret","label_en":"App secret","secret":true}
  ]'::jsonb,
  10
);

-- ---------------------------------------------------------------------------
-- Secret bundles
-- ---------------------------------------------------------------------------

-- One bundle of secrets, referenced by (kind, subject) rather than by a column on the
-- subject. A column on `public.payment_gateways` would be a public, readable pointer to
-- the store holding that gateway's merchant credentials, and the join here costs one
-- indexed lookup on a table only Edge Functions read.
create table private.secret_bundles (
  id uuid primary key default gen_random_uuid(),
  subject_kind text not null,
  subject_id uuid not null,
  vault_secret_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint secret_bundles_subject_kind_known
    check (subject_kind in ('gateway', 'ai_provider')),
  -- One bundle per subject. Two bundles for one gateway would mean two caches and two
  -- rotations to reason about, which is the failure this whole design removes.
  constraint secret_bundles_subject_unique unique (subject_kind, subject_id)
);

comment on table private.secret_bundles is
  'Vault-backed secrets for one subject. The pointer is here; the value is in the vault, '
  'reachable only through api.secret_bundle_open by service_role.';

create trigger secret_bundles_touch
  before update on private.secret_bundles
  for each row
  execute function private.touch_updated_at();

create index secret_bundles_subject_idx
  on private.secret_bundles (subject_kind, subject_id);

-- ---------------------------------------------------------------------------
-- Environment is operational config, not a secret
-- ---------------------------------------------------------------------------

-- sandbox before live, deliberately. An operator who never picks one gets a gateway
-- that cannot take real money, rather than one that does.
alter table public.payment_gateways
  add column environment text not null default 'sandbox',
  add constraint payment_gateways_environment_known
    check (environment in ('sandbox', 'live'));

comment on column public.payment_gateways.environment is
  'Which bKash environment this gateway talks to. Not secret; it selects the base URL '
  'and is shown to the operator so the right credentials go with the right one.';

-- ---------------------------------------------------------------------------
-- Registry-backed validation
-- ---------------------------------------------------------------------------

-- A CHECK constraint cannot hold a subquery, so the provider allowlist moves to a
-- trigger. The guarantee is worth keeping: the settlement RPC trusts this value to
-- choose a payment backend, so a typo has to fail on the row rather than at an HTTP
-- call with a live order attached.
--
-- The SQLSTATE stays 23514 rather than becoming 22023. Callers already branch on check
-- violation here, and a trigger that quietly changed the code would break them while
-- looking like an internal refactor. The message improves instead: it names the provider
-- that was rejected, which the generated constraint message never did.
create or replace function private.guard_provider_known()
returns trigger
language plpgsql
as $$
begin
  if new.provider is not null and not exists (
    select 1 from private.auto_providers p
    where p.slug = new.provider and p.is_active
  ) then
    raise exception 'unknown payment provider: %', new.provider using errcode = '23514';
  end if;
  return new;
end
$$;

alter table public.payment_gateways
  drop constraint payment_gateways_provider_known;

create trigger payment_gateways_guard_provider
  before insert or update of provider on public.payment_gateways
  for each row
  execute function private.guard_provider_known();

-- Same argument for sessions: an unrecognised provider on a money row is a bug, and
-- this is where it stops.
alter table public.payment_sessions
  drop constraint payment_sessions_provider_known;

create trigger payment_sessions_guard_provider
  before insert or update of provider on public.payment_sessions
  for each row
  execute function private.guard_provider_known();

-- ---------------------------------------------------------------------------
-- Credential storage
-- ---------------------------------------------------------------------------

-- The keys a provider declares, or null when the provider is not registered.
create or replace function private.provider_field_keys(p_provider text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select array_agg(f ->> 'key' order by ord)
  from private.auto_providers p,
       lateral jsonb_array_elements(p.fields) with ordinality as f(f, ord)
  where p.slug = p_provider and p.is_active
$$;

-- Writes the bundle for one subject, validating every key against the provider schema.
--
-- Merge semantics, not replace. The admin form shows stored secrets masked and cannot
-- read them back, so an edit-save that does not touch the credentials sends an empty
-- bundle. Treating that as "replace with nothing" would erase the merchant password on
-- every unrelated save, and requiring every key on every save would fail every one of
-- them. Keys present in the payload are written, keys absent are kept, and a bundle
-- created from scratch must supply every declared key because there is nothing to keep.
create or replace function private.store_credential_bundle(
  p_subject_id uuid,
  p_provider text,
  p_bundle jsonb
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_allowed text[] := coalesce(private.provider_field_keys(p_provider), array[]::text[]);
  v_row private.secret_bundles;
  v_existing jsonb := '{}'::jsonb;
  v_merged jsonb;
  v_key text;
begin
  if v_allowed = array[]::text[] then
    raise exception 'unknown payment provider: %', p_provider using errcode = '22023';
  end if;

  -- A key the provider does not declare is either a typo or an attempt to store
  -- something the settlement code will never read. Both are refused rather than stored
  -- quietly, because a credential that looks saved but is never used is a worse state
  -- than one that is obviously missing.
  for v_key in select jsonb_object_keys(p_bundle) loop
    if not (v_allowed @> array[v_key]) then
      raise exception 'credential % is not part of %', v_key, p_provider
        using errcode = '22023';
    end if;

    if btrim(coalesce(p_bundle ->> v_key, '')) = '' then
      raise exception 'credential % cannot be blank', v_key using errcode = '22023';
    end if;
  end loop;

  select * into v_row
  from private.secret_bundles
  where subject_kind = 'gateway' and subject_id = p_subject_id;

  if v_row.id is null then
    foreach v_key in array v_allowed loop
      if not (p_bundle ? v_key) then
        raise exception 'credential % is required for %', v_key, p_provider
          using errcode = '22023';
      end if;
    end loop;

    v_merged := p_bundle;
  else
    -- ::jsonb on the way out of Vault. Vault stores an opaque text blob and never parses it,
    -- so the whole merge below works in jsonb and every value written back is `jsonb::text`.
    -- Casting here rather than making v_existing text keeps `||`, `?` and `is distinct from`
    -- as jsonb operations, which is the only reason they type-check.
    select d.secret::jsonb into v_existing
    from vault.decrypted_secrets d
    where d.id = v_row.vault_secret_id;

    -- A row whose vault secret is gone is treated as absent rather than trusted, so a
    -- re-save rebuilds it instead of failing inside vault.update_secret on a null id.
    if v_row.vault_secret_id is null or v_existing is null then
      foreach v_key in array v_allowed loop
        if not (p_bundle ? v_key) then
          raise exception 'credential % is required for %', v_key, p_provider
            using errcode = '22023';
        end if;
      end loop;

      v_merged := p_bundle;
      perform vault.update_secret(v_row.vault_secret_id, v_merged::text);
      return v_row.id;
    end if;

    v_merged := v_existing || p_bundle;
  end if;

  if v_row.id is null then
    insert into private.secret_bundles (subject_kind, subject_id, vault_secret_id)
    values (
      'gateway',
      p_subject_id,
      vault.create_secret(
        v_merged::text,
        'gateway:' || p_subject_id::text,
        'Payment gateway credentials for gateway ' || p_subject_id::text
      )
    )
    returning * into v_row;
  else
    perform vault.update_secret(v_row.vault_secret_id, v_merged::text);

    -- Rotation is not only a vault update. The cached id_token was minted from the
    -- app_secret being replaced, so leaving it in place means the next request
    -- authenticates with a token from a retired credential and fails as an opaque
    -- provider error rather than as "you changed your key".
    if v_merged is distinct from v_existing then
      delete from private.bkash_tokens where credential_bundle_id = v_row.id;
    end if;
  end if;

  return v_row.id;
end
$$;

revoke all on function private.store_credential_bundle(uuid, text, jsonb)
  from public, anon, authenticated;

-- The bundle for a gateway, or null when credentials are not configured.
--
-- Service-role only, and deliberately not a column join any admin RPC exposes. This is
-- the lookup an Edge Function makes before talking to a provider, and it has to be the
-- thing that returns null when an operator has not finished setting a gateway up, so
-- "not configured" surfaces as a clear error rather than as a 401 from bKash.
create or replace function api.gateway_credential_bundle(p_gateway_id uuid)
returns uuid
language sql
volatile
security definer
set search_path = ''
as $$
  select b.id
  from public.payment_gateways g
  left join private.secret_bundles b
    on b.subject_kind = 'gateway' and b.subject_id = g.id
  where g.id = p_gateway_id
$$;

revoke all on function api.gateway_credential_bundle(uuid) from public, anon, authenticated;
grant execute on function api.gateway_credential_bundle(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Opening a bundle
-- ---------------------------------------------------------------------------

-- The single path from a bundle id to plaintext, and deliberately service_role only.
--
-- No `authenticated` grant, no admin RPC that wraps it, no view over
-- vault.decrypted_secrets. A customer-facing or admin-facing route to a merchant
-- password is the one thing this design must not have, so the surface is one function
-- that Edge Functions call with their own service-role key.
create or replace function api.secret_bundle_open(p_bundle_id uuid)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  -- Vault's `secret` is text. Without ::jsonb this function declares jsonb and returns text,
  -- which Postgres rejects at create time (42P13) — and only on a project with the real Vault.
  -- Callers cast the result to a typed shape, so it has to arrive as jsonb, not a JSON string.
  select d.secret::jsonb
  from private.secret_bundles b
  join vault.decrypted_secrets d on d.id = b.vault_secret_id
  where b.id = p_bundle_id
$$;

revoke all on function api.secret_bundle_open(uuid) from public, anon, authenticated;
grant execute on function api.secret_bundle_open(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Provider registry, read by the admin form
-- ---------------------------------------------------------------------------

-- Staff-readable on purpose: rendering the automatic-gateway form needs the field
-- schema, and staff already reach the gateway pages. Nothing here is a secret, and the
-- `fields` rows carry labels rather than values.
create or replace function api.admin_auto_providers()
returns table (
  slug text,
  name_en text,
  name_bn text,
  fields jsonb,
  sort_order integer,
  is_active boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.slug, p.name_en, p.name_bn, p.fields, p.sort_order, p.is_active
  from private.auto_providers p
  order by p.sort_order, p.slug
$$;

revoke all on function api.admin_auto_providers() from public, anon;
grant execute on function api.admin_auto_providers() to authenticated;

-- ---------------------------------------------------------------------------
-- Token cache, re-keyed
-- ---------------------------------------------------------------------------

-- The three environment-keyed functions are dropped rather than replaced.
--
-- `create or replace` matches on the argument list, so defining the bundle-keyed versions
-- below leaves the environment-keyed ones in place under their own signatures, still
-- granted to service_role and still callable. They look a cached token up by environment
-- alone, which after this migration means "whichever merchant happens to sort first" —
-- so gateway A would be handed gateway B's id_token, and B would present it to bKash and
-- fail as an intermittent auth error. Dropping the overloads is the only thing standing
-- between this migration and that bug, so it is asserted rather than assumed; see
-- 13_secret_bundles.sql.
drop function if exists api.bkash_token_state(text);
drop function if exists api.bkash_claim_refresh(text);
drop function if exists api.bkash_store_token(text, text, text, integer);

-- Rows under the old key cannot be attributed to a bundle: the credentials they were
-- minted from were environment settings, shared by every gateway. There is no correct
-- way to adopt them, and keeping any would risk handing gateway A's token to gateway
-- B on the very first request. Deleting them costs one Grant Token call.
delete from private.bkash_tokens;

alter table private.bkash_tokens
  add column credential_bundle_id uuid references private.secret_bundles (id) on delete cascade;

alter table private.bkash_tokens
  drop constraint bkash_tokens_pkey;

-- The primary key carries NOT NULL with it, so the column does not need its own.
alter table private.bkash_tokens
  add constraint bkash_tokens_pkey primary key (credential_bundle_id, environment);

comment on table private.bkash_tokens is
  'Cached bKash id_token per credential bundle and environment. Keyed on the bundle rather '
  'than the environment because a token belongs to an app_key: two gateways on different '
  'merchant accounts must never share one. A row with an empty id_token is a placeholder '
  'written by the first caller to claim a refresh.';

create index bkash_tokens_by_bundle_idx
  on private.bkash_tokens (credential_bundle_id);

-- ---------------------------------------------------------------------------
-- Token RPCs, bundle-scoped
-- ---------------------------------------------------------------------------

create or replace function api.bkash_token_state(p_bundle_id uuid, p_environment text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row private.bkash_tokens;
begin
  if p_environment not in ('sandbox', 'live') then
    raise exception 'unknown bkash environment: %', p_environment using errcode = '22023';
  end if;

  select * into v_row
  from private.bkash_tokens
  where credential_bundle_id = p_bundle_id and environment = p_environment;

  if not found or v_row.id_token = '' then
    -- No usable token yet. `bootstrap` distinguishes "fetch the first one" from
    -- "rotate an existing one", because refresh needs the refresh token we do not have.
    --
    -- `refreshing` is reported here too, and that is the whole reason this branch is
    -- not an early return that forgets it. Claiming the lease writes a placeholder row
    -- with an empty token, so a concurrent caller landing in this branch during the very
    -- first bootstrap would otherwise see nothing held and call Grant Token as well.
    -- Two concurrent first-time customers then spend two of the two calls allowed per
    -- hour, and the shop cannot take another payment until the window rolls over.
    return jsonb_build_object(
      'usable', false,
      'bootstrap', true,
      'refreshing', found and v_row.refresh_claimed_until > now()
    );
  end if;

  return jsonb_build_object(
    'usable', true,
    'bootstrap', false,
    'id_token', v_row.id_token,
    -- Five minutes of headroom, not zero. A token that expires while a create is in
    -- flight fails as an opaque 2001, and the customer sees a payment error rather
    -- than a retry.
    'needs_refresh', v_row.expires_at <= now() + interval '5 minutes',
    'refreshing', v_row.refresh_claimed_until > now()
  );
end
$$;

revoke all on function api.bkash_token_state(uuid, text) from public, anon, authenticated;
grant execute on function api.bkash_token_state(uuid, text) to service_role;

create or replace function api.bkash_claim_refresh(p_bundle_id uuid, p_environment text)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_claimed boolean;
begin
  if p_environment not in ('sandbox', 'live') then
    raise exception 'unknown bkash environment: %', p_environment using errcode = '22023';
  end if;

  -- The insert arm writes the placeholder for a first-ever call; the update arm takes
  -- the lease only if it is free. When the `where` fails no row comes back, so
  -- coalesce reports false rather than letting everyone refresh.
  --
  -- The `with` has to be the whole statement: a data-modifying CTE is not allowed to
  -- sit inside a sub-expression, so this selects into a variable rather than being
  -- wrapped in coalesce at the return.
  with claimed as (
    insert into private.bkash_tokens as t
      (credential_bundle_id, environment, id_token, refresh_token, expires_at,
       refresh_claimed_until)
    values (p_bundle_id, p_environment, '', '', now(), now() + interval '60 seconds')
    on conflict (credential_bundle_id, environment) do update
      set refresh_claimed_until = now() + interval '60 seconds'
      where t.refresh_claimed_until <= now()
    returning true
  )
  select coalesce(bool_or(true), false) into v_claimed from claimed;

  return v_claimed;
end
$$;

revoke all on function api.bkash_claim_refresh(uuid, text) from public, anon, authenticated;
grant execute on function api.bkash_claim_refresh(uuid, text) to service_role;

create or replace function api.bkash_store_token(
  p_bundle_id uuid,
  p_environment text,
  p_id_token text,
  p_refresh_token text,
  p_expires_in integer
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_environment not in ('sandbox', 'live') then
    raise exception 'unknown bkash environment: %', p_environment using errcode = '22023';
  end if;

  if btrim(coalesce(p_id_token, '')) = '' or btrim(coalesce(p_refresh_token, '')) = '' then
    raise exception 'bkash returned an empty token' using errcode = '22023';
  end if;

  -- A grant or refresh that omits expires_in still means one hour; assuming a much
  -- longer life would leave us calling a dead token until something failed visibly.
  update private.bkash_tokens
  set id_token = p_id_token,
      refresh_token = p_refresh_token,
      expires_at = now() + make_interval(secs => coalesce(p_expires_in, 3600)),
      refresh_claimed_until = now(),
      updated_at = now()
  where credential_bundle_id = p_bundle_id and environment = p_environment;

  if not found then
    raise exception 'no bkash token row to store into; claim the refresh first'
      using errcode = '22023';
  end if;
end
$$;

revoke all on function api.bkash_store_token(uuid, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function api.bkash_store_token(uuid, text, text, text, integer)
  to service_role;

-- ---------------------------------------------------------------------------
-- Gateway writes carry credentials
-- ---------------------------------------------------------------------------

create or replace function api.admin_upsert_gateway(p_gateway jsonb)
returns public.payment_gateways
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid := nullif(p_gateway ->> 'id', '')::uuid;
  v_row public.payment_gateways;
  v_provider text := nullif(btrim(p_gateway ->> 'provider'), '');
  v_kind text := nullif(btrim(p_gateway ->> 'kind'), '');
  v_environment text := coalesce(nullif(btrim(p_gateway ->> 'environment'), ''), 'sandbox');
  -- A jsonb null is not a SQL null, so `coalesce` alone would pass a literal `null` to
  -- the validators and fail on it. An untouched editor sends exactly that, and "you left
  -- this blank" must mean "empty", not "malformed".
  v_account_fields jsonb := coalesce(nullif(p_gateway -> 'account_fields', 'null'::jsonb), '[]'::jsonb);
  v_evidence_fields jsonb := coalesce(nullif(p_gateway -> 'evidence_fields', 'null'::jsonb), '[]'::jsonb);
  v_credentials jsonb := coalesce(
    nullif(p_gateway -> 'credential_bundle', 'null'::jsonb),
    '{}'::jsonb
  );
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_kind is null then
    raise exception 'a payment method needs a kind' using errcode = '22023';
  end if;

  if length(v_kind) > 48 then
    raise exception 'kind is longer than 48 characters' using errcode = '22023';
  end if;

  if v_environment not in ('sandbox', 'live') then
    raise exception 'unknown gateway environment: %', v_environment using errcode = '22023';
  end if;

  -- The registry replaces the hardcoded allowlist. A disabled provider is refused too,
  -- because it would otherwise stay writable and then fail at settlement.
  if v_provider is not null and not exists (
    select 1 from private.auto_providers p
    where p.slug = v_provider and p.is_active
  ) then
    raise exception 'unknown payment provider: %', v_provider using errcode = '22023';
  end if;

  -- A manual method has nowhere to put a merchant password, and an automatic one
  -- without credentials cannot take a payment. Both directions are refused here rather
  -- than left to fail at checkout.
  if v_provider is null and v_credentials <> '{}'::jsonb then
    raise exception 'a manual payment method does not take credentials'
      using errcode = '22023';
  end if;

  perform private.validate_account_fields(v_account_fields);

  if v_id is null then
    insert into public.payment_gateways (
      kind, account_number, account_name, account_fields,
      name_en, name_bn,
      instructions_md_en, instructions_md_bn,
      reference_prompt_en, reference_prompt_bn, supports_reference,
      evidence_fields, is_active, sort_order, provider, environment
    )
    values (
      v_kind,
      p_gateway ->> 'account_number',
      p_gateway ->> 'account_name',
      v_account_fields,
      p_gateway ->> 'name_en',
      nullif(p_gateway ->> 'name_bn', ''),
      nullif(p_gateway ->> 'instructions_md_en', ''),
      nullif(p_gateway ->> 'instructions_md_bn', ''),
      nullif(p_gateway ->> 'reference_prompt_en', ''),
      nullif(p_gateway ->> 'reference_prompt_bn', ''),
      coalesce((p_gateway ->> 'supports_reference')::boolean, false),
      v_evidence_fields,
      coalesce((p_gateway ->> 'is_active')::boolean, true),
      coalesce((p_gateway ->> 'sort_order')::integer, 0),
      v_provider,
      v_environment
    )
    returning * into v_row;
  else
    update public.payment_gateways
    set kind = v_kind,
        account_fields = v_account_fields,
        account_number = p_gateway ->> 'account_number',
        account_name = p_gateway ->> 'account_name',
        name_en = p_gateway ->> 'name_en',
        name_bn = nullif(p_gateway ->> 'name_bn', ''),
        instructions_md_en = nullif(p_gateway ->> 'instructions_md_en', ''),
        instructions_md_bn = nullif(p_gateway ->> 'instructions_md_bn', ''),
        reference_prompt_en = nullif(p_gateway ->> 'reference_prompt_en', ''),
        reference_prompt_bn = nullif(p_gateway ->> 'reference_prompt_bn', ''),
        supports_reference = coalesce((p_gateway ->> 'supports_reference')::boolean, false),
        evidence_fields = v_evidence_fields,
        is_active = coalesce((p_gateway ->> 'is_active')::boolean, true),
        sort_order = coalesce((p_gateway ->> 'sort_order')::integer, 0),
        provider = v_provider,
        environment = v_environment
    where id = v_id
    returning * into v_row;
  end if;

  if not found then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  -- Written after the row exists because the bundle is keyed by gateway id. Swapping an
  -- automatic method back to manual retires the bundle rather than leaving an orphan
  -- holding a live merchant credential.
  --
  -- Credentials are not *required* here. A gateway with a provider and no bundle is a
  -- legitimate "not finished setting it up" state, and refusing it would make the form
  -- unusable before the operator has bKash to hand. It fails clearly at payment time
  -- instead, via api.gateway_credential_bundle returning null.
  if v_provider is not null and v_credentials <> '{}'::jsonb then
    perform private.store_credential_bundle(v_row.id, v_provider, v_credentials);
  elsif v_provider is null then
    delete from private.secret_bundles
    where subject_kind = 'gateway' and subject_id = v_row.id;
  end if;

  return v_row;
end
$$;

revoke all on function api.admin_upsert_gateway(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_gateway(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

-- Neither table is readable by anyone through PostgREST. The registry is reachable only
-- through `api.admin_auto_providers`, and the bundles only through the service_role-only
-- opener.
revoke all on private.secret_bundles from public, anon, authenticated;
revoke all on private.auto_providers from public, anon, authenticated;
grant usage on schema private to service_role;

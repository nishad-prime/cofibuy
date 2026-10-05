-- One credential writer, for every subject that has credentials.
--
-- `private.secret_bundles` has reserved `ai_provider` as a subject kind since it was
-- created, and the CHECK constraint has accepted it ever since. Nothing could write one:
-- `store_credential_bundle` took a subject id and hardcoded `'gateway'` in three places, so
-- the reserved slot was a comment.
--
-- This migration spends it, and in doing so fixes a bug that only shows up once a second
-- kind exists.
--
-- ---------------------------------------------------------------------------
-- The registry learns what kind it is registering
-- ---------------------------------------------------------------------------
--
-- `auto_providers` described itself as a registry of automatic *payment* backends, which
-- was true and is about to stop being true. The row shape does not change - a slug, a name,
-- and the field schema that drives a credential form - so the discriminator goes on the row
-- rather than into a second table that would have to be joined to get the same answer.
--
-- The column has no default. `add column ... default 'gateway'` is how a table grows a
-- silent wrong answer: every insert that forgets the kind lands on 'gateway' and nobody
-- looks again. Making it explicit costs one word per insert.

alter table private.auto_providers
  add column subject_kind text not null default 'gateway';

alter table private.auto_providers
  alter column subject_kind drop default;

alter table private.auto_providers
  add constraint auto_providers_subject_kind_known
  check (subject_kind in ('gateway', 'ai_provider'));

comment on column private.auto_providers.subject_kind is
  'Which kind of subject this provider supplies credentials to. A gateway row is checked '
  'against gateway providers only, so registering an ai_provider can never make its slug a '
  'usable payment provider.';

comment on table private.auto_providers is
  'Registry of credential-bearing backends, discriminated by subject_kind. A gateway row '
  'points at one with provider = slug and subject_kind = gateway; fields describes the '
  'credentials that backend needs.';

-- ---------------------------------------------------------------------------
-- The collision this closes
-- ---------------------------------------------------------------------------
--
-- One registry means one slug namespace, so without the discriminator an AI provider would
-- become a valid `payment_gateways.provider` the moment it was registered. A gateway would
-- then accept a customer's money, route it by weight to a kind that has no settlement code,
-- and fail at capture time instead of at setup. The guard below is the boundary, and it now
-- asks the kind as well as the slug.

create or replace function private.guard_provider_known()
returns trigger
language plpgsql
as $$
begin
  if new.provider is not null and not exists (
    select 1 from private.auto_providers p
    where p.slug = new.provider and p.is_active and p.subject_kind = 'gateway'
  ) then
    raise exception 'unknown payment provider: %', new.provider using errcode = '23514';
  end if;
  return new;
end;
$$;

-- The keys a provider declares for one kind of subject, or null when it declares none.
-- Null is not "unknown provider" and "wrong kind" at the same time to the caller: the
-- writer distinguishes them, because they are different mistakes with different fixes.
create or replace function private.provider_field_keys(p_provider text, p_subject_kind text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select array_agg(f ->> 'key' order by ord)
  from private.auto_providers p,
       lateral jsonb_array_elements(p.fields) with ordinality as f(f, ord)
  where p.slug = p_provider and p.is_active and p.subject_kind = p_subject_kind
$$;

drop function if exists private.provider_field_keys(text);

-- ---------------------------------------------------------------------------
-- One writer, for every kind
-- ---------------------------------------------------------------------------
--
-- Restated from the bKash migration, which restated it from the credential migration. Three
-- changes and one behaviour fix:
--
--   1. The kind is a parameter, so the same validation, the same merge semantics, and the
--      same trimming apply to every credential in the system. One writer means one place to
--      get "a blank value is refused" right.
--   2. The bKash token purge is now gated on the kind. It was harmless before, because the
--      only kind was gateway and only gateways have tokens - but a generic function that
--      unconditionally deletes from a payment table is one refactor away from a bug, and the
--      guard reads as the truth it is.
--   3. Vault naming carries the kind, so a bundle is identifiable in the vault's own listing
--      rather than only through this table.
--
-- The gateway error message is preserved verbatim because callers and three test files
-- branch on it. A non-gateway kind gets its own wording rather than being told about a
-- payment provider it has nothing to do with.

create or replace function private.store_credential_bundle(
  p_subject_kind text,
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
  v_allowed text[] := coalesce(private.provider_field_keys(p_provider, p_subject_kind), array[]::text[]);
  v_row private.secret_bundles;
  v_existing jsonb := '{}'::jsonb;
  v_trimmed jsonb := '{}'::jsonb;
  v_source jsonb;
  v_merged jsonb := '{}'::jsonb;
  v_key text;
begin
  -- Checked before anything else. The CHECK constraint on `secret_bundles` would refuse an
  -- unknown kind eventually, but only after the key lookup has already reported it as an
  -- unknown provider - which sends the reader to the registry instead of to the caller that
  -- passed the wrong word.
  if p_subject_kind not in ('gateway', 'ai_provider') then
    raise exception 'unknown credential subject kind: %', p_subject_kind using errcode = '22023';
  end if;

  if v_allowed = array[]::text[] then
    if p_subject_kind = 'gateway' then
      raise exception 'unknown payment provider: %', p_provider using errcode = '22023';
    end if;

    raise exception 'unknown % provider: %', p_subject_kind, p_provider using errcode = '22023';
  end if;

  -- A key the provider does not declare is either a typo or an attempt to store
  -- something the caller will never read. Both are refused rather than stored quietly,
  -- because a credential that looks saved but is never used is a worse state than one
  -- that is obviously missing.
  --
  -- `v_trimmed` is built as the keys are validated, so what is checked and what is stored
  -- cannot drift.
  --
  -- The blank check runs on the trimmed value. A secret of `'   '` must still be refused,
  -- and `btrim` is what makes that the same question as "is this value empty" rather than
  -- a second rule that has to be remembered alongside the first.
  --
  -- A non-string value is refused rather than coerced. `->>` would happily turn a number
  -- into text and store `'42'`, which then fails downstream as an opaque error naming
  -- neither field. Refusing here names the field.
  for v_key in select jsonb_object_keys(p_bundle) loop
    if not (v_allowed @> array[v_key]) then
      raise exception 'credential % is not part of %', v_key, p_provider
        using errcode = '22023';
    end if;

    if jsonb_typeof(p_bundle -> v_key) <> 'string' then
      raise exception 'credential % must be a string', v_key using errcode = '22023';
    end if;

    if btrim(coalesce(p_bundle ->> v_key, '')) = '' then
      raise exception 'credential % cannot be blank', v_key using errcode = '22023';
    end if;

    v_trimmed := v_trimmed || jsonb_build_object(v_key, btrim(p_bundle ->> v_key));
  end loop;

  select * into v_row
  from private.secret_bundles
  where subject_kind = p_subject_kind and subject_id = p_subject_id;

  if v_row.id is null then
    foreach v_key in array v_allowed loop
      if not (v_trimmed ? v_key) then
        raise exception 'credential % is required for %', v_key, p_provider
          using errcode = '22023';
      end if;
    end loop;

    v_source := v_trimmed;
  else
    select d.secret::jsonb into v_existing
    from vault.decrypted_secrets d
    where d.id = v_row.vault_secret_id;

    -- A row whose vault secret is gone is treated as absent rather than trusted, so a
    -- re-save rebuilds it instead of failing inside vault.update_secret on a null id.
    if v_row.vault_secret_id is null or v_existing is null then
      foreach v_key in array v_allowed loop
        if not (v_trimmed ? v_key) then
          raise exception 'credential % is required for %', v_key, p_provider
            using errcode = '22023';
        end if;
      end loop;

      v_source := v_trimmed;
    else
      v_source := v_existing || v_trimmed;
    end if;
  end if;

  -- Every declared key is trimmed on the way out, not only the ones this call mentioned.
  -- Keys that came from `v_existing` may have been stored by a version of this function
  -- that did not trim, so a shop that saved before that migration would keep
  -- authenticating with a value that is wrong in exactly the way it existed to remove.
  -- Re-saving normalises them, which is repair without a migration that has to decrypt
  -- and rewrite every bundle.
  --
  -- Restricted to the provider's declared keys, so a stray key in an old secret is dropped
  -- rather than laundered through here.
  foreach v_key in array v_allowed loop
    if v_source ? v_key then
      v_merged := v_merged || jsonb_build_object(v_key, btrim(v_source ->> v_key));
    end if;
  end loop;

  if v_row.id is null then
    insert into private.secret_bundles (subject_kind, subject_id, vault_secret_id)
    values (
      p_subject_kind,
      p_subject_id,
      vault.create_secret(
        v_merged::text,
        p_subject_kind || ':' || p_subject_id::text,
        'Credentials for ' || p_subject_kind || ' ' || p_subject_id::text || ' (' || p_provider || ')'
      )
    )
    returning * into v_row;
  else
    perform vault.update_secret(v_row.vault_secret_id, v_merged::text);

    -- Rotation is not only a vault update. A cached token was minted from the secret being
    -- replaced, so leaving it in place means the next request authenticates with a token
    -- from a retired credential and fails as an opaque provider error rather than as "you
    -- changed your key".
    --
    -- Gated on the kind because this function is no longer gateway-specific. Only bKash
    -- mints tokens; a bundle of any other kind has no rows here, and saying so is clearer
    -- than relying on a delete that happens to match nothing.
    --
    -- Compared against the *stored* secret rather than the incoming payload, so a save that
    -- changes nothing still purges nothing and a save that changes one key purges once.
    if p_subject_kind = 'gateway' and v_merged is distinct from v_existing then
      delete from private.bkash_tokens where credential_bundle_id = v_row.id;
    end if;
  end if;

  return v_row.id;
end;
$$;

-- The gateway-shaped signature is gone rather than kept as a wrapper. A convenience
-- overload would be callable by anything holding the revoked privilege, and a call site
-- reading `store_credential_bundle(gateway_id, ...)` would silently mean `gateway` while
-- the neighbouring call meant something else - which is the same class of bug that made
-- the environment-only token functions ambiguous in the first place.
drop function if exists private.store_credential_bundle(uuid, text, jsonb);

revoke all on function private.store_credential_bundle(text, uuid, text, jsonb)
  from public, anon, authenticated;
revoke all on function private.provider_field_keys(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The admin form keeps seeing payment providers only
-- ---------------------------------------------------------------------------
--
-- `admin_auto_providers` drives the automatic-gateway form's provider dropdown. Left
-- unfiltered it would start offering AI providers as ways to take a customer's money, which
-- is the collision above arriving through the UI instead of through a direct insert.

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
  where p.subject_kind = 'gateway'
  order by p.sort_order, p.slug
$$;

revoke all on function api.admin_auto_providers() from public, anon;
grant execute on function api.admin_auto_providers() to authenticated;

-- ---------------------------------------------------------------------------
-- The one call site, named
-- ---------------------------------------------------------------------------
--
-- `admin_upsert_gateway` is restated for two lines. `create or replace` cannot add a
-- parameter or narrow a body, so the whole function is repeated; the reason it is
-- repeated here rather than left alone is that it is the only caller of the old
-- three-argument writer, and dropping that signature would otherwise leave a function
-- that fails at runtime with "function does not exist".
--
-- Its own provider check is narrowed to gateway providers for the same reason the trigger
-- is: a registry shared with another kind must not widen what a payment method accepts.

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
  v_account_fields jsonb := coalesce(nullif(p_gateway -> 'account_fields', 'null'::jsonb), '[]'::jsonb);
  v_evidence_fields jsonb := coalesce(nullif(p_gateway -> 'evidence_fields', 'null'::jsonb), '[]'::jsonb);
  v_credentials jsonb := coalesce(nullif(p_gateway -> 'credential_bundle', 'null'::jsonb), '{}'::jsonb);
  v_weight integer := coalesce(nullif(btrim(p_gateway ->> 'weight'), '')::integer, 1);
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

  -- Checked here as well as by the trigger so the refusal names the field the operator was
  -- editing. The trigger still has to fire: `weight` is also writable by anything holding a
  -- direct connection, and this constraint is the boundary, not this function.
  if v_weight < 1 then
    raise exception 'weight must be at least 1; use is_active to disable a payment method'
      using errcode = '22023';
  end if;

  if v_provider is not null and not exists (
    select 1 from private.auto_providers p
    where p.slug = v_provider and p.is_active and p.subject_kind = 'gateway'
  ) then
    raise exception 'unknown payment provider: %', v_provider using errcode = '22023';
  end if;

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
      evidence_fields, is_active, sort_order, weight, provider, environment
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
      v_weight,
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
        weight = v_weight,
        provider = v_provider,
        environment = v_environment
    where id = v_id
    returning * into v_row;
  end if;

  if not found then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  if v_provider is not null and v_credentials <> '{}'::jsonb then
    perform private.store_credential_bundle('gateway', v_row.id, v_provider, v_credentials);
  elsif v_provider is null then
    delete from private.secret_bundles
    where subject_kind = 'gateway' and subject_id = v_row.id;
  end if;

  return v_row;
end;
$$;

revoke all on function api.admin_upsert_gateway(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_gateway(jsonb) to authenticated;

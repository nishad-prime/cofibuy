-- ---------------------------------------------------------------------------
-- Read the vault's DECRYPTED secret, not its ciphertext.
--
-- `vault.decrypted_secrets` carries both: `secret`, the encrypted blob the base
-- table stores, and `decrypted_secret`, the plaintext the view exists to expose.
-- The local stub in `00_environment.sql` mirrored this wrong - it put plaintext
-- under `secret` - so every function reading `secret` passed the whole suite and
-- handed bKash a blob of ciphertext in production. The customer-visible shape of
-- that bug: `could not open credentials ... invalid input syntax for type json`
-- on every pay attempt, with credentials that were perfectly well stored.
--
-- Both readers move to `decrypted_secret`. The stub now marks `secret` with a
-- sentinel so a wrong-column read explodes in the test database too, instead of
-- only against the real Vault.
-- ---------------------------------------------------------------------------

-- secret_bundle_open(p_bundle_id uuid) grants: "{postgres,service_role}"
CREATE OR REPLACE FUNCTION api.secret_bundle_open(p_bundle_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- The plaintext is `decrypted_secret`. Vault's `secret` column holds the CIPHERTEXT, and
  -- the local stub used to mirror this wrong - plaintext under `secret` - so a function
  -- that read the wrong column passed the whole suite and handed bKash a blob of
  -- ciphertext in production. Reading the encrypted column now fails the suite too: the
  -- stub marks it with a sentinel, so the ::jsonb cast explodes in the test database
  -- exactly as it does against the real Vault.
  select d.decrypted_secret::jsonb
  from private.secret_bundles b
  join vault.decrypted_secrets d on d.id = b.vault_secret_id
  where b.id = p_bundle_id
$function$

;

revoke all on function api.secret_bundle_open(uuid) from public, anon, authenticated;
grant execute on function api.secret_bundle_open(uuid) to service_role;

revoke all on function private.store_credential_bundle(text, uuid, text, jsonb) from public, anon, authenticated;

-- store_credential_bundle(p_subject_kind text, p_subject_id uuid, p_provider text, p_bundle jsonb) grants: "{postgres}"
CREATE OR REPLACE FUNCTION private.store_credential_bundle(p_subject_kind text, p_subject_id uuid, p_provider text, p_bundle jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    select d.decrypted_secret::jsonb into v_existing
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
$function$;

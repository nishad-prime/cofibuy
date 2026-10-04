-- Bound what the copy editor can store.
--
-- Why a separate migration: `api.admin_set_copy` was last defined in
-- 20261004130000, which is applied to the hosted project. Supabase records applied
-- migrations by version, so editing that file would change the repository and never
-- the database. A new migration is the only way the rule reaches a live project.
--
-- Both checks are raised before the insert, for the reason the label rule is: a
-- rejected write must not half-apply a batch that arrived as one call, or the
-- operator sees "saved" and a string that did not change.
--
-- 1. A length cap. The editor is a trust boundary. `private.copy_registry` already
--    refuses markdown on a label key because a reviewer who can approve orders has no
--    business rewriting what the shopfront says about taking payment; length is the same
--    class of problem one dimension over. 400 characters is about three times the longest
--    string the bundles ship (`paywall.closedBody`, 137) and five times the longest prose
--    block, which leaves room for Bangla running longer than English while still bounding
--    a heading to something that renders as a heading. Per-key limits would be tighter,
--    but they would mean eighty numbers to keep in step with the bundles - more drift
--    surface than the rule earns. Instead `supabase/tests/09_copy.sql` asserts every
--    shipped value fits inside the cap, so the number can never be set below copy that
--    already exists.
--
-- 2. A value that renders as nothing. `private.tidy_blank_to_null` already turns a
--    space-only value into NULL on write, but `btrim` with no second argument trims the
--    space alone, so a value made of a tab or a zero-width space is stored as an override
--    that displays nothing: the editor shows the field as filled in and the button comes
--    out with no label. Rejected rather than normalised, because normalising would
--    silently revert what the operator saved and leave the editor disagreeing with the
--    storefront. Whitespace-only keeps the normalisation it already has, so this covers
--    only what that trigger misses.
--
-- The length is a variable rather than a literal repeated in the comparison and the
-- message, so the cap is stated in exactly one place.

create or replace function api.admin_set_copy(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_key text;
  v_lang text;
  v_val text;
  v_written integer := 0;
  c_max integer := 400;
  -- Whitespace plus the characters that occupy no pixels: the soft hyphen, the
  -- zero-width family, the word joiner, the BOM and the bidi overrides.
  c_invisible constant text := E' \t\n\r\f\u00a0\u00ad\u200b\u200c\u200d\u2060\ufeff\u200e\u200f\u202a\u202b\u202c\u202d\u202e';
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'expected a json array of { key, value_bn, value_en, is_markdown }'
      using errcode = '22023';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_key := btrim(v_item ->> 'key');

    if v_key is null or v_key = '' then
      raise exception 'every item needs a key' using errcode = '22023';
    end if;

    if not exists (select 1 from private.copy_registry r where r.key = v_key) then
      raise exception 'unknown copy key: %', v_key using errcode = '22023';
    end if;

    -- The label rule, from the same row that admitted the key.
    if coalesce((v_item ->> 'is_markdown')::boolean, false)
       and not exists (
         select 1 from private.copy_registry r where r.key = v_key and r.markdown_allowed
       ) then
      raise exception 'copy key % is a label and cannot be markdown', v_key
        using errcode = '22023';
    end if;

    -- Both values blank still means "revert to the bundle" and is handled by the
    -- delete below, so nothing is measured here.
    foreach v_lang in array array['bn', 'en'] loop
      v_val := btrim(v_item ->> ('value_' || v_lang));
      continue when v_val is null or v_val = '';

      if char_length(v_val) > c_max then
        raise exception 'copy key % (%): % characters, the limit is %',
          v_key, v_lang, char_length(v_val), c_max using errcode = '22023';
      end if;

      if btrim(v_val, c_invisible) = '' then
        raise exception 'copy key % (%): contains no visible characters',
          v_key, v_lang using errcode = '22023';
      end if;
    end loop;

    insert into public.copy_strings (key, value_bn, value_en, is_markdown)
    values (
      v_key,
      nullif(btrim(v_item ->> 'value_bn'), ''),
      nullif(btrim(v_item ->> 'value_en'), ''),
      coalesce((v_item ->> 'is_markdown')::boolean, false)
    )
    on conflict (key) do update
    set value_bn = excluded.value_bn,
        value_en = excluded.value_en,
        is_markdown = excluded.is_markdown;

    -- Both languages blank means "revert to the shipped wording". The row is deleted
    -- rather than left as an all-null stub, so the editor and the public read agree
    -- about whether the key is set.
    if nullif(btrim(v_item ->> 'value_bn'), '') is null
       and nullif(btrim(v_item ->> 'value_en'), '') is null then
      delete from public.copy_strings c where c.key = v_key;
    end if;

    v_written := v_written + 1;
  end loop;

  return v_written;
end
$$;

-- Restated as defence in depth, not because replacing the function requires it.
--
-- `create or replace function` keeps the existing ACL: the revoke from
-- 20261004110000 is still in force after every replacement since, verified against
-- the hosted project by calling this as `anon` and being refused at the ACL with
-- 42501 rather than reaching the owner gate below. Only `drop function` resets
-- grants, to the creating role's defaults - which for a function in an exposed
-- schema means `PUBLIC` gets execute.
--
-- So the grant below is belt-and-braces for the case where someone later drops and
-- recreates this function, and it costs nothing. What must never happen is a casual
-- `drop function api.admin_set_copy` to "make the schema change cleanly": that is
-- the one action that would hand execute to anon and authenticated, and the reason
-- this comment exists. An earlier version of this comment asserted the opposite -
-- that replacing a function resets its grants - which would have invited exactly
-- that mistake.
grant execute on function api.admin_set_copy(jsonb) to authenticated;
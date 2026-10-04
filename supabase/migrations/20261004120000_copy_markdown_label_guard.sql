-- Refuse `is_markdown` on keys that are labels rather than prose.
--
-- Why a separate migration: the copy store was already pushed when this rule was
-- added. Supabase records applied migrations by version, so editing the applied
-- file would change the repository and never the database. A new migration is the
-- only way the change actually reaches a live project.
--
-- `home.heading` and the other 63 label keys sit inside buttons and headings.
-- Rendering one as markdown turns operator input into markup, and `is_markdown` is
-- the operator's to set, so the rule has to hold in the database: the editor's
-- client-side guard in `src/config/copyKeys.ts` is one request away from being
-- bypassed, and a reviewer who can approve orders has no business rewriting what
-- the shopfront says about taking payment.

-- The keys that must stay plain text. Generated from `MARKDOWN_FORBIDDEN` in
-- `src/config/copyKeys.ts` by `npm run copy:keys:sync` and checked by
-- `npm run copy:keys:check`, so the rule cannot be loosened in the app without
-- the database agreeing.
create or replace function private.copy_markdown_forbidden()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'app.name',
    'app.tagline',
    'common.back',
    'common.close',
    'common.copied',
    'common.copy',
    'common.loading',
    'common.no',
    'common.optional',
    'common.required',
    'common.retry',
    'common.yes',
    'evidence.chooseImage',
    'evidence.errFileSize',
    'evidence.errMaxLen',
    'evidence.errNumeric',
    'evidence.errPhone',
    'evidence.errRequired',
    'evidence.errTrxid',
    'evidence.maxSize',
    'evidence.optional',
    'evidence.required',
    'footer.builtWith',
    'home.browse',
    'home.empty',
    'home.heading',
    'home.subheading',
    'lang.label',
    'lang.switchTo',
    'notFound.cta',
    'notFound.title',
    'order.newOrder',
    'order.reference',
    'order.rejectReason',
    'order.status.approved',
    'order.status.awaiting_proof',
    'order.status.draft',
    'order.status.expired',
    'order.status.locked',
    'order.status.rejected',
    'order.status.under_review',
    'order.submitEvidence',
    'order.submitEvidenceCta',
    'order.submitting',
    'order.title',
    'order.unlocked',
    'paywall.amount',
    'paywall.back',
    'paywall.chooseMethod',
    'paywall.noMethods',
    'paywall.refusedLocked',
    'paywall.sendTo',
    'paywall.submit',
    'paywall.submitting',
    'paywall.summary',
    'paywall.summaryAmount',
    'paywall.summaryLink',
    'recovery.back',
    'recovery.sent',
    'recovery.submit',
    'recovery.submitting',
    'recovery.title',
    'setup.see',
    'setup.title'
  ]
$$;

-- `create or replace` rather than a new name: the grant on api.admin_set_copy from
-- the previous migration is tied to the function identity, so replacing the body
-- keeps callers working instead of dropping access for every existing client.
create or replace function api.admin_set_copy(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_key text;
  v_known text[];
  v_written integer := 0;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'expected a json array of { key, value_bn, value_en, is_markdown }'
      using errcode = '22023';
  end if;

  v_known := private.copy_keys();

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_key := btrim(v_item ->> 'key');

    if v_key is null or v_key = '' then
      raise exception 'every item needs a key' using errcode = '22023';
    end if;

    if not (v_key = any (v_known)) then
      raise exception 'unknown copy key: %', v_key using errcode = '22023';
    end if;

    -- The label rule. Deliberately before the insert, so a rejected write cannot
    -- half-apply a batch that arrived as one call.
    if coalesce((v_item ->> 'is_markdown')::boolean, false)
       and v_key = any (private.copy_markdown_forbidden()) then
      raise exception 'copy key % is a label and cannot be markdown', v_key
        using errcode = '22023';
    end if;

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

    -- Both languages blank means "revert to the bundle", which is the absence of
    -- an override. Deleting the row is what makes that true: `get_public_copy`
    -- filters all-null rows out, so a lingering one would show up in the editor
    -- looking like a setting that exists while changing nothing, and the editor
    -- and the public read would disagree about whether the key is set.
    if nullif(btrim(v_item ->> 'value_bn'), '') is null
       and nullif(btrim(v_item ->> 'value_en'), '') is null then
      delete from public.copy_strings c where c.key = v_key;
    end if;

    v_written := v_written + 1;
  end loop;

  return v_written;
end
$$;

-- Replacing a function resets its grants to the creating role's defaults, so the
-- execute grant from 20261004110000 has to be restated. Without this the owner
-- would keep access (the check is not owner-gated) but `authenticated` would
-- silently lose it, and the failure would look like a permission error on a
-- function that is supposed to be owner-only anyway - so it is easy to misread.
grant execute on function api.admin_set_copy(jsonb) to authenticated;
-- The editable-copy registry, as rows.
--
-- Why a table rather than the two generated arrays this replaces: the app knows two
-- things about every copy key - whether it may be edited, and whether it may be
-- stored as markdown - and those are properties of one registry, not two lists.
-- Holding them as separate `select array[...]` functions meant a new key had to be
-- added in three places, and nothing stopped the two from disagreeing. They did
-- disagree: `setup.body` was editable, had no markdown rule, and was rendered
-- nowhere. One row per key makes that state unrepresentable.
--
-- It also moves registry changes from schema changes to data changes. `COPY_KEYS` and
-- `MARKDOWN_ALLOWED` in `src/config/copyKeys.ts` are the source of truth;
-- `npm run copy:keys:sync` writes the block below and `npm run copy:keys:check`
-- fails the build if the two drift, so the rule is enforced even though the data is
-- duplicated.

create table private.copy_registry (
  key text primary key,
  -- False for anything that is a label, is interpolated with a value, or is read as
  -- an HTML attribute. Those cannot be rendered as markdown even when the operator
  -- asks for it, so the answer belongs here rather than in a view that only exists
  -- in the app.
  markdown_allowed boolean not null default false,

  -- Same shape rule as the copy table itself, so a malformed row cannot exist here
  -- either. Shape is not the point of the check, but the registry is the gate every
  -- write passes through, so it should not be the weakest link.
  constraint copy_registry_key_shape check (key ~ '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$')
);

comment on table private.copy_registry is
  'Mirror of COPY_KEYS in src/config/copyKeys.ts. Generated: npm run copy:keys:sync.';
comment on column private.copy_registry.markdown_allowed is
  'False for labels, interpolated strings and attribute values, which cannot be rendered as markdown.';

-- The `private` schema is not exposed through PostgREST, so this table is not
-- reachable by `anon` or `authenticated` even without a grant. Revoked anyway, so
  -- the intent survives a future move to an exposed schema.
revoke all on table private.copy_registry from public, anon, authenticated;

-- copy-registry:begin
insert into private.copy_registry (key, markdown_allowed) values
  ('app.name', false),
  ('app.tagline', false),
  ('home.heading', false),
  ('home.subheading', false),
  ('home.empty', false),
  ('home.browse', false),
  ('paywall.back', false),
  ('paywall.chooseMethod', false),
  ('paywall.chooseMethodHint', true),
  ('paywall.noMethods', false),
  ('paywall.sendTo', false),
  ('paywall.amount', false),
  ('paywall.amountMin', false),
  ('paywall.amountAny', false),
  ('paywall.amountError', false),
  ('paywall.summary', false),
  ('paywall.summaryLink', false),
  ('paywall.summaryAmount', false),
  ('paywall.submit', false),
  ('paywall.submitting', false),
  ('paywall.refused', false),
  ('paywall.refusedLocked', false),
  ('paywall.deliverable', true),
  ('paywall.closedTitle', false),
  ('paywall.closedBody', false),
  ('paywall.closedContact', false),
  ('order.title', false),
  ('order.reference', false),
  ('order.rejectReason', false),
  ('order.status.draft', false),
  ('order.status.awaiting_proof', false),
  ('order.status.under_review', false),
  ('order.status.approved', false),
  ('order.status.rejected', false),
  ('order.status.expired', false),
  ('order.status.locked', false),
  ('order.submitEvidence', false),
  ('order.evidenceHint', true),
  ('order.submitEvidenceCta', false),
  ('order.submitting', false),
  ('order.unlocked', false),
  ('order.underReview', false),
  ('order.rejected', false),
  ('order.expired', false),
  ('order.locked', false),
  ('order.newOrder', false),
  ('order.reminder', false),
  ('order.reminderBody', true),
  ('order.payOnline', false),
  ('order.payOnlinePending', false),
  ('order.payOnlineSandbox', false),
  ('order.payOnlineReturnTitle', false),
  ('order.payOnlineReturnBody', false),
  ('order.payOnlineTestDone', false),
  ('order.payOnlineFailed', false),
  ('order.payOnlineRetry', false),
  ('evidence.required', false),
  ('evidence.optional', false),
  ('evidence.chooseImage', false),
  ('evidence.maxSize', false),
  ('evidence.errRequired', false),
  ('evidence.errPhone', false),
  ('evidence.errTrxid', false),
  ('evidence.errNumeric', false),
  ('evidence.errMaxLen', false),
  ('evidence.errFileSize', false),
  ('recovery.title', false),
  ('recovery.phone', false),
  ('recovery.code', false),
  ('recovery.body', true),
  ('recovery.submit', false),
  ('recovery.submitting', false),
  ('recovery.sent', false),
  ('recovery.back', false),
  ('recovery.disabled', false),
  ('common.loading', false),
  ('common.retry', false),
  ('common.copy', false),
  ('common.copied', false),
  ('common.close', false),
  ('common.optional', false),
  ('common.required', false),
  ('common.back', false),
  ('common.yes', false),
  ('common.no', false),
  ('lang.switchTo', false),
  ('lang.label', false),
  ('notFound.title', false),
  ('notFound.body', true),
  ('notFound.cta', false);
-- copy-registry:end

-- `api.admin_set_copy` is rewritten below to read this table. It is replaced rather
-- than dropped and recreated so the function identity - and with it the grant from
-- 20261004110000 - survives.
--
-- The generated array functions go away. Leaving them would mean the same list exists
-- twice with nothing keeping the copies honest, which is what this migration exists to
-- stop. Nothing else referenced them.
drop function if exists private.copy_keys();
drop function if exists private.copy_markdown_forbidden();

create or replace function api.admin_set_copy(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_key text;
  v_written integer := 0;
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

    -- The label rule, from the same row that admitted the key. Deliberately before
    -- the insert: a rejected write must not half-apply a batch that arrived as one
    -- call, or the operator sees "saved" and a string that did not change.
    if coalesce((v_item ->> 'is_markdown')::boolean, false)
       and not exists (
         select 1 from private.copy_registry r where r.key = v_key and r.markdown_allowed
       ) then
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

    -- Both languages blank means "revert to the bundle", which is the absence of an
    -- override. Deleting the row is what makes that true: `get_public_copy` filters
    -- all-null rows out, so a lingering one would show up in the editor looking like a
    -- setting that exists while changing nothing, and the editor and the public read
    -- would disagree about whether the key is set.
    if nullif(btrim(v_item ->> 'value_bn'), '') is null
       and nullif(btrim(v_item ->> 'value_en'), '') is null then
      delete from public.copy_strings c where c.key = v_key;
    end if;

    v_written := v_written + 1;
  end loop;

  return v_written;
end
$$;

-- Restated as defence in depth. `create or replace function` keeps the existing ACL,
-- so the revoke from 20261004110000 is still in force - anon is refused at the ACL
-- with 42501, before reaching the owner gate inside. Only `drop function` resets
-- grants, to the creating role's defaults, which in an exposed schema means `PUBLIC`
-- gets execute. Keep this line: it is what saves the function if it is ever dropped
-- and recreated, and it costs nothing.
grant execute on function api.admin_set_copy(jsonb) to authenticated;
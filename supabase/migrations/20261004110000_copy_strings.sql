-- Editable customer copy.
--
-- The bundled `customer.json` files ship with the app and are the fallback. This
-- table holds operator overrides for those strings, so a wording change does not
-- need a redeploy. Three rules make the store safe to merge over the bundles:
--
--   1. The key must be a known dotted path in `src/config/copyKeys.ts`. The
--      database cannot know what the code contains, so the registry is the
--      source of truth for what is *editable*, and a copy edit for a key the app
--      never asks for is rejected rather than silently stored forever. That also
--      keeps a stray key from shadowing nothing at runtime.
--
--   2. Only a non-blank value counts as an override. `private.tidy_blank_to_null`
--      normalises whitespace-only text to NULL on write, and the merge treats NULL
--      as "no override" - so clearing the admin editor reverts to the bundle. This
--      has to agree with the bilingual fallback in the app: '' and NULL must mean
--      the same thing everywhere, or a cleared field renders as an empty string
--      instead of the shipped text.
--
--   3. Read through `api.get_public_copy()`, never by granting SELECT. The table
--      is RLS-on with no policies, so an authenticated customer cannot read it
--      even though they hold the anon key. Overrides are public by design, but
--      reaching them is a deliberate function call, not an inherited privilege.
--
-- `is_markdown` is per-row rather than a property of the key because the registry
-- knows it: a label like `home.heading` must never render HTML, while a paragraph
-- like `recovery.body` is authored as markdown. Keeping the flag in the database
-- lets an operator switch a field to markdown without a code change, which is the
-- point of the feature - so it is stored, refused for label keys at write time,
-- and enforced at render time by DOMPurify either way.

create table public.copy_strings (
  key text primary key,
  value_bn text,
  value_en text,
  is_markdown boolean not null default false,
  updated_at timestamptz not null default now(),

  -- Shape rather than membership: which keys exist is the app's business (see
  -- src/config/copyKeys.ts, enforced in api.admin_set_copy). The store only has to
  -- refuse things that are malformed regardless of the registry, which keeps this
  -- migration free of a hardcoded list that would drift from the code.
  constraint copy_strings_key_shape check (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$')
);

comment on table public.copy_strings is
  'Operator overrides for bundled customer copy. Merged over the locale bundles by src/composables/useCopyOverrides.ts.';
comment on column public.copy_strings.is_markdown is
  'Render as sanitised markdown. Labels must stay false or they become a markup injection surface.';

create trigger copy_strings_touch
  before update on public.copy_strings
  for each row
  execute function private.touch_updated_at();

create trigger copy_strings_tidy
  before insert or update on public.copy_strings
  for each row
  execute function private.tidy_blank_to_null();

-- The store is reachable only through the api functions below.
alter table public.copy_strings enable row level security;

-- The registry, mirrored. Generated from `src/config/copyKeys.ts` by
-- `npm run copy:keys:sync` and checked by `npm run copy:keys:check`, so the two
-- cannot drift: the database refuses a key the app does not know, and CI fails if
-- either array here is not exactly what the app asks for.
--
-- A generated list in a migration is normally a smell - schema that depends on
-- application code. It is contained to these two functions, and the alternative
-- is either an unenforced write path or a second place to remember to update,
-- which is worse. Membership lives here; shape lives in the table constraint.
create or replace function private.copy_keys()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'app.name',
    'app.tagline',
    'home.heading',
    'home.subheading',
    'home.empty',
    'home.browse',
    'paywall.back',
    'paywall.chooseMethod',
    'paywall.chooseMethodHint',
    'paywall.noMethods',
    'paywall.sendTo',
    'paywall.amount',
    'paywall.amountMin',
    'paywall.amountAny',
    'paywall.amountError',
    'paywall.summary',
    'paywall.summaryLink',
    'paywall.summaryAmount',
    'paywall.submit',
    'paywall.submitting',
    'paywall.refused',
    'paywall.refusedLocked',
    'paywall.deliverable',
    'order.title',
    'order.reference',
    'order.rejectReason',
    'order.status.draft',
    'order.status.awaiting_proof',
    'order.status.under_review',
    'order.status.approved',
    'order.status.rejected',
    'order.status.expired',
    'order.status.locked',
    'order.submitEvidence',
    'order.evidenceHint',
    'order.submitEvidenceCta',
    'order.submitting',
    'order.unlocked',
    'order.underReview',
    'order.rejected',
    'order.expired',
    'order.locked',
    'order.newOrder',
    'order.reminder',
    'order.reminderBody',
    'evidence.required',
    'evidence.optional',
    'evidence.chooseImage',
    'evidence.maxSize',
    'evidence.errRequired',
    'evidence.errPhone',
    'evidence.errTrxid',
    'evidence.errNumeric',
    'evidence.errMaxLen',
    'evidence.errFileSize',
    'recovery.title',
    'recovery.body',
    'recovery.submit',
    'recovery.submitting',
    'recovery.sent',
    'recovery.back',
    'common.loading',
    'common.retry',
    'common.copy',
    'common.copied',
    'common.close',
    'common.optional',
    'common.required',
    'common.back',
    'common.yes',
    'common.no',
    'footer.builtWith',
    'lang.switchTo',
    'lang.label',
    'notFound.title',
    'notFound.body',
    'notFound.cta',
    'setup.title',
    'setup.body',
    'setup.see'
  ]
$$;

-- The keys that must never be rendered as markdown live in
-- private.copy_markdown_forbidden(), added by 20261004120000: the copy store had
-- already been pushed by then, and Supabase records applied migrations by
-- version, so the rule could not be added to this file and still reach a live
-- database.

-- `get_public_copy()` takes no arguments and returns one row per key, so the
-- client makes exactly one request per page load and merges client-side.
create or replace function api.get_public_copy()
returns table (key text, value_bn text, value_en text, is_markdown boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select c.key, c.value_bn, c.value_en, c.is_markdown
  from public.copy_strings c
  where c.value_bn is not null or c.value_en is not null
  order by c.key
$$;

-- Owner-gated: copy is customer-visible, so this is deliberately above `staff`.
-- A reviewer who can approve orders has no business rewriting what the shopfront
-- says about taking payment.
create or replace function api.admin_copy()
returns table (key text, value_bn text, value_en text, is_markdown boolean, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select c.key, c.value_bn, c.value_en, c.is_markdown, c.updated_at
  from public.copy_strings c
  order by c.key;
end
$$;

-- One row per key, both languages at once, because the two are edited together and
-- a half-saved bilingual pair is exactly the state the fallback exists to paper
-- over. Clears a language by sending an empty string: the tidy trigger turns it
-- into NULL, which the merge reads as "fall back to the bundle for this language".
--
-- Rejects a key the app does not know. Storing it would be harmless at runtime but
-- it would sit in the admin editor looking like a live setting, and the next
-- person to read it would reasonably assume it was doing something.
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
    -- an override. Deleting the row is what makes that true: the merge reads NULL
    -- as no override either way, but a lingering all-NULL row would show up in the
    -- admin editor looking like a setting that exists while changing nothing, and
    -- `get_public_copy` already filters these rows out - so the editor and the
    -- public read would disagree about whether the key is set.
    if nullif(btrim(v_item ->> 'value_bn'), '') is null
       and nullif(btrim(v_item ->> 'value_en'), '') is null then
      delete from public.copy_strings c where c.key = v_key;
    end if;

    v_written := v_written + 1;
  end loop;

  return v_written;
end
$$;

revoke all on table public.copy_strings from anon, authenticated;
revoke all on function api.get_public_copy() from public;
revoke all on function api.admin_copy() from public;
revoke all on function api.admin_set_copy(jsonb) from public;

-- Reads are public: the strings appear on the shopfront.
grant execute on function api.get_public_copy() to anon, authenticated;
grant execute on function api.admin_copy() to authenticated;
grant execute on function api.admin_set_copy(jsonb) to authenticated;

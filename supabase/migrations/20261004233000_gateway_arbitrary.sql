-- Arbitrary payment methods.
--
-- Until now a payment method was one of three strings chosen from a dropdown, backed by
-- a Postgres enum, and the money the customer sends to was two fixed columns. That is
-- fine for bKash, Nagad and a bank, and wrong the moment someone wants to accept CellFin,
-- Rocket, or a wallet that did not exist when the schema was written. Adding one meant a
-- migration, a release, and a deploy.
--
-- Two changes, both aimed at the same thing - a method an operator can add without a
-- developer:
--
--   1. `kind` becomes text. Nothing in the schema ever branched on the value; it was only
--      ever a label, and the one function that did cast it (`admin_upsert_gateway`) turned
--      a typo into an unhandled enum error rather than a usable message. So the enum is
--      dropped and the value is validated as text instead.
--
--   2. The destination the customer sends money to becomes `account_fields`, an ordered
--      list of labelled values in exactly the shape `evidence_fields` already uses. A bank
--      transfer needs a routing number and a branch; a mobile wallet needs one number. One
--      list covers both, and the customer view renders whatever is in it.
--
-- `account_number` and `account_name` stay in the table. Nothing reads them any more, but
-- seed.sql and the test fixtures still write them, and dropping a column to tidy up a
-- migration nobody asked for is how a migration gets reverted. Existing rows are backfilled
-- into `account_fields` below, so no operator has to re-enter their own bank details.
--
-- This file renames `api.public_link_payload` the same way the bKash migration did, and
-- for the same reason: the payload projection carries the hidden-minimum rule and must
-- never be retyped by hand.

-- ---------------------------------------------------------------------------
-- Free-text kind
-- ---------------------------------------------------------------------------

-- `api.my_orders` and `api.admin_orders` name the enum in their return tables, so the
-- type cannot be altered underneath them. Both are dropped and rebuilt below with `text`.
-- Dropping loses the grants, which is why each rebuild is followed by them again.
drop function if exists api.my_orders();
drop function if exists api.admin_orders(text, text, integer);

-- The same rule applies to a view: Postgres refuses to change a column's type while
-- anything selects it. `payment_gateways_public` projects `kind`, so it is dropped and
-- recreated around the change. Its grants and its RLS policy are restored below too -
-- a view that came back without them would be invisible rather than broken, which is the
-- kind of regression a test suite does not notice.
drop view public.payment_gateways_public;

alter table public.payment_gateways
  alter column kind type text using kind::text;

-- Bounded but otherwise free: a method is named by a person, so "CellFin", "Rocket" and
-- "Nagad (Agent)" all have to be writable. Blank and absurd lengths are still refused,
-- because the value ends up in an admin list and a report.
alter table public.payment_gateways
  add constraint payment_gateways_kind_shape
  check (btrim(kind) <> '' and length(kind) <= 48);

comment on column public.payment_gateways.kind is
  'Free-text method category, e.g. bkash, bank, cellfin. A label, not a code path: '
  'nothing branches on it.';

-- The two functions above, rebuilt. Bodies are unchanged; only the `kind` column in the
-- return table moves from `public.gateway_kind` to `text`.
create or replace function api.my_orders()
returns table (
  id uuid,
  slug text,
  title_en text,
  title_bn text,
  gateway_kind text,
  status public.order_status,
  reference_code text,
  amount numeric,
  min_amount numeric,
  min_hidden boolean,
  created_at timestamptz,
  expires_at timestamptz,
  submitted_at timestamptz,
  attempt_count integer,
  reject_reason_en text,
  reject_reason_bn text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    o.id,
    l.slug,
    l.title_en,
    l.title_bn,
    g.kind,
    o.status,
    o.reference_code,
    o.amount,
    case when o.hide_min_snapshot then null else o.min_amount_snapshot end,
    o.hide_min_snapshot,
    o.created_at,
    o.expires_at,
    o.submitted_at,
    o.attempt_count,
    o.reject_reason_en,
    o.reject_reason_bn
  from public.orders o
  join public.paywall_links l on l.id = o.link_id
  join public.payment_gateways g on g.id = o.gateway_id
  where o.user_id = auth.uid()
  order by o.created_at desc
$$;

revoke all on function api.my_orders() from public;
grant execute on function api.my_orders() to authenticated;

create or replace function api.admin_orders(
  p_status text default null,
  p_reference text default null,
  p_limit integer default 100
)
returns table (
  id uuid,
  slug text,
  title_en text,
  title_bn text,
  kind text,
  status public.order_status,
  reference_code text,
  amount numeric,
  phone_e164 text,
  attempt_count integer,
  probe_count integer,
  created_at timestamptz,
  submitted_at timestamptz,
  has_duplicate_trxid boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select
    o.id,
    l.slug,
    l.title_en,
    l.title_bn,
    g.kind,
    o.status,
    o.reference_code,
    o.amount,
    o.phone_e164,
    o.attempt_count,
    o.probe_count,
    o.created_at,
    o.submitted_at,
    exists (
      select 1
      from public.order_evidence e
      join public.order_evidence dup
        on dup.field_key = e.field_key
       and dup.value_text_norm is not null
       and dup.value_text_norm = e.value_text_norm
       and dup.order_id <> o.id
      where e.order_id = o.id and e.value_text_norm is not null
    )
  from public.orders o
  join public.paywall_links l on l.id = o.link_id
  join public.payment_gateways g on g.id = o.gateway_id
  where (p_status is null or o.status::text = p_status)
    and (
      p_reference is null
      or o.reference_code = private.normalize_reference(p_reference)
    )
  order by o.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$$;

revoke all on function api.admin_orders(text, text, integer) from public;
grant execute on function api.admin_orders(text, text, integer) to authenticated;

-- Nothing names the enum now. Dropping it rather than leaving it behind is the check
-- that the conversion was complete: if some function still returned it, this would fail.
drop type public.gateway_kind;

-- ---------------------------------------------------------------------------
-- Dynamic account details
-- ---------------------------------------------------------------------------

-- Same shape and the same reasoning as `private.validate_evidence_fields`, because it
-- answers the same question: operator-authored JSON that the customer view will render,
-- validated rather than trusted. The difference is that these are values to copy, not
-- questions to answer, so there is no type and no validator - just a label and something
-- to send the money to.
create or replace function private.validate_account_fields(p_fields jsonb)
returns void
language plpgsql
immutable
as $$
declare
  v_field jsonb;
  v_key text;
  v_seen text[] := '{}';
begin
  if p_fields is null or jsonb_typeof(p_fields) <> 'array' then
    raise exception 'account_fields must be a JSON array' using errcode = '22023';
  end if;

  if jsonb_array_length(p_fields) > 12 then
    raise exception 'account_fields accepts at most 12 rows' using errcode = '22023';
  end if;

  for v_field in select * from jsonb_array_elements(p_fields) loop
    if jsonb_typeof(v_field) <> 'object' then
      raise exception 'each account field must be a JSON object' using errcode = '22023';
    end if;

    v_key := v_field ->> 'key';
    if v_key is null or v_key !~ '^[a-z][a-z0-9_]{0,31}$' then
      raise exception 'account field key % does not match ^[a-z][a-z0-9_]{0,31}$',
        coalesce(v_key, '(missing)')
        using errcode = '22023';
    end if;

    if v_key = any (v_seen) then
      raise exception 'duplicate account field key %', v_key using errcode = '22023';
    end if;
    v_seen := v_seen || v_key;

    -- An operator-authored label is what the customer reads. A row with no label would
    -- render as a bare value, which is the one thing a payment instruction must not be.
    if btrim(coalesce(v_field ->> 'label_en', '')) = '' then
      raise exception 'account field % needs a non-blank label_en', v_key using errcode = '22023';
    end if;

    if btrim(coalesce(v_field ->> 'value', '')) = '' then
      raise exception 'account field % needs a non-blank value', v_key using errcode = '22023';
    end if;
  end loop;
end
$$;

alter table public.payment_gateways
  add column account_fields jsonb not null default '[]'::jsonb;

comment on column public.payment_gateways.account_fields is
  'Ordered {key,label_en,label_bn,value} rows describing where the customer sends money. '
  'Empty for automated methods, which have no destination to show.';

-- The two columns this replaces were NOT NULL, which would force every future form to
-- keep writing them as well - the same bank details in two places, and a second thing to
-- forget. Nothing reads them any more: the only appearances outside generated types were
-- the seed and the test fixtures, which supply values happily. They stay in the table
-- rather than being dropped, so this migration cannot strand a deployment that has not
-- yet been re-seeded; a follow-up can remove them once nothing writes them.
alter table public.payment_gateways
  alter column account_number drop not null,
  alter column account_name drop not null;

comment on column public.payment_gateways.account_number is
  'Legacy. Superseded by account_fields; retained so an un-re-seeded deployment still works.';
comment on column public.payment_gateways.account_name is
  'Legacy. Superseded by account_fields; retained so an un-re-seeded deployment still works.';

-- Backfill from the pair being replaced, so an existing bank transfer keeps working
-- without anyone retyping it. Number first: that is the field a customer reads first on
-- every one of these methods, and preserving that order preserves the page.
update public.payment_gateways as g
set account_fields = (
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'key', entry.key,
             'label_en', entry.label_en,
             'label_bn', entry.label_bn,
             'value', entry.value
           ) order by entry.ordinality
         ), '[]'::jsonb)
  from (
    select 1 as ordinality, 'account_number' as key,
           'Account / wallet number'::text as label_en,
           null::text as label_bn,
           btrim(g.account_number) as value
    union all
    select 2, 'account_name', 'Account name', null, btrim(g.account_name)
  ) as entry
  where entry.value <> ''
)
where g.account_number is not null or g.account_name is not null;

-- An automated method has no destination to show, so it has no account details either.
-- This replaces the evidence-only rule rather than sitting beside it: two constraints
-- saying the same thing about different columns is one more thing to keep in step.
alter table public.payment_gateways
  drop constraint payment_gateways_automatic_has_no_evidence;

alter table public.payment_gateways
  add constraint payment_gateways_automatic_has_no_forms
  check (
    provider is null
    or (evidence_fields = '[]'::jsonb and account_fields = '[]'::jsonb)
  );

-- Validation runs on the way in rather than as a table constraint, for the same reason
-- evidence_fields does: the messages name the offending key, which is what makes them
-- fixable by whoever typed them.

-- ---------------------------------------------------------------------------
-- The public gateway view, back
-- ---------------------------------------------------------------------------

-- Rebuilt with `provider` and `account_fields` added, because a customer reading this
-- directly has the same need as one reading the link payload: know whether to send money
-- somewhere, and where. `security_invoker` and the active-only filter are unchanged, and
-- so is the fact that the table's own `payment_gateways_public_read` policy still decides
-- which rows get through - dropping the view never touched it.
create view public.payment_gateways_public
with (security_invoker = true)
as
select
  id,
  kind,
  provider,
  account_number,
  account_name,
  account_fields,
  name_en,
  name_bn,
  instructions_md_en,
  instructions_md_bn,
  reference_prompt_en,
  reference_prompt_bn,
  supports_reference,
  evidence_fields,
  sort_order
from public.payment_gateways
where is_active;

grant select on public.payment_gateways_public to anon, authenticated;

-- The view is security_invoker, so it runs as `anon` and needs the base table's columns
-- granted individually - the view grant above is not enough on its own. The original
-- grant list predates `provider` and `account_fields` and is additive here: these two
-- columns are what a customer is shown, so withholding them would only break the view
-- that exists to serve them. `probe_count`-style internals stay ungranted.
grant select (provider, account_fields)
  on public.payment_gateways to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Writing gateways
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
  -- A jsonb null is not a SQL null, so `coalesce` alone would pass a literal `null` to
  -- the validators and fail on it. An untouched editor sends exactly that, and "you left
  -- this blank" must mean "empty", not "malformed".
  v_account_fields jsonb := coalesce(nullif(p_gateway -> 'account_fields', 'null'::jsonb), '[]'::jsonb);
  v_evidence_fields jsonb := coalesce(nullif(p_gateway -> 'evidence_fields', 'null'::jsonb), '[]'::jsonb);
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

  if v_provider is not null and v_provider <> 'bkash_pgw' then
    raise exception 'unknown payment provider: %', v_provider using errcode = '22023';
  end if;

  perform private.validate_account_fields(v_account_fields);

  if v_id is null then
    insert into public.payment_gateways (
      kind, account_number, account_name, account_fields,
      name_en, name_bn,
      instructions_md_en, instructions_md_bn,
      reference_prompt_en, reference_prompt_bn, supports_reference,
      evidence_fields, is_active, sort_order, provider
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
      v_provider
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
        provider = v_provider
    where id = v_id
    returning * into v_row;
  end if;

  return v_row;
end
$$;

revoke all on function api.admin_upsert_gateway(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_gateway(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Public payload
-- ---------------------------------------------------------------------------

-- `account_fields` rides along with `provider`. The customer view needs both to decide
-- between "here is where to send the money" and "press this and bKash takes it", and the
-- payload is the only place it can learn that without guessing from `kind`.
alter function api.public_link_payload(text) rename to public_link_payload_v2;
revoke all on function api.public_link_payload_v2(text) from public, anon, authenticated;

create or replace function api.public_link_payload(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when base.doc is null then null
    else jsonb_set(
      base.doc,
      '{gateways}',
      (
        select coalesce(
          jsonb_agg(
            entry.doc
              || jsonb_build_object(
                   'provider', g.provider,
                   'account_fields', g.account_fields
                 )
            order by entry.ordinality
          ),
          '[]'::jsonb
        )
        from jsonb_array_elements(coalesce(base.doc -> 'gateways', '[]'::jsonb))
          with ordinality as entry(doc, ordinality)
        join public.payment_gateways g on g.id = (entry.doc ->> 'id')::uuid
      )
    )
  end
  from (select api.public_link_payload_v2(p_slug) as doc) base
$$;

-- Not granted, for the same reason as in the bKash migration: `get_public_link` is
-- security definer and reaches this without help, and a second anon-reachable entry point
-- returning the same payload minus `maintenance_mode` is surface without benefit.
revoke all on function api.public_link_payload(text) from public, anon, authenticated;
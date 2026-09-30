-- Cofibuy core schema.
--
-- Layout follows Supabase conventions:
--
--   public   tables and the curated read views. RLS on, grants revoked.
--   private  helper functions. Never exposed, never granted to a client role.
--   api      security definer RPCs. The only surface PostgREST exposes besides
--            the public views.
--
-- Two rules hold throughout:
--
--   1. Grants decide reachability, policies decide rows. Revoking every table
--      from anon and authenticated means a customer cannot SELECT a money
--      table at all, no matter what a policy says.
--   2. Anything a customer should not see is never returned by a function, not
--      merely hidden. `orders` carries min_amount_snapshot for auditing; that
--      column is why customer reads go through RPCs with explicit column lists.

create schema if not exists extensions;
create schema if not exists private;
create schema if not exists api;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pgcrypto') then
    create extension pgcrypto with schema extensions;
  end if;
end
$$;

do $$
begin
  if to_regprocedure('extensions.crypt(text,text)') is null then
    raise exception
      'pgcrypto must be installed in the "extensions" schema. On Supabase it is by default.';
  end if;
end
$$;

revoke all on schema private from public;
revoke all on schema api from public;
grant usage on schema api to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------------

create type public.staff_role as enum ('staff', 'owner');
create type public.gateway_kind as enum ('bkash', 'nagad', 'bank');
create type public.order_status as enum (
  'draft',
  'awaiting_proof',
  'under_review',
  'approved',
  'rejected',
  'expired',
  'locked'
);
create type public.evidence_type as enum ('text', 'textarea', 'number', 'image');
create type public.field_validator as enum ('bd_phone', 'trxid', 'numeric');
create type public.recovery_status as enum (
  'pending',
  'sent',
  'verified',
  'expired',
  'failed',
  'undeliverable'
);

-- ---------------------------------------------------------------------------
-- Normalisation helpers
--
-- These are the SQL twins of `src/lib/phone.ts` and `src/lib/digits.ts`. The
-- database is authoritative: a mismatch means a real, paid order cannot be
-- found by the reference the customer typed, so the twin has a test that pins
-- them to the same behaviour.
-- ---------------------------------------------------------------------------

-- Bengali numerals must be converted *before* stripping non-digits: Postgres
-- \d and \D match ASCII 0-9 only, so a Bengali digit would be deleted rather
-- than translated and the number would silently lose digits.
create or replace function private.to_latin_digits(p_text text)
returns text
language sql
immutable
as $$
  select translate(p_text, '০১২৩৪৫৬৭৮৯', '0123456789')
$$;

-- Reduces every accepted spelling of a BD mobile number to E.164, or NULL.
-- Accepts Bengali digits, an international access prefix, the country code with
-- or without a plus, a trunk zero, and any spacing or punctuation.
create or replace function private.normalize_bd_phone(p_raw text)
returns text
language sql
immutable
as $$
  with digits as (
    select regexp_replace(private.to_latin_digits(coalesce(p_raw, '')), '[^0-9]', '', 'g') as v
  ),
  trimmed as (
    select regexp_replace(
             regexp_replace(
               regexp_replace(v, '^00', ''),
               '^880', ''
             ),
             '^0+', ''
           ) as v
    from digits
  )
  select case when v ~ '^1[3-9][0-9]{8}$' then '+880' || v else null end
  from trimmed
$$;

-- Comparison form of a transcribed value: Bengali digits to Latin, whitespace
-- collapsed, upper-cased. TrxIDs are compared case-insensitively because the
-- statement search an admin runs is not.
create or replace function private.normalize_reference(p_raw text)
returns text
language sql
immutable
as $$
  select upper(btrim(regexp_replace(private.to_latin_digits(coalesce(p_raw, '')), '\s+', ' ', 'g')))
$$;

create or replace function private.otp_hash(p_plain text)
returns text
language sql
volatile
as $$
  select extensions.crypt(p_plain, extensions.gen_salt('bf', 10))
$$;

create or replace function private.otp_matches(p_plain text, p_hash text)
returns boolean
language sql
stable
as $$
  select p_plain is not null and p_hash is not null
    and extensions.crypt(p_plain, p_hash) = p_hash
$$;

-- Short, human-readable reconciliation key for bKash's Reference field.
-- The alphabet omits 0/O/1/I/L so a code read aloud or retyped from an SMS
-- cannot be misread into a different valid code.
create or replace function private.gen_reference_code()
returns text
language sql
volatile
as $$
  select string_agg(
           substr('23456789ABCDEFGHJKMNPQRSTUVWXYZ', floor(random() * 29)::int + 1, 1),
           ''
           order by g
         )
  from generate_series(1, 8) g
$$;

-- ---------------------------------------------------------------------------
-- Generic triggers
-- ---------------------------------------------------------------------------

create or replace function private.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

-- Blank and whitespace-only mean the same thing as absent, everywhere.
--
-- The bilingual fallback in the app treats '' and NULL identically, so the
-- database has to agree or the two disagree at runtime — a link whose English
-- body is a space would render as an empty page instead of falling back to
-- Bangla. Normalising on write makes `is null` the only question anyone asks.
--
-- Generic rather than per-table so a new text column cannot be added without
-- inheriting the rule.
create or replace function private.tidy_blank_to_null()
returns trigger
language plpgsql
as $$
declare
  v_row jsonb := to_jsonb(new);
  v_key text;
begin
  for v_key in select jsonb_object_keys(v_row) loop
    if jsonb_typeof(v_row -> v_key) = 'string' and btrim(v_row ->> v_key) = '' then
      v_row := jsonb_set(v_row, array[v_key], 'null'::jsonb, true);
    end if;
  end loop;

  new := jsonb_populate_record(new, v_row);
  return new;
end
$$;

-- Append-only tables reject UPDATE and DELETE outright, so an evidence row or
-- an audit trail cannot be rewritten after the fact.
create or replace function private.deny_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception '% is append-only: % is not permitted', tg_table_name, tg_op
    using errcode = '42501';
end
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.site_settings (
  id smallint primary key default 1,
  min_amount numeric(12, 2) not null default 100,
  hide_min_amount boolean not null default false,
  default_lang text not null default 'bn',
  recovery_enabled boolean not null default false,
  contact text,
  updated_at timestamptz not null default now(),
  constraint site_settings_singleton check (id = 1),
  constraint site_settings_min_nonneg check (min_amount >= 0),
  constraint site_settings_lang check (default_lang in ('bn', 'en'))
);

insert into public.site_settings (id) values (1);

create table public.staff (
  user_id uuid primary key references auth.users (id) on delete cascade,
  role public.staff_role not null,
  created_at timestamptz not null default now()
);

create table public.payment_gateways (
  id uuid primary key default gen_random_uuid(),
  kind public.gateway_kind not null,
  account_number text not null,
  account_name text not null,
  -- name_en is required because the admin panel is English-only: an admin must
  -- never see a raw key where a label should be.
  name_en text not null,
  name_bn text,
  instructions_md_en text,
  instructions_md_bn text,
  reference_prompt_en text,
  reference_prompt_bn text,
  supports_reference boolean not null default false,
  evidence_fields jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_gateways_account_number_present check (btrim(account_number) <> ''),
  constraint payment_gateways_account_name_present check (btrim(account_name) <> ''),
  constraint payment_gateways_name_en_present check (btrim(name_en) <> ''),
  constraint payment_gateways_fields_is_array check (jsonb_typeof(evidence_fields) = 'array')
);

create table public.paywall_links (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title_en text,
  title_bn text,
  teaser_md_en text,
  teaser_md_bn text,
  unlock_body_md_en text,
  unlock_body_md_bn text,
  unlock_cta_label_en text,
  unlock_cta_label_bn text,
  unlock_cta_url text,
  min_amount_override numeric(12, 2),
  hide_min_override boolean,
  is_active boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint paywall_links_slug_shape check (slug ~ '^[a-z0-9]([a-z0-9-]{1,46}[a-z0-9])$'),

  -- A link cannot go live without a title and an unlocked body in at least one
  -- language. Checked with btrim rather than trusting the tidy trigger, so the
  -- rule holds even for rows written by a migration or a restore.
  constraint paywall_links_publishable check (
    is_active = false
    or (
      coalesce(nullif(btrim(title_bn), ''), nullif(btrim(title_en), '')) is not null
      and coalesce(
        nullif(btrim(unlock_body_md_bn), ''),
        nullif(btrim(unlock_body_md_en), '')
      ) is not null
    )
  )
);

create index paywall_links_active_idx
  on public.paywall_links (sort_order, slug)
  where is_active;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  link_id uuid not null references public.paywall_links (id) on delete restrict,
  gateway_id uuid not null references public.payment_gateways (id) on delete restrict,
  status public.order_status not null default 'draft',
  reference_code text not null unique,
  amount numeric(12, 2) not null,
  -- The terms the customer agreed to. Raising the minimum later must not
  -- retroactively invalidate an order that is already waiting for a screenshot.
  min_amount_snapshot numeric(12, 2) not null,
  hide_min_snapshot boolean not null default false,
  phone_e164 text,
  phone_raw text,
  attempt_count integer not null default 0,
  probe_count integer not null default 0,
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id) on delete set null,
  reject_code text,
  reject_reason_en text,
  reject_reason_bn text,

  constraint orders_amount_positive check (amount > 0),
  constraint orders_reference_code_shape check (reference_code ~ '^[2-9A-HJ-NP-Z]{8}$'),
  constraint orders_phone_shape check (
    phone_e164 is null or phone_e164 ~ '^\+8801[3-9][0-9]{8}$'
  ),
  constraint orders_rejected_has_reason check (
    status <> 'rejected' or reject_reason_en is not null
  ),
  constraint orders_reviewed_has_reviewer check (
    status not in ('approved', 'rejected') or reviewed_at is not null
  )
);

-- One open order per customer per link, enforced by the database rather than by
-- application logic, so two browser tabs cannot both start an order.
--
-- `locked` is in the set on purpose. Leaving it out would let a customer escape
-- a probe lock simply by calling create_order again, since a new row would not
-- collide with anything.
create unique index orders_one_open_per_user_link
  on public.orders (user_id, link_id)
  where status in ('draft', 'awaiting_proof', 'under_review', 'locked');

create index orders_by_status_idx on public.orders (status, created_at desc);
create index orders_by_user_idx on public.orders (user_id, created_at desc);
create index orders_by_phone_idx on public.orders (phone_e164) where phone_e164 is not null;

create table public.order_evidence (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders (id) on delete cascade,
  field_key text not null,
  value_text_raw text,
  value_text_norm text,
  file_path text,
  attempt integer not null,
  created_at timestamptz not null default now(),

  constraint order_evidence_field_key_shape check (field_key ~ '^[a-z][a-z0-9_]{0,31}$'),
  constraint order_evidence_attempt_positive check (attempt >= 1),

  -- An evidence row is either a typed value or an uploaded file, never both and
  -- never neither.
  constraint order_evidence_one_shape check (
    (file_path is not null and value_text_raw is null)
    or (file_path is null and value_text_raw is not null)
  ),
  constraint order_evidence_file_path_shape check (
    file_path is null or file_path ~ ('^' || '[0-9a-f-]{36}/[0-9a-f-]{36}/[a-z][a-z0-9_]{0,31}/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$')
  )
);

-- One value per field per attempt, so a repeated submit cannot fan out rows.
create unique index order_evidence_unique_per_attempt
  on public.order_evidence (order_id, attempt, field_key);

-- Duplicate detection runs on the normalised column so a TrxID typed with a
-- Bangla keyboard still collides with the Latin one an admin will search for.
create index order_evidence_norm_idx
  on public.order_evidence (field_key, value_text_norm)
  where value_text_norm is not null;

create table public.access_grants (
  user_id uuid not null,
  link_id uuid not null references public.paywall_links (id) on delete cascade,
  via_order_id uuid references public.orders (id) on delete set null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  primary key (user_id, link_id)
);

create index access_grants_by_link_idx
  on public.access_grants (link_id)
  where revoked_at is null;

create table public.customer_contacts (
  user_id uuid not null,
  phone_e164 text not null,
  telegram_chat_id bigint,
  linked_at timestamptz not null default now(),
  primary key (user_id, phone_e164),
  constraint customer_contacts_phone_shape check (phone_e164 ~ '^\+8801[3-9][0-9]{8}$')
);

-- Recovery resolves a phone to every account that has paid with it.
create index customer_contacts_phone_idx on public.customer_contacts (phone_e164);

create table public.recovery_requests (
  id uuid primary key default gen_random_uuid(),
  phone_e164 text not null,
  purpose text not null default 'restore_access',
  status public.recovery_status not null default 'pending',
  requester_user_id uuid,
  request_ip_hash text,
  attempt_count integer not null default 0,
  sent_at timestamptz,
  verified_at timestamptz,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint recovery_requests_phone_shape check (phone_e164 ~ '^\+8801[3-9][0-9]{8}$'),
  constraint recovery_requests_sent_has_timestamp check (status <> 'sent' or sent_at is not null)
);

-- The worker's claim query reads exactly this index.
create index recovery_requests_pending_idx
  on public.recovery_requests (created_at)
  where status = 'pending';

create index recovery_requests_phone_idx on public.recovery_requests (phone_e164, created_at desc);

create table public.otp_challenges (
  id uuid primary key default gen_random_uuid(),
  recovery_request_id uuid not null references public.recovery_requests (id) on delete cascade,
  phone_e164 text not null,
  otp_hash text not null,
  attempt_count integer not null default 0,
  max_attempts integer not null default 5,
  consumed_at timestamptz,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint otp_challenges_attempts_bounded check (
    attempt_count >= 0 and max_attempts >= 1 and attempt_count <= max_attempts
  )
);

-- A resend supersedes the previous code rather than adding a second live one,
-- so an attacker cannot keep several valid codes alive at once.
create unique index otp_challenges_one_live_per_request
  on public.otp_challenges (recovery_request_id)
  where consumed_at is null;

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null,
  target_table text,
  target_id text,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index audit_log_by_target_idx on public.audit_log (target_table, target_id, created_at desc);
create index audit_log_by_actor_idx on public.audit_log (actor_id, created_at desc);

-- Defined here rather than with the other helpers because it reads a table.
-- Security definer because the caller has no grant on public.staff, which is
-- itself a useful property: nobody can enumerate the team.
create or replace function private.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.staff s where s.user_id = auth.uid())
$$;

create or replace function private.is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff s where s.user_id = auth.uid() and s.role = 'owner'
  )
$$;

-- ---------------------------------------------------------------------------
-- Evidence field schema validation
--
-- Admin-authored JSON that decides what the customer may be asked for, so it
-- is validated rather than trusted. `validate` is a fixed vocabulary: the
-- server dispatches on it, and a stored function name would be remote code
-- execution by another name.
-- ---------------------------------------------------------------------------

create or replace function private.validate_evidence_fields(p_fields jsonb)
returns void
language plpgsql
immutable
as $$
declare
  v_field jsonb;
  v_key text;
  v_type text;
  v_validate text;
  v_seen text[] := '{}';
  v_max_len text;
  v_max_mb text;
begin
  if p_fields is null or jsonb_typeof(p_fields) <> 'array' then
    raise exception 'evidence_fields must be a JSON array' using errcode = '22023';
  end if;

  if jsonb_array_length(p_fields) > 12 then
    raise exception 'evidence_fields accepts at most 12 fields' using errcode = '22023';
  end if;

  for v_field in select * from jsonb_array_elements(p_fields) loop
    if jsonb_typeof(v_field) <> 'object' then
      raise exception 'each evidence field must be a JSON object' using errcode = '22023';
    end if;

    v_key := v_field ->> 'key';
    v_type := v_field ->> 'type';
    v_validate := v_field ->> 'validate';

    if v_key is null or v_key !~ '^[a-z][a-z0-9_]{0,31}$' then
      raise exception 'evidence field key % does not match ^[a-z][a-z0-9_]{0,31}$',
        coalesce(v_key, '(missing)')
        using errcode = '22023';
    end if;

    if v_key = any (v_seen) then
      raise exception 'duplicate evidence field key %', v_key using errcode = '22023';
    end if;
    v_seen := v_seen || v_key;

    if v_type is null or v_type not in ('text', 'textarea', 'number', 'image') then
      raise exception 'evidence field % has unknown type %', v_key, coalesce(v_type, '(missing)')
        using errcode = '22023';
    end if;

    -- The admin panel is English-only, so an English label is mandatory. The
    -- Bangla label is optional and falls back per R2.
    if btrim(coalesce(v_field ->> 'label_en', '')) = '' then
      raise exception 'evidence field % needs a non-blank label_en', v_key using errcode = '22023';
    end if;

    if v_validate is not null and btrim(v_validate) <> ''
      and v_validate not in ('bd_phone', 'trxid', 'numeric')
    then
      raise exception 'evidence field % has unknown validator %', v_key, v_validate
        using errcode = '22023';
    end if;

    if v_type in ('text', 'textarea') then
      v_max_len := v_field ->> 'max_len';
      if v_max_len is null or v_max_len !~ '^[0-9]+$' or v_max_len::int < 1
        or v_max_len::int > 200
      then
        raise exception 'evidence field % of type % needs max_len between 1 and 200',
          v_key, v_type
          using errcode = '22023';
      end if;
    end if;

    if v_type = 'image' then
      v_max_mb := v_field ->> 'max_mb';
      if v_max_mb is null or v_max_mb !~ '^[0-9]+$' or v_max_mb::int < 1 or v_max_mb::int > 10 then
        raise exception 'evidence field % of type image needs max_mb between 1 and 10', v_key
          using errcode = '22023';
      end if;
    end if;
  end loop;
end
$$;

create or replace function private.guard_evidence_fields()
returns trigger
language plpgsql
as $$
begin
  perform private.validate_evidence_fields(new.evidence_fields);
  return new;
end
$$;

create trigger payment_gateways_validate_fields
  before insert or update of evidence_fields on public.payment_gateways
  for each row
  execute function private.guard_evidence_fields();

-- ---------------------------------------------------------------------------
-- Order state machine
-- ---------------------------------------------------------------------------

create or replace function private.guard_order_status()
returns trigger
language plpgsql
as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if not (
    (old.status = 'draft' and new.status in ('awaiting_proof', 'locked', 'expired'))
    or (old.status = 'awaiting_proof' and new.status in ('under_review', 'locked', 'expired'))
    or (old.status = 'under_review' and new.status in ('approved', 'rejected', 'locked', 'expired'))
    or (old.status = 'rejected' and new.status in ('under_review', 'locked', 'expired'))
    -- `locked` is the one terminal state that reopens, and only for an admin
    -- reset. Without this branch api.admin_reset_probes() would be refused by
    -- its own trigger, which is the kind of failure that only shows up in
    -- production when a customer is already locked out.
    or (old.status = 'locked' and new.status in ('awaiting_proof', 'expired'))
  ) then
    raise exception 'illegal order transition % -> %', old.status, new.status using errcode = '22023';
  end if;

  -- Terminal states have no outgoing transition at all: the list above omits
  -- them entirely, so this branch is what rejects an attempt to un-approve.
  return new;
end
$$;

create trigger orders_guard_status
  before update of status on public.orders
  for each row
  execute function private.guard_order_status();

-- Granting on approval rather than in the RPC means an order cannot reach
-- `approved` without access, whichever path approved it. Idempotent, so a
-- double-clicked button cannot create a second grant.
create or replace function private.grant_on_approval()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    insert into public.access_grants (user_id, link_id, via_order_id)
    values (new.user_id, new.link_id, new.id)
    on conflict (user_id, link_id) do nothing;
  end if;
  return null;
end
$$;

create trigger orders_grant_on_approval
  after update of status on public.orders
  for each row
  execute function private.grant_on_approval();

-- Written by trigger rather than by application code, so the trail survives a
-- bypassed admin UI.
create or replace function private.audit_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.audit_log (actor_id, action, target_table, target_id, meta)
    values (
      auth.uid(),
      'order.created',
      'orders',
      new.id::text,
      jsonb_build_object('status', new.status, 'link_id', new.link_id)
    );
  elsif new.status is distinct from old.status then
    insert into public.audit_log (actor_id, action, target_table, target_id, meta)
    values (
      coalesce(new.reviewed_by, auth.uid()),
      'order.status_changed',
      'orders',
      new.id::text,
      jsonb_build_object('from', old.status, 'to', new.status)
    );
  end if;
  return null;
end
$$;

create trigger orders_audit
  after insert or update on public.orders
  for each row
  execute function private.audit_order();

-- ---------------------------------------------------------------------------
-- Generic triggers on the tables
-- ---------------------------------------------------------------------------

create trigger site_settings_touch
  before update on public.site_settings
  for each row
  execute function private.touch_updated_at();

create trigger site_settings_tidy
  before insert or update on public.site_settings
  for each row
  execute function private.tidy_blank_to_null();

create trigger payment_gateways_touch
  before update on public.payment_gateways
  for each row
  execute function private.touch_updated_at();

create trigger payment_gateways_tidy
  before insert or update on public.payment_gateways
  for each row
  execute function private.tidy_blank_to_null();

create trigger paywall_links_touch
  before update on public.paywall_links
  for each row
  execute function private.touch_updated_at();

create trigger paywall_links_tidy
  before insert or update on public.paywall_links
  for each row
  execute function private.tidy_blank_to_null();

create trigger order_evidence_append_only
  before update or delete on public.order_evidence
  for each row
  execute function private.deny_mutation();

create trigger audit_log_append_only
  before update or delete on public.audit_log
  for each row
  execute function private.deny_mutation();

-- ---------------------------------------------------------------------------
-- Curated read views
--
-- `security_invoker` keeps row filtering in the hands of the base table's RLS
-- rather than silently elevating to the view owner, and the base tables carry
-- matching column-level grants so an invoker can actually read through them.
--
-- What is absent is the point:
--   * min_amount_override / hide_min_override — a hidden minimum must have no
--     read path at all, not merely be hidden by the client.
--   * unlock_body_md_* — the paid content, served only to a customer with a
--     grant, by api.get_unlocked_link().
-- ---------------------------------------------------------------------------

create view public.paywall_links_public
with (security_invoker = true)
as
select
  id,
  slug,
  title_en,
  title_bn,
  teaser_md_en,
  teaser_md_bn,
  unlock_cta_label_en,
  unlock_cta_label_bn,
  unlock_cta_url,
  sort_order
from public.paywall_links
where is_active;

create view public.payment_gateways_public
with (security_invoker = true)
as
select
  id,
  kind,
  account_number,
  account_name,
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

-- ---------------------------------------------------------------------------
-- Grants
--
-- Revoke first, then add back only what is needed. Policies filter rows; only
-- grants decide whether a table is reachable, so a missing grant must be the
-- default state rather than something to remember to tighten later.
-- ---------------------------------------------------------------------------

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

-- The account number is public by design: the customer needs it to pay.
grant select on public.payment_gateways_public to anon, authenticated;
grant select on public.paywall_links_public to anon, authenticated;

-- Column-level grants on the base tables back the security_invoker views.
-- The minimum columns are deliberately not granted, so they are unreachable
-- through any path.
grant select (id, slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
              unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
              sort_order, is_active)
  on public.paywall_links to anon, authenticated;

grant select (id, kind, account_number, account_name, name_en, name_bn,
              instructions_md_en, instructions_md_bn, reference_prompt_en,
              reference_prompt_bn, supports_reference, evidence_fields,
              sort_order, is_active)
  on public.payment_gateways to anon, authenticated;

alter table public.site_settings enable row level security;
alter table public.staff enable row level security;
alter table public.payment_gateways enable row level security;
alter table public.paywall_links enable row level security;
alter table public.orders enable row level security;
alter table public.order_evidence enable row level security;
alter table public.access_grants enable row level security;
alter table public.customer_contacts enable row level security;
alter table public.recovery_requests enable row level security;
alter table public.otp_challenges enable row level security;
alter table public.audit_log enable row level security;

-- The owner can point the shop at a model, and the credential behind it stays in the vault.
--
-- The previous commit made it possible to write an `ai_provider` bundle. This is the surface
-- that does it, which means three new things have to exist: a registered AI provider, a row
-- to hang the bundle on, and an RPC that is allowed to write it.
--
-- ---------------------------------------------------------------------------
-- What identifies an AI credential subject
-- ---------------------------------------------------------------------------
--
-- A gateway bundle is keyed by `payment_gateways.id`, so the bundle's `subject_id` points at
-- something with a row, a lifecycle and an admin page. An AI provider has none of those yet,
-- and inventing a sentinel uuid to stand in for "the shop" would put the identity of the
-- subject somewhere only a comment knows.
--
-- So there is one row. `private.ai_settings` is a singleton, enforced the same way
-- `public.site_settings` enforces its own, and its id is the subject id. That buys three
-- things a sentinel would not: the bundle's subject is a row that exists, a second AI
-- provider is a later migration rather than a schema change, and "which provider is this
-- shop on" has somewhere to live that is not inside a credential blob.

create table private.ai_settings (
  id uuid primary key default gen_random_uuid(),
  singleton smallint not null default 1,
  provider text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint ai_settings_singleton check (singleton = 1),
  constraint ai_settings_singleton_unique unique (singleton)
);

create trigger ai_settings_touch
  before update on private.ai_settings
  for each row
  execute function private.touch_updated_at();

comment on table private.ai_settings is
  'One row: which AI provider this shop generates copy with. Its id is the subject id of '
  'the ai_provider credential bundle, so the bundle points at a row rather than at a '
  'constant that only a comment explains.';

revoke all on private.ai_settings from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The provider check, at the row
-- ---------------------------------------------------------------------------
--
-- The same argument as `guard_provider_known`: a value that decides which backend a paid
-- request runs against must fail on the row, not at the HTTP call. A CHECK constraint cannot
-- hold a subquery, so this is a trigger, and the message names the offender - which the
-- generated constraint message never did.

create or replace function private.guard_ai_provider_known()
returns trigger
language plpgsql
as $$
begin
  if new.provider is not null and not exists (
    select 1 from private.auto_providers p
    where p.slug = new.provider and p.is_active and p.subject_kind = 'ai_provider'
  ) then
    raise exception 'unknown ai_provider provider: %', new.provider using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger ai_settings_guard_provider
  before insert or update of provider on private.ai_settings
  for each row
  execute function private.guard_ai_provider_known();

-- ---------------------------------------------------------------------------
-- The provider the shop can pick
-- ---------------------------------------------------------------------------
--
-- One row, and it is deliberately not a hardcoded list in the RPC: the field schema is what
-- the admin form renders, so a second provider later is a seed insert rather than a deploy.
--
-- `base_url` and `model` are marked non-secret. They are still stored in the vault and still
-- write-only over the API - `secret` decides what the admin form masks, nothing more - but
-- masking a URL an operator has to be able to read back would make the form unusable, and
-- neither value is a credential.
--
-- `base_url` is the API root, `https://api.example.com/v1`, and not the full chat-completions
-- endpoint. Recorded here because the caller in `_shared/ai/provider.ts` wants the endpoint and
-- the two are one `chat/completions` apart, and a field named `url` holding a prefix is how a
-- request ends up 404ing on a perfectly good key. The caller joins them; this table stores what
-- the operator's dashboard told them to copy.

insert into private.auto_providers (slug, subject_kind, name_en, name_bn, fields, sort_order)
values (
  'openai_compatible',
  'ai_provider',
  'OpenAI-compatible model',
  null,
  '[
    {"key":"api_key","label_en":"API key","secret":true},
    {"key":"base_url","label_en":"Base URL","secret":false},
    {"key":"model","label_en":"Model","secret":false}
  ]'::jsonb,
  10
);

-- ---------------------------------------------------------------------------
-- Reading, for the form
-- ---------------------------------------------------------------------------
--
-- Owner-only, like `admin_upsert_gateway`. Whether a credential exists is itself owner-only
-- configuration.
--
-- `admin_auto_providers` is deliberately *not* reused here: that one is staff-readable because
-- rendering an automatic-gateway form needs the field schema and staff already reach the
-- gateway pages. Nothing on a staff page renders an AI provider list, so this one guards too -
-- field labels are not credentials, but they are part of the same owner-only page and the
-- cheaper default is the one that does not have to be walked back later.

create or replace function api.admin_ai_providers()
returns table (
  slug text,
  name_en text,
  name_bn text,
  fields jsonb,
  is_active boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.slug, p.name_en, p.name_bn, p.fields, p.is_active
  from private.auto_providers p
  where p.subject_kind = 'ai_provider' and private.is_owner()
  order by p.sort_order, p.slug
$$;

revoke all on function api.admin_ai_providers() from public, anon, authenticated;
grant execute on function api.admin_ai_providers() to authenticated;

-- Existence, and the one value the form has to render. Deliberately narrower than it could be:
-- no key names, which `admin_ai_providers` above does return because that list is what the form
-- is built from, and no partial state that would let the page disagree with the database.
create or replace function api.admin_ai_settings()
returns table (
  provider text,
  has_credentials boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not private.is_owner() then null::text
    else (
      select s.provider
      from private.ai_settings s
      limit 1
    )
  end,
  case
    when not private.is_owner() then false
    else exists (
      select 1
      from private.ai_settings s
      join private.secret_bundles b
        on b.subject_kind = 'ai_provider' and b.subject_id = s.id
    )
  end
$$;

revoke all on function api.admin_ai_settings() from public, anon, authenticated;
grant execute on function api.admin_ai_settings() to authenticated;

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------
--
-- Owner-only, and credentials are not required - same reasoning as the gateway form. A shop can
-- pick a provider before it has a key, and the Edge Function lookup then returning no row at all
-- is a clear "not configured" where an opaque provider 401 is not.
--
-- Merge semantics come from the writer, not from here: keys in the payload are written, keys
-- absent are kept, and the form renders a mask rather than reading a secret back.

create or replace function api.admin_upsert_ai_settings(p_settings jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row private.ai_settings;
  v_before private.ai_settings;
  v_provider text := nullif(btrim(p_settings ->> 'provider'), '');
  v_credentials jsonb := coalesce(nullif(p_settings -> 'credential_bundle', 'null'::jsonb), '{}'::jsonb);
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_before from private.ai_settings limit 1;

  -- Switching provider without resending credentials is refused rather than half-applied.
  -- The writer merges into the existing secret and then keeps only the new provider's declared
  -- keys, so a switch carrying one field would silently drop the old provider's fields and
  -- silently omit the new provider's required ones - a bundle that reads as configured and
  -- fails at the first request. Testing the payload for non-emptiness would not catch it:
  -- `{"model": "..."}` is not empty, and it is not a credential either.
  --
  -- So a switch requires every declared field of the incoming provider, and a blank string
  -- counts as absent because that is what a cleared input sends. The condition is the new
  -- provider's field list rather than a fixed set of names, which is what lets a second
  -- provider be seeded later without revisiting this function.
  --
  -- Same-provider saves are deliberately untouched. Those are rotations, and the form sends one
  -- field at a time against a mask.
  if v_before.id is not null
     and v_provider is distinct from v_before.provider
     and v_provider is not null
     and exists (
       select 1
       from unnest(private.provider_field_keys(v_provider, 'ai_provider')) as k(field_key)
       where nullif(btrim(v_credentials ->> k.field_key), '') is null
     ) then
    raise exception
      'changing the AI provider requires sending all of its credentials in the same save'
      using errcode = '22023';
  end if;

  if v_before.id is null then
    insert into private.ai_settings (provider) values (v_provider) returning * into v_row;
  else
    update private.ai_settings
    set provider = v_provider
    where singleton = 1
    returning * into v_row;
  end if;

  if v_provider is not null and v_credentials <> '{}'::jsonb then
    perform private.store_credential_bundle('ai_provider', v_row.id, v_provider, v_credentials);
  elsif v_provider is null then
    -- Dropping the provider retires the bundle rather than leaving an orphan holding a live
    -- API key in the vault with nothing pointing at it.
    delete from private.secret_bundles
    where subject_kind = 'ai_provider' and subject_id = v_row.id;
  end if;
end;
$$;

revoke all on function api.admin_upsert_ai_settings(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_ai_settings(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- The Edge Function's lookup
-- ---------------------------------------------------------------------------
--
-- Service-role only, and deliberately not joined to the credentials: it answers "which bundle,
-- and for whom", never "what is in it". The caller resolves the id and then opens it through
-- `api.secret_bundle_open`, so no function other than that one handles the plaintext.
--
-- The provider comes back with the id, and that is the reason this is not the bare `uuid` that
-- `api.gateway_credential_bundle` returns. A gateway caller already knows its provider: it read
-- the row it was asked to pay with. An AI caller has no such row, and `private.ai_settings` is
-- unreachable to a service-role client precisely because it is private - so a bare id would
-- leave the provider to be hardcoded in the function or guessed out of the bundle's keys. Both
-- throw away the registry that exists so the provider list is data rather than code.
--
-- Zero rows, rather than a row with a null id, when the shop has chosen nothing. `provider is not
-- null` is the whole of the "is this configured" answer, and a bundle id here would hand the
-- caller an empty configuration dressed up as a working one.

create or replace function api.ai_credential_bundle()
returns table (
  provider text,
  bundle uuid
)
language sql
volatile
security definer
set search_path = ''
as $$
  select s.provider, b.id
  from private.ai_settings s
  left join private.secret_bundles b
    on b.subject_kind = 'ai_provider' and b.subject_id = s.id
  where s.provider is not null
$$;

revoke all on function api.ai_credential_bundle() from public, anon, authenticated;
grant execute on function api.ai_credential_bundle() to service_role;

-- `private.ai_settings` is reachable only through the RPCs above, exactly as
-- `private.secret_bundles` is. Re-stated because a table added to the private schema is a
-- table nobody has thought about yet.
revoke all on private.ai_settings from public, anon, authenticated;
grant usage on schema private to service_role;

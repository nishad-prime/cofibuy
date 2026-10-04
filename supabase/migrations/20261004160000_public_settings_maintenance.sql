-- Public settings the browser can read, and a sitewide maintenance switch.
--
-- The problem this solves is that `public.site_settings` has RLS enabled with no
-- policies and no grants, so nothing global can reach the browser at all, and
-- `api.admin_settings()` is owner-only. A customer page therefore cannot know
-- whether the shop is taking orders until it tries and reads an error.
--
-- Reading goes through a function rather than a grant, for the same reason
-- `api.get_public_copy()` does: the projection is the contract, so a column added
-- to the table later is not automatically published.

-- ---------------------------------------------------------------------------
-- Maintenance mode
-- ---------------------------------------------------------------------------

alter table public.site_settings
  add column maintenance_mode boolean not null default false;

comment on column public.site_settings.maintenance_mode is
  'When true, create_order refuses and get_public_link reports it. The storefront '
  'hides the order form on the same flag, but the database is the gate.';

-- ---------------------------------------------------------------------------
-- Public read
-- ---------------------------------------------------------------------------

create or replace function api.get_public_settings()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    -- The same rule as `get_public_link`: a hidden minimum has no read path, so the
    -- global value is withheld here too. `hide_min_amount` itself is a display choice
    -- and is safe to publish; the number it hides is not. `get_public_link` resolves
    -- per-link overrides and remains the only place the effective minimum is exposed.
    'min_amount', case when s.hide_min_amount then null else s.min_amount end,
    'hide_min_amount', s.hide_min_amount,
    'recovery_enabled', s.recovery_enabled,
    'maintenance_mode', s.maintenance_mode,
    'default_lang', s.default_lang,
    'contact', s.contact
  )
  from public.site_settings s
  where s.id = 1
$$;

-- Anon as well as authenticated: the storefront has to know it is in maintenance
-- before anyone signs in.
--
-- `create or replace` re-grants EXECUTE to PUBLIC, because that is the default for
-- a new function. Every `create or replace` below is therefore followed by an
-- explicit revoke, or the function silently becomes callable by every role in the
-- database -- which is what `supabase/tests/07_rls.sql` exists to catch.
revoke all on function api.get_public_settings() from public;
grant execute on function api.get_public_settings() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Maintenance gate
--
-- Both existing entry points are moved aside under a name nothing is granted to,
-- and thin wrappers take their place. The alternative -- pasting a copy of each
-- body with one extra `if` -- is how a projection silently drifts out of sync with
-- the thing it is supposed to describe, and `get_public_link` in particular encodes
-- the hidden-minimum rule that must not be retyped by hand.
--
-- The wrappers are `security definer` like the originals, so the inner functions
-- still read the tables as their owner, and Postgres owns both, so the wrappers can
-- still call them.
--
-- The revokes name `anon` and `authenticated` explicitly rather than only `public`.
-- Renaming a function carries its grants with it, so the original
-- `grant execute ... to anon, authenticated` on `get_public_link` is still attached
-- to `public_link_payload` after the rename. Revoking from `public` alone leaves
-- those direct grants in place and the inner function stays callable -- which is
-- how `supabase/tests/10_settings.sql` caught it.
-- ---------------------------------------------------------------------------

alter function api.get_public_link(text) rename to public_link_payload;
revoke all on function api.public_link_payload(text) from public, anon, authenticated;

create or replace function api.get_public_link(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when payload.base is null then null
    else payload.base || jsonb_build_object(
      -- Reported rather than raised. The link is still worth showing: a customer
      -- should be able to read what they would have bought and why they cannot pay
      -- for it right now, which is a better answer than an error page.
      'maintenance_mode', (select s.maintenance_mode from public.site_settings s where s.id = 1)
    )
  end
  from (select api.public_link_payload(p_slug) as base) payload
$$;

revoke all on function api.get_public_link(text) from public;
grant execute on function api.get_public_link(text) to anon, authenticated;

alter function api.create_order(text, uuid, numeric) rename to create_order_unchecked;
revoke all on function api.create_order_unchecked(text, uuid, numeric) from public, anon, authenticated;

create or replace function api.create_order(
  p_slug text,
  p_gateway_id uuid,
  p_amount numeric
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- Before anything else, so the answer does not depend on whether the slug happens
  -- to exist or which gateway was named. An operator flipping this switch wants
  -- every order attempt refused, not a mix of "not found" and "temporarily closed".
  if (select s.maintenance_mode from public.site_settings s where s.id = 1) then
    raise exception 'shop temporarily closed' using errcode = 'P0001';
  end if;

  return api.create_order_unchecked(p_slug, p_gateway_id, p_amount);
end;
$$;

revoke all on function api.create_order(text, uuid, numeric) from public;
grant execute on function api.create_order(text, uuid, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Owner-gated setter
-- ---------------------------------------------------------------------------

create or replace function api.admin_set_settings(p_settings jsonb)
returns public.site_settings
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.site_settings;
  v_unknown text;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- `admin_set_copy` raises on an unknown key and the copy panel depends on it, so
  -- the same rule belongs here. Silently dropping a key means a typo looks like it
  -- saved, which is the harder bug to notice.
  select string_agg(k.key, ', ') into v_unknown
  from jsonb_object_keys(coalesce(p_settings, '{}'::jsonb)) as k(key)
  where k.key not in (
    'min_amount',
    'hide_min_amount',
    'default_lang',
    'recovery_enabled',
    'contact',
    'maintenance_mode'
  );

  if v_unknown is not null then
    raise exception 'unknown settings key: %', v_unknown;
  end if;

  update public.site_settings
  set min_amount = coalesce((p_settings ->> 'min_amount')::numeric, min_amount),
      hide_min_amount = coalesce((p_settings ->> 'hide_min_amount')::boolean, hide_min_amount),
      default_lang = coalesce(p_settings ->> 'default_lang', default_lang),
      -- Recovery ships gated. Turning it on before the OTP worker is deployed leaves
      -- customers waiting for a code that never arrives, so the default is off and
      -- the switch is deliberate.
      recovery_enabled = coalesce((p_settings ->> 'recovery_enabled')::boolean, recovery_enabled),
      -- Present-but-blank clears it, so an operator can genuinely remove the contact
      -- details rather than only ever overwriting them.
      contact = case
        when p_settings ? 'contact' then nullif(btrim(p_settings ->> 'contact'), '')
        else contact
      end,
      maintenance_mode = coalesce((p_settings ->> 'maintenance_mode')::boolean, maintenance_mode)
  where id = 1
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function api.admin_set_settings(jsonb) from public;
grant execute on function api.admin_set_settings(jsonb) to authenticated;
-- A store-wide currency code, so the symbol the customer reads is a setting rather
-- than a compile-time constant in `src/lib/money.ts`.
--
-- The allowlist is deliberate rather than accepting any well-formed ISO-4217 code.
-- The client formats through `Intl.NumberFormat`; a code the UI never offered is a
-- configuration mistake that would then be printed to every customer. The list is
-- mirrored in `src/lib/currency.ts` and asserted against this file by
-- `src/lib/currency.test.ts`, so the two cannot drift.
--
-- Whole units only: the app formats every amount with zero fraction digits, which
-- matches the existing numeric columns. Introducing a sub-unit currency would be a
-- schema question, not a formatting one.

alter table public.site_settings
  add column currency text not null default 'BDT';

comment on column public.site_settings.currency is
  'ISO 4217 code used to format money. Whole units only; the app never renders fractions.';

alter table public.site_settings
  add constraint site_settings_currency_known
  -- currency-allowlist:begin
  check (currency in ('BDT', 'USD', 'INR', 'PKR', 'NPR', 'LKR', 'MYR', 'AED', 'SAR', 'EUR', 'GBP'));
  -- currency-allowlist:end

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
    'currency', s.currency,
    'contact', s.contact
  )
  from public.site_settings s
  where s.id = 1
$$;

-- `create or replace` re-grants EXECUTE to PUBLIC, because that is the default for a
-- new function, so the grant from 20261004160000 has to be restated as a revoke too.
revoke all on function api.get_public_settings() from public;
grant execute on function api.get_public_settings() to anon, authenticated;

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
  v_currency text;
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
    'maintenance_mode',
    'currency'
  );

  if v_unknown is not null then
    raise exception 'unknown settings key: %', v_unknown;
  end if;

  -- Normalised to upper case and checked before the update, so the answer is the
  -- same friendly invalid-parameter error as an unknown key rather than a raw
  -- check-constraint violation. The constraint stays as the backstop for a write
  -- that does not come through this function.
  if p_settings ? 'currency' then
    v_currency := upper(btrim(p_settings ->> 'currency'));
    if v_currency is not null and v_currency not in (
      'BDT', 'USD', 'INR', 'PKR', 'NPR', 'LKR', 'MYR', 'AED', 'SAR', 'EUR', 'GBP'
    ) then
      raise exception 'unsupported currency: %', v_currency using errcode = '22023';
    end if;
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
      maintenance_mode = coalesce((p_settings ->> 'maintenance_mode')::boolean, maintenance_mode),
      -- A null currency keeps the existing code; only a present, non-null value moves
      -- it, and it has already been validated above.
      currency = coalesce(v_currency, currency)
  where id = 1
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function api.admin_set_settings(jsonb) from public;
grant execute on function api.admin_set_settings(jsonb) to authenticated;

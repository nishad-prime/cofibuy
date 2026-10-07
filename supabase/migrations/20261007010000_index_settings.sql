-- ---------------------------------------------------------------------------
-- The index becomes configurable.
--
-- The home page used to be a fixed grid under two copy keys. The index is now
-- the shop's front door — the list of pages that are not hidden from it — and
-- a front door carries its own words. Four columns on the settings singleton:
-- a heading and a subheading, each in both locales, because the storefront is
-- bilingual end to end and an index that could only speak one language would
-- be the single place the rule broke.
--
-- Nothing is invented here that the copy store already did; but the copy store
-- is global chrome for every screen, and the index heading is not chrome — it
-- is content an owner rewords on a whim, next to the same owner's page fields.
-- Living in settings means it saves in one RPC with everything else the shop
-- publishes.
-- ---------------------------------------------------------------------------

alter table public.site_settings
  add column index_heading_en text,
  add column index_heading_bn text,
  add column index_subheading_en text,
  add column index_subheading_bn text;

create or replace function api.get_public_settings()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    -- The same rule as `get_public_page`: a hidden minimum has no read path, so the
    -- global value is withheld here too. `hide_min_amount` itself is a display choice
    -- and is safe to publish; the number it hides is not. `get_public_page` resolves
    -- per-page overrides and remains the only place the effective minimum is exposed.
    'min_amount', case when s.hide_min_amount then null else s.min_amount end,
    'hide_min_amount', s.hide_min_amount,
    'recovery_enabled', s.recovery_enabled,
    'maintenance_mode', s.maintenance_mode,
    'default_lang', s.default_lang,
    'currency', s.currency,
    'contact', s.contact,
    'index_heading_en', s.index_heading_en,
    'index_heading_bn', s.index_heading_bn,
    'index_subheading_en', s.index_subheading_en,
    'index_subheading_bn', s.index_subheading_bn
  )
  from public.site_settings s
  where s.id = 1
$$;

revoke all on function api.get_public_settings() from public, anon, authenticated;
grant execute on function api.get_public_settings() to anon, authenticated;

create or replace function api.admin_set_settings(p_settings jsonb)
returns site_settings
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
    'currency',
    'index_heading_en',
    'index_heading_bn',
    'index_subheading_en',
    'index_subheading_bn'
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
      currency = coalesce(v_currency, currency),
      -- The index words follow the contact pattern: present-but-blank clears, absent
      -- keeps, so a form that does not render a field cannot blank it by saving.
      index_heading_en = case
        when p_settings ? 'index_heading_en' then nullif(btrim(p_settings ->> 'index_heading_en'), '')
        else index_heading_en
      end,
      index_heading_bn = case
        when p_settings ? 'index_heading_bn' then nullif(btrim(p_settings ->> 'index_heading_bn'), '')
        else index_heading_bn
      end,
      index_subheading_en = case
        when p_settings ? 'index_subheading_en' then nullif(btrim(p_settings ->> 'index_subheading_en'), '')
        else index_subheading_en
      end,
      index_subheading_bn = case
        when p_settings ? 'index_subheading_bn' then nullif(btrim(p_settings ->> 'index_subheading_bn'), '')
        else index_subheading_bn
      end
  where id = 1
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function api.admin_set_settings(jsonb) from public, anon, authenticated;
grant execute on function api.admin_set_settings(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Amount presets.
--
-- The amount field used to be a bare number input, which asked the customer a
-- question the shop had already answered: how much is this worth? The operator
-- can now configure a handful of prices per page - the chips the paywall shows
-- - and the customer taps one, or picks Custom and types anything at or above
-- the minimum.
--
-- The presets live on the page, because they are its price list, not the
-- shop's. Validation is the same shape rule as template_config: an array of
-- positive numbers, at most eight, because a wall of chips is its own kind of
-- question. Values below the page's effective minimum are not refused here -
-- the minimum is resolved per request (global, override, hidden) - the paywall
-- simply does not render chips a customer cannot legally tap.
-- ---------------------------------------------------------------------------

alter table public.pages
  add column amount_presets jsonb not null default '[]';

-- Same trigger as the template guard: one write-time place that refuses a
-- shape the app cannot render.
create or replace function private.guard_page_template() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.template not in ('standard', 'landing') then
    raise exception 'unknown template %', new.template using errcode = '22023';
  end if;

  -- The config is handed to whatever form and renderer the template declares.
  -- Anything but an object has no meaning on either side of that contract.
  if jsonb_typeof(new.template_config) <> 'object' then
    raise exception 'template_config must be a JSON object' using errcode = '22023';
  end if;

  -- Presets: a JSON array of positive numbers, eight at most. Every other
  -- shape is refused at the write, not at the customer's first render.
  if jsonb_typeof(new.amount_presets) <> 'array' then
    raise exception 'amount_presets must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(new.amount_presets) > 8 then
    raise exception 'at most 8 amount presets' using errcode = '22023';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(new.amount_presets) v
    where jsonb_typeof(v) <> 'number' or (v)::numeric < 1
  ) then
    raise exception 'amount presets must be positive numbers' using errcode = '22023';
  end if;

  return new;
end
$$;

-- public_page_payload_v1: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.public_page_payload_v1(p_slug text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with link as (
    select
      l.*,
      s.min_amount as global_min,
      s.hide_min_amount as global_hide
    from public.pages l
    cross join public.site_settings s
    where l.slug = p_slug and l.is_active and s.id = 1
  ),
  resolved as (
    select
      link.*,
      coalesce(link.min_amount_override, link.global_min) as min_amount,
      coalesce(link.hide_min_override, link.global_hide) as hide_min
    from link
  )
  select jsonb_build_object(
    'id', r.id,
    'slug', r.slug,
    'title_en', r.title_en,
    'title_bn', r.title_bn,
    'teaser_md_en', r.teaser_md_en,
    'teaser_md_bn', r.teaser_md_bn,
    'unlock_cta_label_en', r.unlock_cta_label_en,
    'unlock_cta_label_bn', r.unlock_cta_label_bn,
    'unlock_cta_url', r.unlock_cta_url,
    'template', r.template,
    'template_config', r.template_config,
    -- The single most important expression in this file. When the minimum is
    -- hidden there is no path by which a client learns it: not here, not
    -- through the public view, not through a column grant on the base table.
    'min_amount', case when r.hide_min then null else r.min_amount end,
    'min_hidden', r.hide_min,
    'amount_presets', r.amount_presets,
    'gateways', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', g.id,
            'kind', g.kind,
            'account_number', g.account_number,
            'account_name', g.account_name,
            'name_en', g.name_en,
            'name_bn', g.name_bn,
            'instructions_md_en', g.instructions_md_en,
            'instructions_md_bn', g.instructions_md_bn,
            'reference_prompt_en', g.reference_prompt_en,
            'reference_prompt_bn', g.reference_prompt_bn,
            'supports_reference', g.supports_reference,
            'evidence_fields', g.evidence_fields
          )
          order by g.sort_order, g.name_en
        )
        from public.payment_gateways g
        where g.is_active
      ),
      '[]'::jsonb
    )
  )
  from resolved r
$function$;
revoke all on function api.public_page_payload_v1(p_slug text) from public, anon, authenticated;

revoke all on function api.public_page_payload_v1(text) from public, anon, authenticated;

-- admin_upsert_page: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.admin_upsert_page(p_page jsonb)
 RETURNS pages
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row public.pages;
  v_id uuid := nullif(p_page ->> 'id', '')::uuid;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  insert into public.pages (
    id, slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
    unlock_body_md_en, unlock_body_md_bn,
    unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
    min_amount_override, hide_min_override, is_active, is_listed, sort_order,
    template, template_config, amount_presets
  )
  values (
    coalesce(v_id, gen_random_uuid()),
    p_page ->> 'slug',
    p_page ->> 'title_en',
    p_page ->> 'title_bn',
    p_page ->> 'teaser_md_en',
    p_page ->> 'teaser_md_bn',
    p_page ->> 'unlock_body_md_en',
    p_page ->> 'unlock_body_md_bn',
    p_page ->> 'unlock_cta_label_en',
    p_page ->> 'unlock_cta_label_bn',
    p_page ->> 'unlock_cta_url',
    nullif(p_page ->> 'min_amount_override', '')::numeric,
    nullif(p_page ->> 'hide_min_override', '')::boolean,
    coalesce((p_page ->> 'is_active')::boolean, false),
    coalesce((p_page ->> 'is_listed')::boolean, true),
    coalesce((p_page ->> 'sort_order')::integer, 0),
    coalesce(p_page ->> 'template', 'standard'),
    coalesce(p_page -> 'template_config', '{}'::jsonb),
    coalesce(p_page -> 'amount_presets', '[]'::jsonb)
  )
  on conflict (id) do update
  set slug = excluded.slug,
      title_en = excluded.title_en,
      title_bn = excluded.title_bn,
      teaser_md_en = excluded.teaser_md_en,
      teaser_md_bn = excluded.teaser_md_bn,
      unlock_body_md_en = excluded.unlock_body_md_en,
      unlock_body_md_bn = excluded.unlock_body_md_bn,
      unlock_cta_label_en = excluded.unlock_cta_label_en,
      unlock_cta_label_bn = excluded.unlock_cta_label_bn,
      unlock_cta_url = excluded.unlock_cta_url,
      min_amount_override = excluded.min_amount_override,
      hide_min_override = excluded.hide_min_override,
      is_active = excluded.is_active,
      is_listed = excluded.is_listed,
      sort_order = excluded.sort_order,
      template = excluded.template,
      template_config = excluded.template_config,
      amount_presets = excluded.amount_presets
  returning * into v_row;

  return v_row;
end
$function$;

revoke all on function api.admin_upsert_page(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_page(jsonb) to authenticated;

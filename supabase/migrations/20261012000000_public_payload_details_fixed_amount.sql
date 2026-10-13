-- Three fixes that only matter together:
--
-- 1. The public payload publishes what the payment form needs BEFORE any
--    order exists: for a manual method the customer must see where to send
--    the money (account fields, account number/name, instructions) and the
--    proof fields the evidence form asks for. These were trimmed from the
--    payload when the per-order gateway snapshot was introduced, which left
--    the pre-order form with an empty account card and an evidence form with
--    no fields. Marketing banners stay public with the rest of the card.
-- 2. `pages.fixed_amount`: an optional price. When set, the customer cannot
--    choose an amount - the send step shows the figure and the client sends
--    exactly it.
-- 3. `admin_upsert_page` persists the new column.

-- ---------------------------------------------------------------------------
-- Public payload: gateways carry their pre-order details again.
-- ---------------------------------------------------------------------------
create or replace function api.public_page_payload(p_slug text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
    when base.doc is null then null
    else jsonb_set(base.doc, '{gateways}', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', g.id,
          'kind', g.kind,
          'name_en', g.name_en,
          'name_bn', g.name_bn,
          'provider', g.provider,
          'sort_order', g.sort_order,
          'country', g.country,
          'is_primary_for_country', g.is_primary_for_country,
          'banner_url', g.banner_url,
          'banner_small_url', g.banner_small_url,
          'account_number', g.account_number,
          'account_name', g.account_name,
          'account_fields', g.account_fields,
          'instructions_md_en', g.instructions_md_en,
          'instructions_md_bn', g.instructions_md_bn,
          'supports_reference', g.supports_reference,
          'evidence_fields', g.evidence_fields
        )
        order by g.sort_order, g.name_en
      )
      from public.payment_gateways g
      where g.is_active
    ), '[]'::jsonb))
  end
  from (select api.public_page_payload_v1(p_slug) as doc) base
$function$;

revoke all on function api.public_page_payload(p_slug text) from public, anon, authenticated;
grant execute on function api.public_page_payload(p_slug text) to anon;
grant execute on function api.public_page_payload(p_slug text) to authenticated;

-- ---------------------------------------------------------------------------
-- Fixed-amount pages.
-- ---------------------------------------------------------------------------
alter table public.pages
  add column if not exists fixed_amount numeric;

alter table public.pages
  add constraint pages_fixed_amount_positive
  check (fixed_amount is null or fixed_amount > 0);

-- ---------------------------------------------------------------------------
-- Admin write path: persist fixed_amount.
-- ---------------------------------------------------------------------------
create or replace function api.admin_upsert_page(p_page jsonb)
 RETURNS pages
 LANGUAGE plpgsql
 VOLATILE
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
    template, template_config, amount_presets, fixed_amount
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
    coalesce(p_page -> 'amount_presets', '[]'::jsonb),
    nullif(p_page ->> 'fixed_amount', '')::numeric
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
      amount_presets = excluded.amount_presets,
      fixed_amount = excluded.fixed_amount
  returning * into v_row;

  return v_row;
end
$function$;

revoke all on function api.admin_upsert_page(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_page(jsonb) to authenticated;

-- The public page doc carries the fixed amount so the client can enforce it.
create or replace function api.public_page_payload_v1(p_slug text)
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
    'fixed_amount', r.fixed_amount,
    'gateways', '[]'::jsonb
  )
  from resolved r
$function$;
revoke all on function api.public_page_payload_v1(p_slug text) from public, anon, authenticated;

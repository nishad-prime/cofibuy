-- The public payload never carried the page's assigned images: page_assets
-- existed in the private schema and the images screen wrote to it, but the
-- storefront received no `images` key, so slot-assigned renders were always
-- empty. The payload now aggregates them, keyed as the templates read them:
-- `hero`, or `benefits.2` for a repeating slot's item index.

create or replace function api.public_page_payload_v1(p_slug text)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
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
    'unlock_cta_label_en', r.unlock_cta_label_en,
    'unlock_cta_label_bn', r.unlock_cta_label_bn,
    'unlock_cta_url', r.unlock_cta_url,
    'template', r.template,
    'template_config', r.template_config,
    'is_listed', r.is_listed,
    'min_amount', case when r.hide_min then null else r.min_amount end,
    'min_hidden', r.hide_min,
    'fixed_amount', r.fixed_amount,
    'amount_presets', coalesce(r.amount_presets, '[]'::jsonb),
    'images', coalesce(
      (
        select jsonb_object_agg(
          case when a.item_index > 0
            then a.slot_key || '.' || a.item_index
            else a.slot_key
          end,
          jsonb_build_object(
            'url', a.public_url,
            'alt_en', a.alt_en,
            'alt_bn', a.alt_bn
          )
        )
        from private.page_assets a
        where a.page_id = r.id and a.public_url is not null and a.public_url <> ''
      ),
      '{}'::jsonb
    ),
    'gateways', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', g.id,
            'kind', g.kind,
            'account_number', g.account_number,
            'account_name', g.account_name,
            'account_fields', g.account_fields,
            'name_en', g.name_en,
            'name_bn', g.name_bn,
            'provider', g.provider,
            'instructions_md_en', g.instructions_md_en,
            'instructions_md_bn', g.instructions_md_bn,
            'evidence_fields', g.evidence_fields,
            'country', g.country,
            'is_primary_for_country', g.is_primary_for_country,
            'banner_url', g.banner_url,
            'banner_small_url', g.banner_small_url
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
grant execute on function api.public_page_payload_v1(p_slug text) to anon;
grant execute on function api.public_page_payload_v1(p_slug text) to authenticated;

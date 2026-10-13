-- Remove fields that no template or customer surface renders.
-- Views depending on the dropped columns are dropped and recreated.

drop view if exists public.pages_public;

alter table public.pages
  drop column if exists teaser_md_en,
  drop column if exists teaser_md_bn;

alter table public.payment_gateways
  drop column if exists reference_prompt_en,
  drop column if exists reference_prompt_bn,
  drop column if exists supports_reference;

create view public.pages_public
with (security_invoker = true)
as
select
  id,
  slug,
  title_en,
  title_bn,
  unlock_cta_label_en,
  unlock_cta_label_bn,
  unlock_cta_url,
  template,
  template_config,
  sort_order
from public.pages
where is_active and is_listed;

grant select on public.pages_public to anon, authenticated;

create or replace function api.list_public_pages()
 returns setof public.pages_public
 language sql
 stable security definer
 set search_path to ''
as $$
  select * from public.pages_public order by sort_order, title_en
$$;

revoke all on function api.list_public_pages() from public, anon, authenticated;
grant execute on function api.list_public_pages() to anon;
grant execute on function api.list_public_pages() to authenticated;

-- The public payload no longer carries teaser or reference fields.
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
    'min_amount', case when r.hide_min then null else r.min_amount end,
    'min_hidden', r.hide_min,
    'fixed_amount', r.fixed_amount,
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

create or replace function api.public_page_payload(p_slug text)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
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
          'banner_small_url', g.banner_small_url
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

create or replace function api.admin_upsert_page(p_page jsonb)
 returns public.pages
 language plpgsql
 volatile
 security definer
 set search_path to ''
as $$
declare
  v_row public.pages;
  v_id uuid := nullif(p_page ->> 'id', '')::uuid;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  insert into public.pages (
    id, slug, title_en, title_bn,
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
    coalesce(p_page ->> 'template', 'sales-landing'),
    coalesce(p_page -> 'template_config', '{}'::jsonb),
    coalesce(p_page -> 'amount_presets', '[]'::jsonb),
    nullif(p_page ->> 'fixed_amount', '')::numeric
  )
  on conflict (id) do update
  set slug = excluded.slug,
      title_en = excluded.title_en,
      title_bn = excluded.title_bn,
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
$$;

revoke all on function api.admin_upsert_page(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_page(jsonb) to authenticated;

-- The manual gateway form no longer edits reference prompts or the
-- supports_reference toggle; the upsert stops writing them.
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
  v_environment text := coalesce(nullif(btrim(p_gateway ->> 'environment'), ''), 'sandbox');
  v_account_fields jsonb := coalesce(nullif(p_gateway -> 'account_fields', 'null'::jsonb), '[]'::jsonb);
  v_evidence_fields jsonb := coalesce(nullif(p_gateway -> 'evidence_fields', 'null'::jsonb), '[]'::jsonb);
  v_credentials jsonb := coalesce(nullif(p_gateway -> 'credential_bundle', 'null'::jsonb), '{}'::jsonb);
  v_weight integer := coalesce(nullif(btrim(p_gateway ->> 'weight'), '')::integer, 1);
  v_country text := nullif(btrim(coalesce(p_gateway ->> 'country', '')), '');
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

  if v_environment not in ('sandbox', 'live') then
    raise exception 'unknown gateway environment: %', v_environment using errcode = '22023';
  end if;

  if v_weight < 1 then
    raise exception 'weight must be at least 1; use is_active to disable a payment method'
      using errcode = '22023';
  end if;

  if v_provider is not null and not exists (
    select 1 from private.auto_providers p
    where p.slug = v_provider and p.is_active and p.subject_kind = 'gateway'
  ) then
    raise exception 'unknown payment provider: %', v_provider using errcode = '22023';
  end if;

  if v_provider is null and v_credentials <> '{}'::jsonb then
    raise exception 'a manual payment method does not take credentials'
      using errcode = '22023';
  end if;

  perform private.validate_account_fields(v_account_fields);

  v_country := case
    when upper(v_country) = 'INTL' or v_country is null then null
    else upper(v_country)
  end;

  if v_id is null then
    insert into public.payment_gateways (
      kind, account_number, account_name, account_fields,
      name_en, name_bn,
      instructions_md_en, instructions_md_bn,
      evidence_fields, is_active, sort_order, weight, provider, environment,
      country, is_primary_for_country, banner_url, banner_small_url
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
      v_evidence_fields,
      coalesce((p_gateway ->> 'is_active')::boolean, true),
      coalesce((p_gateway ->> 'sort_order')::integer, 0),
      v_weight,
      v_provider,
      v_environment,
      v_country,
      coalesce((p_gateway ->> 'is_primary_for_country')::boolean, false),
      nullif(p_gateway ->> 'banner_url', ''),
      nullif(p_gateway ->> 'banner_small_url', '')
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
        evidence_fields = v_evidence_fields,
        is_active = coalesce((p_gateway ->> 'is_active')::boolean, true),
        sort_order = coalesce((p_gateway ->> 'sort_order')::integer, 0),
        weight = v_weight,
        provider = v_provider,
        environment = v_environment,
        country = v_country,
        is_primary_for_country = coalesce((p_gateway ->> 'is_primary_for_country')::boolean, false),
        banner_url = nullif(p_gateway ->> 'banner_url', ''),
        banner_small_url = nullif(p_gateway ->> 'banner_small_url', '')
    where id = v_id
    returning * into v_row;
  end if;

  if not found then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  if v_provider is not null and v_credentials <> '{}'::jsonb then
    perform private.store_credential_bundle('gateway', v_row.id, v_provider, v_credentials);
  elsif v_provider is null then
    delete from private.secret_bundles
    where subject_kind = 'gateway' and subject_id = v_row.id;
  end if;

  return v_row;
end;
$$;

revoke all on function api.admin_upsert_gateway(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_gateway(jsonb) to authenticated;

-- The customer's unlocked page read no longer returns reference fields.
create or replace function api.get_unlocked_page(p_slug text)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select jsonb_build_object(
    'unlock_body_md_en', l.unlock_body_md_en,
    'unlock_body_md_bn', l.unlock_body_md_bn,
    'unlock_cta_label_en', l.unlock_cta_label_en,
    'unlock_cta_label_bn', l.unlock_cta_label_bn,
    'unlock_cta_url', l.unlock_cta_url
  )
  from public.pages l
  where l.slug = p_slug
    and l.is_active
    and exists (
      select 1 from public.access_grants ag
      where ag.user_id = auth.uid()
        and ag.link_id = l.id
        and ag.revoked_at is null
    )
$function$;

revoke all on function api.get_unlocked_page(p_slug text) from public, anon, authenticated;
grant execute on function api.get_unlocked_page(p_slug text) to authenticated;

create or replace function api.my_order_status(p_order_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $$
declare
  v_order public.orders;
  v_gateway public.payment_gateways;
begin
  select * into v_order from public.orders where id = p_order_id and user_id = auth.uid();
  if not found then
    return null;
  end if;

  select * into v_gateway from public.payment_gateways where id = v_order.gateway_id;

  return jsonb_build_object(
    'id', v_order.id,
    'status', v_order.status,
    'reference_code', v_order.reference_code,
    'amount', v_order.amount,
    'expires_at', v_order.expires_at,
    'submitted_at', v_order.submitted_at,
    'attempt_count', v_order.attempt_count,
    'reject_reason_en', v_order.reject_reason_en,
    'reject_reason_bn', v_order.reject_reason_bn,
    'gateway', jsonb_build_object(
      'kind', v_gateway.kind,
      'name_en', v_gateway.name_en,
      'name_bn', v_gateway.name_bn,
      'account_number', v_gateway.account_number,
      'account_name', v_gateway.account_name,
      'account_fields', v_gateway.account_fields,
      'instructions_md_en', v_gateway.instructions_md_en,
      'instructions_md_bn', v_gateway.instructions_md_bn,
      'evidence_fields', v_gateway.evidence_fields
    )
  );
end
$$;

revoke all on function api.my_order_status(uuid) from public, anon, authenticated;
grant execute on function api.my_order_status(uuid) to authenticated;

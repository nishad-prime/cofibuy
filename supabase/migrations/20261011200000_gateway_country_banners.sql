-- Country routing and banner images for gateways.
--
-- Three ideas, one migration:
--
-- 1. A gateway belongs to a country (`country`, ISO-3166 alpha-2) or to the
--    International catch-all (`country IS NULL`). The customer's own country
--    decides which gateways are "home": their primary gets the big banner,
--    their other gateways the normal one, and everyone else the normal one
--    scaled down. When no gateway matches the customer's country, the
--    International gateways take the primary/preferred roles instead.
-- 2. One primary per country, enforced by the database - the customer page
--    never has to arbitrate between two "big" banners of the same country.
--    NULL countries group together for this rule, so there is exactly one
--    International primary.
-- 3. Banners are two public images per gateway: `banner_url` (big, 3:1,
--    recommended 1200x400) and `banner_small_url` (normal, 1.5:1,
--    recommended 600x400). They live in a dedicated public bucket, written
--    only by staff, mirroring the `page-assets` arrangement.

alter table public.payment_gateways
  add column if not exists country text,
  add column if not exists is_primary_for_country boolean not null default false,
  add column if not exists banner_url text,
  add column if not exists banner_small_url text;

-- Shape guard: either NULL (International) or a two-letter code. Lowercase
-- input is normalized in the upsert below rather than refused, so a form
-- slip cannot create a country that never matches.
alter table public.payment_gateways
  add constraint payment_gateways_country_iso
  check (country is null or country ~ '^[A-Z]{2}$');

-- One primary per country; International is its own group.
create unique index payment_gateways_one_primary_per_country
  on public.payment_gateways (coalesce(country, '__INTL__'))
  where is_primary_for_country;

-- ---------------------------------------------------------------------------
-- Banner bucket: public read, staff write, same rules as page-assets.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'gateway-assets',
  'gateway-assets',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy gateway_assets_public_read
  on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'gateway-assets');

create policy gateway_assets_staff_write
  on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'gateway-assets' and private.is_staff());

create policy gateway_assets_staff_update
  on storage.objects
  for update
  to authenticated
  using (bucket_id = 'gateway-assets' and private.is_staff());

create policy gateway_assets_staff_delete
  on storage.objects
  for delete
  to authenticated
  using (bucket_id = 'gateway-assets' and private.is_staff());

-- ---------------------------------------------------------------------------
-- Public read paths: banners are marketing images, so they are published with
-- the rest of the gateway card; country and primary flag drive the layout.
-- ---------------------------------------------------------------------------
drop view public.payment_gateways_public;

create view public.payment_gateways_public
as
select
  id,
  kind,
  provider,
  name_en,
  name_bn,
  sort_order,
  country,
  is_primary_for_country,
  banner_url,
  banner_small_url
from public.payment_gateways
where is_active;

grant select on public.payment_gateways_public to anon, authenticated;

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
  -- '' or 'INTL' means the International catch-all, stored as NULL; anything
  -- else is normalized to an upper-case ISO-3166 alpha-2 code.
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

  -- Checked here as well as by the trigger so the refusal names the field the operator was
  -- editing. The trigger still has to fire: `weight` is also writable by anything holding a
  -- direct connection, and this constraint is the boundary, not this function.
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

  v_country := case
    when upper(v_country) = 'INTL' or v_country is null then null
    else upper(v_country)
  end;

  perform private.validate_account_fields(v_account_fields);

  if v_id is null then
    insert into public.payment_gateways (
      kind, account_number, account_name, account_fields,
      name_en, name_bn,
      instructions_md_en, instructions_md_bn,
      reference_prompt_en, reference_prompt_bn, supports_reference,
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
      nullif(p_gateway ->> 'reference_prompt_en', ''),
      nullif(p_gateway ->> 'reference_prompt_bn', ''),
      coalesce((p_gateway ->> 'supports_reference')::boolean, false),
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
        reference_prompt_en = nullif(p_gateway ->> 'reference_prompt_en', ''),
        reference_prompt_bn = nullif(p_gateway ->> 'reference_prompt_bn', ''),
        supports_reference = coalesce((p_gateway ->> 'supports_reference')::boolean, false),
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

-- ---------------------------------------------------------------------------
-- Page images become first-class assets with named slots.
--
-- Until now a template's only image was a URL embedded in `template_config`,
-- uploaded to a flat path nobody owned. That made three things impossible:
-- an operator could not see which images a page still needed, a replaced
-- image left its old file orphaned in the bucket forever, and the AI could
-- not describe what a missing image should show without somewhere to put the
-- description.
--
-- `page_assets` fixes all three. One row per image slot per page - the slot
-- is a name the template registry declares (`hero`, `problem`,
-- `benefits` + index, ...) - carrying the storage path, the public URL, the
-- localized alt text, and the image brief: the sentence that says what
-- should be in the picture. A row with a null URL is an assigned brief
-- waiting for its upload, which is exactly what the AI fill produces.
--
-- Storage paths become structured (`{page_id}/{slot_key}/...`) so cleanup
-- can find a page's files, and the upload composable uses that shape.
-- ---------------------------------------------------------------------------

create table private.page_assets (
  id uuid primary key default gen_random_uuid(),
  page_id uuid not null references public.pages (id) on delete cascade,
  slot_key text not null,
  item_index integer not null default 0,
  storage_path text,
  public_url text,
  alt_en text,
  alt_bn text,
  brief_en text,
  brief_bn text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (page_id, slot_key, item_index)
);

comment on table private.page_assets is
  'One row per image slot per page. A row with a null public_url is a brief '
  'waiting for its upload. Slot keys are declared by the template registry in '
  'code; the database stores them without interpreting them.';

create trigger page_assets_touch
  before update on private.page_assets
  for each row execute function private.touch_updated_at();

revoke all on private.page_assets from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Reads and writes: staff can manage images (the storage bucket already
-- trusts staff), because uploading art for a page is lighter work than
-- writing its copy.
-- ---------------------------------------------------------------------------

create or replace function api.admin_page_assets(p_page_id uuid)
returns table (
  slot_key text,
  item_index integer,
  storage_path text,
  public_url text,
  alt_en text,
  alt_bn text,
  brief_en text,
  brief_bn text
)
language sql
stable
security definer
set search_path = ''
as $$
  select a.slot_key, a.item_index, a.storage_path, a.public_url,
         a.alt_en, a.alt_bn, a.brief_en, a.brief_bn
  from private.page_assets a
  where a.page_id = p_page_id
  order by a.slot_key, a.item_index
$$;

revoke all on function api.admin_page_assets(uuid) from public, anon, authenticated;
grant execute on function api.admin_page_assets(uuid) to authenticated;

create or replace function api.admin_upsert_page_asset(
  p_page_id uuid,
  p_slot_key text,
  p_item_index integer,
  p_storage_path text,
  p_public_url text,
  p_alt_en text,
  p_alt_bn text,
  p_brief_en text,
  p_brief_bn text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row private.page_assets;
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- The page must exist: an asset for a deleted page is an orphan by
  -- definition, and a typo in a page id would otherwise quietly create one.
  if not exists (select 1 from public.pages where id = p_page_id) then
    raise exception 'page not found' using errcode = 'P0002';
  end if;

  if btrim(coalesce(p_slot_key, '')) = '' then
    raise exception 'slot key is required' using errcode = '22023';
  end if;

  -- A slot is either fully assigned (url + path) or a brief-only placeholder.
  -- Anything between them - a URL with no path, or a path with no URL - would
  -- make replacement cleanup guess.
  if (p_public_url is null) <> (p_storage_path is null) then
    raise exception 'an assigned image needs both its url and its storage path'
      using errcode = '22023';
  end if;

  insert into private.page_assets (
    page_id, slot_key, item_index, storage_path, public_url,
    alt_en, alt_bn, brief_en, brief_bn
  )
  values (
    p_page_id, btrim(p_slot_key), coalesce(p_item_index, 0),
    nullif(btrim(coalesce(p_storage_path, '')), ''),
    nullif(btrim(coalesce(p_public_url, '')), ''),
    nullif(btrim(coalesce(p_alt_en, '')), ''),
    nullif(btrim(coalesce(p_alt_bn, '')), ''),
    nullif(btrim(coalesce(p_brief_en, '')), ''),
    nullif(btrim(coalesce(p_brief_bn, '')), '')
  )
  on conflict (page_id, slot_key, item_index) do update
  set storage_path = excluded.storage_path,
      public_url = excluded.public_url,
      alt_en = excluded.alt_en,
      alt_bn = excluded.alt_bn,
      brief_en = excluded.brief_en,
      brief_bn = excluded.brief_bn
  returning * into v_row;

  return jsonb_build_object(
    'ok', true,
    'slot_key', v_row.slot_key,
    'item_index', v_row.item_index,
    'storage_path', v_row.storage_path,
    'public_url', v_row.public_url
  );
end
$$;

revoke all on function api.admin_upsert_page_asset(uuid, text, integer, text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function api.admin_upsert_page_asset(uuid, text, integer, text, text, text, text, text, text)
  to authenticated;

-- Removing an asset returns the storage path so the caller can delete the
-- object from the bucket after the record is gone. The function owns no
-- storage, so the ordering matters: record first, file second.
create or replace function api.admin_remove_page_asset(
  p_page_id uuid,
  p_slot_key text,
  p_item_index integer
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_path text;
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from private.page_assets
  where page_id = p_page_id and slot_key = btrim(p_slot_key) and item_index = coalesce(p_item_index, 0)
  returning storage_path into v_path;

  return v_path;
end
$$;

revoke all on function api.admin_remove_page_asset(uuid, text, integer) from public, anon, authenticated;
grant execute on function api.admin_remove_page_asset(uuid, text, integer) to authenticated;

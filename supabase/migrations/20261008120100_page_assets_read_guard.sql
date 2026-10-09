-- The assets read is staff-only, like every admin read. The migration that
-- created it shipped with the grant but no guard, and since every customer's
-- anonymous signup carries the authenticated role, the grant alone would let
-- any buyer read a page's image briefs.
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
    and private.is_staff()
  order by a.slot_key, a.item_index
$$;

revoke all on function api.admin_page_assets(uuid) from public, anon, authenticated;
grant execute on function api.admin_page_assets(uuid) to authenticated;

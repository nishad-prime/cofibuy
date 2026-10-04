-- Index visibility.
--
-- A link can be published and yet kept off the index page, so a report can be
-- sold by direct link without appearing in the catalogue. The flag is `is_listed`,
-- deliberately distinct from `is_active`:
--
--   is_active   the link exists and can be bought
--   is_listed   the link appears in api.list_public_links()
--
-- Unlisted is NOT private. Anyone holding the slug can still reach the paywall and
-- buy it. This is a catalogue decision, not an access control, and the RLS policy
-- below is the only thing standing between "hidden from the index" and "hidden
-- from a direct query". Both are enforced, deliberately, in two places:
--
--   1. The RLS policy on `public.paywall_links` gains `and is_listed`. Without it
--      the flag is cosmetic: column-level SELECT grants let anon read the base
--      table directly, so `get /rest/v1/paywall_links?select=slug` would return
--      every unlisted link and the whole feature would be theatre.
--
--   2. `api.list_public_links()` filters explicitly. It is `security definer`, so
--      it reads with the function owner's rights and the policy above does not
--      apply to it - the owner bypasses RLS. Relying on the policy alone would
--      leave unlisted links in the catalogue.
--
-- What is NOT changed is `public.paywall_links_public`: no `is_listed` column and
-- no predicate. `api.get_public_link()` reads the *base table* with only
-- `is_active`, and `api.create_order()` does the same, so an unlisted link stays
-- buyable by direct slug. Filtering the view instead would have been the wrong
-- lever, and would also have changed `setof public.paywall_links_public`'s shape.

alter table public.paywall_links
  add column is_listed boolean not null default true;

-- Serves the index query. Partial on `is_active and is_listed` so it covers
-- exactly the rows `list_public_links` can return and stays small as drafts and
-- unlisted links accumulate. The existing `paywall_links_active_idx` keeps
-- serving the by-slug lookups that ignore listing.
create index paywall_links_listed_idx
  on public.paywall_links (sort_order, slug)
  where is_active and is_listed;

comment on column public.paywall_links.is_listed is
  'Whether the link appears in the public index. False keeps it buyable by direct '
  'slug but off the catalogue; it is not an access control.';

-- Drop and recreate: a policy predicate cannot be altered in place, and an
-- unlisted link must be invisible to a direct table read, not just to the RPC.
drop policy if exists paywall_links_public_read on public.paywall_links;

create policy paywall_links_public_read
  on public.paywall_links
  for select
  to anon, authenticated
  using (is_active and is_listed);

-- Explicit `is_listed`, because this function is `security definer` and therefore
-- reads with the *function owner's* rights. The tightened policy does not apply
-- here: the owner bypasses RLS, so a policy-only fix would leave unlisted links in
-- the catalogue.
--
-- It selects from the base table rather than `paywall_links_public`. The view has
-- no `is_listed` column, by design (see the note at the top of the file), and
-- adding one would mean granting the flag to `anon`, which is exactly the probe
-- surface the flag is meant to avoid. The explicit column list is copied from the
-- view and must stay in step with it, since the return type is the view's row type.
create or replace function api.list_public_links()
returns setof public.paywall_links_public
language sql
stable
security definer
set search_path = ''
as $$
  select
    id,
    slug,
    title_en,
    title_bn,
    teaser_md_en,
    teaser_md_bn,
    unlock_cta_label_en,
    unlock_cta_label_bn,
    unlock_cta_url,
    sort_order
  from public.paywall_links
  where is_active and is_listed
  order by sort_order, slug
$$;

-- `is_listed` appears in BOTH the insert column list and the `on conflict` set.
-- Adding it to only one half means the flag silently reverts on the next edit of
-- that link, which is the same trap `admin_upsert_gateway` documents: the upsert
-- only reaches its conflict branch when an id is present, so an edit that drops
-- the column writes the old value back over the new one.
create or replace function api.admin_upsert_link(p_link jsonb)
returns public.paywall_links
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.paywall_links;
  v_id uuid := nullif(p_link ->> 'id', '')::uuid;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  insert into public.paywall_links (
    id, slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
    unlock_body_md_en, unlock_body_md_bn,
    unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
    min_amount_override, hide_min_override, is_active, is_listed, sort_order
  )
  values (
    coalesce(v_id, gen_random_uuid()),
    p_link ->> 'slug',
    p_link ->> 'title_en',
    p_link ->> 'title_bn',
    p_link ->> 'teaser_md_en',
    p_link ->> 'teaser_md_bn',
    p_link ->> 'unlock_body_md_en',
    p_link ->> 'unlock_body_md_bn',
    p_link ->> 'unlock_cta_label_en',
    p_link ->> 'unlock_cta_label_bn',
    p_link ->> 'unlock_cta_url',
    nullif(p_link ->> 'min_amount_override', '')::numeric,
    nullif(p_link ->> 'hide_min_override', '')::boolean,
    coalesce((p_link ->> 'is_active')::boolean, false),
    coalesce((p_link ->> 'is_listed')::boolean, true),
    coalesce((p_link ->> 'sort_order')::integer, 0)
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
      sort_order = excluded.sort_order
  returning * into v_row;

  return v_row;
end
$$;
-- ---------------------------------------------------------------------------
-- Links become pages.
--
-- The storefront sells pages, not links: a page is a standalone landing surface
-- for one digital good, and the index is a configurable view over the pages
-- that are not hidden from it. The word "link" described the row when it was
-- little more than a slug and a URL to unlock; it no longer does.
--
-- This migration is a rename plus two new columns, not a rewrite:
--
--   1. `paywall_links` becomes `pages`. Indexes, constraints and triggers are
--      renamed to match so the catalog does not keep telling the old story.
--   2. Every function whose body named the old table is recreated. Functions
--      are re-bound to table OIDs when they are parsed, but a body that spells
--      the old name out would fail the first time plpgsql resolved it, so each
--      one is rewritten from its current catalog definition with the new names
--      substituted. The definitions dumped here are the live ones, not the
--      first draft from the earliest migration, so nothing later migrations
--      changed is silently reverted.
--   3. `template` and `template_config` are added. A template is a code-side
--      layout (see `src/pages/templates/registry.ts`); the database's job is
--      only to refuse a template the running app has never heard of, and to
--      require the config to be a JSON object. The per-template shape is the
--      app's contract, checked in `src/pages/templates/registry.ts`, where the
--      forms and renderers live.
--
-- The old function names are dropped outright: there is no production data to
-- carry across a deprecation window, and a second name for the same thing is
-- exactly the confusion this rename exists to end.
-- ---------------------------------------------------------------------------

-- The link-named functions go first: the view they read is dropped below, and
-- Postgres tracks that dependency, so dropping them before the view keeps the
-- whole migration cascade-free.
drop function api.get_public_link(text);
drop function api.public_link_payload(text);
drop function api.public_link_payload_v1(text);
drop function api.list_public_links();
drop function api.get_unlocked_link(text);
drop function api.admin_links();
drop function api.admin_upsert_link(jsonb);
drop function api.admin_delete_link(uuid);

alter table public.paywall_links rename to pages;

-- Cosmetics, so the catalog reads the new story everywhere.
alter index public.paywall_links_active_idx rename to pages_active_idx;
alter index public.paywall_links_listed_idx rename to pages_listed_idx;
alter table public.pages rename constraint paywall_links_slug_key to pages_slug_key;
alter table public.pages rename constraint paywall_links_slug_shape to pages_slug_shape;
alter table public.pages rename constraint paywall_links_publishable to pages_publishable;
alter trigger paywall_links_touch on public.pages rename to pages_touch;
alter trigger paywall_links_tidy on public.pages rename to pages_tidy;

-- A template the app cannot render is a page the customer cannot see. The
-- allowlist lives here so the refusal happens at the write, not at first paint.
create function private.guard_page_template() returns trigger
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

  return new;
end
$$;

create trigger pages_template_guard
  before insert or update on public.pages
  for each row execute function private.guard_page_template();

alter table public.pages
  add column template text not null default 'standard',
  add column template_config jsonb not null default '{}';

-- The public projection keeps the same columns it always had; only the name
-- and the source table change. The locked columns stay locked: a template's
-- config is public by design, but the paid body is still grant-only and the
-- price overrides are still resolved server side.
drop view public.paywall_links_public;
create view public.pages_public
  -- Security invoker, like the view it replaces: the projection adds nothing
  -- and must not quietly bypass the table's RLS for unlisted rows.
  with (security_invoker = on)
  as
  select id, slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
         unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
         template, template_config, sort_order
  from public.pages
  where is_active;
grant select on public.pages_public to anon, authenticated;

-- The security-invoker view resolves column rights against the base table, so
-- the two template columns the projection now carries need their own grants.
-- The config is what the renderer draws the page from: public by design, and
-- holding nothing the customer is not told anyway.
grant select (template, template_config) on public.pages to anon, authenticated;

-- effective_min: recreated from the renamed table
CREATE OR REPLACE FUNCTION private.effective_min(p_link pages, p_settings site_settings)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(p_link.min_amount_override, p_settings.min_amount)
$function$;
revoke all on function private.effective_min(p_link pages, p_settings site_settings) from public, anon, authenticated;
grant execute on function private.effective_min(p_link pages, p_settings site_settings) to PUBLIC;

-- effective_hide_min: recreated from the renamed table
CREATE OR REPLACE FUNCTION private.effective_hide_min(p_link pages, p_settings site_settings)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(p_link.hide_min_override, p_settings.hide_min_amount)
$function$;
revoke all on function private.effective_hide_min(p_link pages, p_settings site_settings) from public, anon, authenticated;
grant execute on function private.effective_hide_min(p_link pages, p_settings site_settings) to PUBLIC;

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

-- public_page_payload: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.public_page_payload(p_slug text)
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
          'sort_order', g.sort_order
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

-- get_public_page: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.get_public_page(p_slug text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
    when payload.base is null then null
    else payload.base || jsonb_build_object(
      -- Reported rather than raised. The link is still worth showing: a customer
      -- should be able to read what they would have bought and why they cannot pay
      -- for it right now, which is a better answer than an error page.
      'maintenance_mode', (select s.maintenance_mode from public.site_settings s where s.id = 1)
    )
  end
  from (select api.public_page_payload(p_slug) as base) payload
$function$;
revoke all on function api.get_public_page(p_slug text) from public, anon, authenticated;
grant execute on function api.get_public_page(p_slug text) to anon;
grant execute on function api.get_public_page(p_slug text) to authenticated;

-- get_unlocked_page: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.get_unlocked_page(p_slug text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'slug', l.slug,
    'title_en', l.title_en,
    'title_bn', l.title_bn,
    'unlock_body_md_en', l.unlock_body_md_en,
    'unlock_body_md_bn', l.unlock_body_md_bn,
    'unlock_cta_label_en', l.unlock_cta_label_en,
    'unlock_cta_label_bn', l.unlock_cta_label_bn,
    'unlock_cta_url', l.unlock_cta_url
  )
  from public.pages l
  where l.slug = p_slug
    and exists (
      select 1
      from public.access_grants g
      where g.user_id = auth.uid() and g.link_id = l.id and g.revoked_at is null
    )
$function$;
revoke all on function api.get_unlocked_page(p_slug text) from public, anon, authenticated;
grant execute on function api.get_unlocked_page(p_slug text) to authenticated;

-- list_public_pages: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.list_public_pages()
 RETURNS SETOF pages_public
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    template,
    template_config,
    sort_order
  from public.pages
  where is_active and is_listed
  order by sort_order, slug
$function$;
revoke all on function api.list_public_pages() from public, anon, authenticated;
grant execute on function api.list_public_pages() to anon;
grant execute on function api.list_public_pages() to authenticated;

-- admin_pages: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.admin_pages()
 RETURNS SETOF pages
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query select * from public.pages order by sort_order, slug;
end
$function$;
revoke all on function api.admin_pages() from public, anon, authenticated;
grant execute on function api.admin_pages() to authenticated;

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
    template, template_config
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
    coalesce(p_page -> 'template_config', '{}'::jsonb)
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
      template_config = excluded.template_config
  returning * into v_row;

  return v_row;
end
$function$;
revoke all on function api.admin_upsert_page(p_link jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_page(p_link jsonb) to authenticated;

-- admin_delete_page: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.admin_delete_page(p_link_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from public.pages where id = p_link_id;
  if not found then
    raise exception 'link not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end
$function$;
revoke all on function api.admin_delete_page(p_link_id uuid) from public, anon, authenticated;
grant execute on function api.admin_delete_page(p_link_id uuid) to authenticated;

-- create_order_unchecked: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.create_order_unchecked(p_slug text, p_gateway_id uuid, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := auth.uid();
  v_link public.pages;
  v_settings public.site_settings;
  v_gateway public.payment_gateways;
  v_min numeric;
  v_hide boolean;
  v_open public.orders;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_link from public.pages where slug = p_slug and is_active;
  if not found then
    raise exception 'link not found' using errcode = 'P0002';
  end if;

  select * into v_gateway from public.payment_gateways where id = p_gateway_id and is_active;
  if not found then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  select * into v_settings from public.site_settings where id = 1;
  v_min := private.effective_min(v_link, v_settings);
  v_hide := private.effective_hide_min(v_link, v_settings);

  -- Reuse the customer's open order rather than creating a second one. This is
  -- a courtesy, not the safety net: the partial unique index is what actually
  -- prevents duplicates.
  --
  -- `locked` is included so a probe lock is found here. Excluding it would let
  -- the customer walk straight past the lock by asking again, because the
  -- follow-on code would fall through and insert a fresh draft.
  select * into v_open
  from public.orders
  where user_id = v_user
    and link_id = v_link.id
    and status in ('draft', 'awaiting_proof', 'rejected', 'locked')
  for update;

  -- `v_open.id`, never `v_open is not null`. A row variable is null only when
  -- *every* column is null, so testing the whole row against null quietly skips
  -- the reuse path for any order that has a sparse column (which every draft
  -- does) and falls through to the insert below, tripping the open-order index.
  if v_open.id is not null then
    -- Locked means no amount is accepted and no new order starts, so the probe
    -- budget cannot be reset by asking again. A distinct code lets the client
    -- say so instead of showing the same "too low" message forever.
    if v_open.status = 'locked' then
      return jsonb_build_object(
        'ok', false,
        'code', 'locked',
        'locked_at', v_open.locked_at
      );
    end if;

    -- Reaching an existing draft means another attempt came in. Count it whether
    -- or not the amount is acceptable, so the lock cannot be side-stepped by
    -- alternating valid and invalid amounts.
    if p_amount is null or p_amount < v_min then
      update public.orders
      set probe_count = probe_count + 1,
          locked_at = case when probe_count + 1 >= 6 then now() else locked_at end,
          status = case when probe_count + 1 >= 6 then 'locked'::public.order_status else status end
      where id = v_open.id;

      return jsonb_build_object('ok', false, 'code', 'below_minimum');
    end if;

    return jsonb_build_object(
      'ok', true,
      'order_id', v_open.id,
      'reference_code', v_open.reference_code,
      'status', v_open.status,
      'expires_at', v_open.expires_at,
      'min_amount', case when v_hide then null else v_min end,
      'min_hidden', v_hide
    );
  end if;

  if p_amount is null or p_amount < v_min then
    -- A row is created even for a rejected amount because the probe counter has
    -- to live somewhere. It is a draft: it is never listed, never reviewed, and
    -- expires on its own.
    insert into public.orders (
      user_id, link_id, gateway_id, status, reference_code, amount,
      min_amount_snapshot, hide_min_snapshot, probe_count, expires_at
    )
    values (
      v_user, v_link.id, v_gateway.id, 'draft', private.gen_reference_code(),
      greatest(coalesce(p_amount, 0), 0.01),
      v_min, v_hide, 1, now() + interval '30 minutes'
    )
    returning * into v_open;

    return jsonb_build_object('ok', false, 'code', 'below_minimum');
  end if;

  insert into public.orders (
    user_id, link_id, gateway_id, status, reference_code, amount,
    min_amount_snapshot, hide_min_snapshot, expires_at
  )
  values (
    v_user, v_link.id, v_gateway.id, 'awaiting_proof',
    private.gen_reference_code(), p_amount,
    v_min, v_hide, now() + interval '30 minutes'
  )
  returning * into v_open;

  return jsonb_build_object(
    'ok', true,
    'order_id', v_open.id,
    'reference_code', v_open.reference_code,
    'status', v_open.status,
    'expires_at', v_open.expires_at,
    'min_amount', case when v_hide then null else v_min end,
    'min_hidden', v_hide
  );
exception
  when unique_violation then
    -- Two different things collide here, and they need different answers.
    --
    -- The one-open-order index fires when the customer double-taps, or opens the
    -- link in a second tab. That is not an error at all: the order the caller
    -- wanted already exists, so hand it back. Only a genuine reference-code
    -- collision — roughly once in 29^8 orders — is worth asking for a retry, and
    -- a retry is the wrong advice for the first case because it will fail
    -- identically every time.
    select o.* into v_open
    from public.orders o
    where o.user_id = v_user
      and o.link_id = v_link.id
      and o.status in ('draft', 'awaiting_proof', 'under_review', 'rejected', 'locked')
    order by o.created_at desc
    limit 1;

    if v_open.id is null then
      raise exception 'could not allocate a reference code, please retry' using errcode = '40001';
    end if;

    if v_open.status = 'locked' then
      return jsonb_build_object('ok', false, 'code', 'locked', 'locked_at', v_open.locked_at);
    end if;

    if v_open.status = 'draft' then
      update public.orders
      set probe_count = probe_count + 1,
          locked_at = case when probe_count + 1 >= 6 then now() else locked_at end,
          status = case when probe_count + 1 >= 6 then 'locked'::public.order_status else status end
      where id = v_open.id;

      return jsonb_build_object('ok', false, 'code', 'below_minimum');
    end if;

    return jsonb_build_object(
      'ok', true,
      'order_id', v_open.id,
      'reference_code', v_open.reference_code,
      'status', v_open.status,
      'expires_at', v_open.expires_at,
      'min_amount', case when v_hide then null else v_min end,
      'min_hidden', v_hide
    );
end
$function$;
revoke all on function api.create_order_unchecked(p_slug text, p_gateway_id uuid, p_amount numeric) from public, anon, authenticated;

-- create_order_resolved: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.create_order_resolved(p_slug text, p_kind text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := auth.uid();
  v_link public.pages;
  v_gateway public.payment_gateways;
  v_open_kind text;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- Read, never written, from here down. `create_order_unchecked` re-reads the link and
  -- locks the open order itself; this pass exists only to compare kinds, and doing that
  -- read without touching probe_count is the whole point of raising before delegating.
  select l.id into v_link
  from public.pages l
  where l.slug = p_slug and l.is_active;

  if v_link.id is null then
    raise exception 'link not found' using errcode = 'P0002';
  end if;

  -- After the link, not before it. A customer who sent a slug that is not for sale is told
  -- the link is gone whether or not they had chosen a method; moving this above that check
  -- would answer a different question than the one they asked.
  if nullif(btrim(p_kind), '') is null then
    raise exception 'a payment method kind is required' using errcode = '22023';
  end if;

  select * into v_gateway from private.pick_gateway_for_kind(p_kind);

  if v_gateway.id is null then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  -- The customer's open order is pinned to one gateway, and the pin has to survive them
  -- changing their mind about the kind - otherwise an order awaiting proof on a bank
  -- transfer could be confirmed against a different account than the one the screenshot
  -- shows. Refused rather than re-pointed: re-pointing would leave the customer holding a
  -- transfer receipt for an account nobody is watching.
  --
  -- Raised rather than returned as a code because the client has to change state, not show
  -- a message: it cannot make the mismatch go away by retrying, and an `ok: false` envelope
  -- carrying no order id is easy for a client to read as "try again" and loop on.
  select g.kind into v_open_kind
  from public.orders o
  join public.payment_gateways g on g.id = o.gateway_id
  where o.user_id = v_user
    and o.link_id = v_link.id
    and o.status in ('draft', 'awaiting_proof', 'rejected', 'locked')
  limit 1;

  if v_open_kind is not null and v_open_kind <> v_gateway.kind then
    -- `kind_mismatch` is the stable part. The sentence after it can be reworded or
    -- translated without breaking a client that needs to know this is not retryable.
    raise exception 'kind_mismatch: open order already uses payment kind %', v_open_kind
      using errcode = '22023';
  end if;

  return api.create_order_unchecked(p_slug, v_gateway.id, p_amount);
end;
$function$;
revoke all on function api.create_order_resolved(p_slug text, p_kind text, p_amount numeric) from public, anon, authenticated;

-- my_orders: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.my_orders()
 RETURNS TABLE(id uuid, slug text, title_en text, title_bn text, gateway_kind text, status order_status, reference_code text, amount numeric, min_amount numeric, min_hidden boolean, created_at timestamp with time zone, expires_at timestamp with time zone, submitted_at timestamp with time zone, attempt_count integer, reject_reason_en text, reject_reason_bn text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select
    o.id,
    l.slug,
    l.title_en,
    l.title_bn,
    g.kind,
    o.status,
    o.reference_code,
    o.amount,
    case when o.hide_min_snapshot then null else o.min_amount_snapshot end,
    o.hide_min_snapshot,
    o.created_at,
    o.expires_at,
    o.submitted_at,
    o.attempt_count,
    o.reject_reason_en,
    o.reject_reason_bn
  from public.orders o
  join public.pages l on l.id = o.link_id
  join public.payment_gateways g on g.id = o.gateway_id
  where o.user_id = auth.uid()
  order by o.created_at desc
$function$;
revoke all on function api.my_orders() from public, anon, authenticated;
grant execute on function api.my_orders() to authenticated;

-- my_grants: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.my_grants()
 RETURNS TABLE(slug text, title_en text, title_bn text, granted_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select l.slug, l.title_en, l.title_bn, g.granted_at
  from public.access_grants g
  join public.pages l on l.id = g.link_id
  where g.user_id = auth.uid() and g.revoked_at is null
  order by g.granted_at desc
$function$;
revoke all on function api.my_grants() from public, anon, authenticated;
grant execute on function api.my_grants() to authenticated;

-- admin_orders: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.admin_orders(p_status text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_limit integer DEFAULT 100)
 RETURNS TABLE(id uuid, slug text, title_en text, title_bn text, kind text, status order_status, reference_code text, amount numeric, phone_e164 text, attempt_count integer, probe_count integer, created_at timestamp with time zone, submitted_at timestamp with time zone, has_duplicate_trxid boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select
    o.id,
    l.slug,
    l.title_en,
    l.title_bn,
    g.kind,
    o.status,
    o.reference_code,
    o.amount,
    o.phone_e164,
    o.attempt_count,
    o.probe_count,
    o.created_at,
    o.submitted_at,
    exists (
      select 1
      from public.order_evidence e
      join public.order_evidence dup
        on dup.field_key = e.field_key
       and dup.value_text_norm is not null
       and dup.value_text_norm = e.value_text_norm
       and dup.order_id <> o.id
      where e.order_id = o.id and e.value_text_norm is not null
    )
  from public.orders o
  join public.pages l on l.id = o.link_id
  join public.payment_gateways g on g.id = o.gateway_id
  where (p_status is null or o.status::text = p_status)
    and (
      p_reference is null
      or o.reference_code = private.normalize_reference(p_reference)
    )
  order by o.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$function$;
revoke all on function api.admin_orders(p_status text, p_reference text, p_limit integer) from public, anon, authenticated;
grant execute on function api.admin_orders(p_status text, p_reference text, p_limit integer) to authenticated;

-- admin_order_detail: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.admin_order_detail(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_order public.orders;
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'id', v_order.id,
    'status', v_order.status,
    'reference_code', v_order.reference_code,
    'amount', v_order.amount,
    -- Staff see the real minimum: it is the staff-only threshold, and the
    -- hide_min flag governs what customers are told, not what the operator knows.
    'min_amount', v_order.min_amount_snapshot,
    'min_hidden', v_order.hide_min_snapshot,
    'phone_e164', v_order.phone_e164,
    'phone_raw', v_order.phone_raw,
    'attempt_count', v_order.attempt_count,
    'probe_count', v_order.probe_count,
    'created_at', v_order.created_at,
    'expires_at', v_order.expires_at,
    'submitted_at', v_order.submitted_at,
    'reviewed_at', v_order.reviewed_at,
    'reject_reason_en', v_order.reject_reason_en,
    'reject_reason_bn', v_order.reject_reason_bn,
    'link', jsonb_build_object(
      'id', l.id, 'slug', l.slug, 'title_en', l.title_en, 'title_bn', l.title_bn
    ),
    'gateway', jsonb_build_object(
      'id', g.id, 'kind', g.kind, 'name_en', g.name_en, 'name_bn', g.name_bn,
      'account_number', g.account_number, 'account_name', g.account_name,
      'evidence_fields', g.evidence_fields
    ),
    'evidence', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', e.id,
            'field_key', e.field_key,
            'value_text_raw', e.value_text_raw,
            'value_text_norm', e.value_text_norm,
            'file_path', e.file_path,
            'attempt', e.attempt,
            'created_at', e.created_at
          )
          order by e.attempt desc, e.field_key
        )
        from public.order_evidence e
        where e.order_id = v_order.id
      ),
      '[]'::jsonb
    ),
    'duplicates', coalesce(
      (
        select jsonb_agg(to_jsonb(d))
        from api.admin_order_duplicate_trxids(v_order.id) d
      ),
      '[]'::jsonb
    )
  )
  from public.pages l, public.payment_gateways g
  where l.id = v_order.link_id and g.id = v_order.gateway_id;
end
$function$;
revoke all on function api.admin_order_detail(p_order_id uuid) from public, anon, authenticated;
grant execute on function api.admin_order_detail(p_order_id uuid) to authenticated;

-- admin_stats: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.admin_stats()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'awaiting_review', (select count(*) from public.orders where status = 'under_review'),
    'awaiting_proof', (select count(*) from public.orders where status = 'awaiting_proof'),
    'rejected', (select count(*) from public.orders where status = 'rejected'),
    'approved_total', (select count(*) from public.orders where status = 'approved'),
    'locked', (select count(*) from public.orders where status = 'locked'),
    'revenue', (select coalesce(sum(amount), 0) from public.orders where status = 'approved'),
    'active_links', (select count(*) from public.pages where is_active),
    'active_gateways', (select count(*) from public.payment_gateways where is_active)
  );
end
$function$;
revoke all on function api.admin_stats() from public, anon, authenticated;
grant execute on function api.admin_stats() to authenticated;

-- bkash_payment_lookup: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.bkash_payment_lookup(p_payment_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := auth.uid();
  v_session public.payment_sessions;
  v_order public.orders;
  v_link public.pages;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if btrim(coalesce(p_payment_id, '')) = '' then
    raise exception 'no payment id' using errcode = '22023';
  end if;

  select s.* into v_session
  from public.payment_sessions s
  join public.orders o on o.id = s.order_id
  where s.provider = 'bkash_pgw'
    and s.provider_payment_id = p_payment_id
    and o.user_id = v_user;

  if v_session.id is null then
    raise exception 'no payment session for %', p_payment_id using errcode = 'P0002';
  end if;

  select * into v_order from public.orders where id = v_session.order_id;
  select * into v_link from public.pages where id = v_order.link_id;

  return jsonb_build_object(
    'ok', true,
    'order_id', v_order.id,
    -- The customer route is keyed by slug as well as order id, so the return page needs
    -- both to send anybody anywhere.
    'slug', v_link.slug,
    'status', v_order.status,
    -- Reported rather than assumed: the customer may have closed the tab and come back a
    -- day later, and re-running execute on a settled payment is the one mistake this
    -- flow cannot make twice.
    'already_settled', v_session.status = 'completed'
  );
end
$function$;
revoke all on function api.bkash_payment_lookup(p_payment_id text) from public, anon, authenticated;
grant execute on function api.bkash_payment_lookup(p_payment_id text) to authenticated;

-- recover_access: recreated from the renamed table
CREATE OR REPLACE FUNCTION api.recover_access(p_phone text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := auth.uid();
  v_phone text;
  v_challenge public.otp_challenges;
  v_challenge_id uuid;
  v_enabled boolean;
  v_granted jsonb;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select recovery_enabled into v_enabled from public.site_settings where id = 1;
  if not coalesce(v_enabled, false) then
    raise exception 'account recovery is not available' using errcode = '22023';
  end if;

  v_phone := private.normalize_bd_phone(p_phone);
  if v_phone is null then
    raise exception 'that is not a valid Bangladeshi mobile number' using errcode = '22023';
  end if;

  -- A wrong code returns rather than raises, and that is load-bearing.
  --
  -- Raising unwinds the function and rolls back everything it did on the way
  -- out, including the attempt it just counted. A counter that only survives
  -- when it is not updated is not a counter: the five-guess limit below would
  -- never be reached, and a code that leaked would be good for unlimited
  -- guesses against it.
  --
  -- The two failures are also the same object, so a caller cannot use the
  -- response to learn whether a code existed, was already used, or had expired.
  --
  -- This first read deliberately takes no lock. It only decides which request
  -- owns the live challenge, so the locks below can be taken in one fixed order.
  select * into v_challenge
  from public.otp_challenges
  where phone_e164 = v_phone and consumed_at is null and expires_at > now()
  order by created_at desc
  limit 1;

  if v_challenge is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_code');
  end if;

  v_challenge_id := v_challenge.id;

  -- Locks are taken request-then-challenge, the same order api.record_otp_sent
  -- uses. Both functions write to both tables, so taking the same two locks in
  -- opposite orders is a deadlock waiting for a worker to send a code at the
  -- moment a customer guesses one.
  perform 1
  from public.recovery_requests
  where id = v_challenge.recovery_request_id
  for update;

  -- Locking the challenge is what makes the five-guess limit a limit. Without
  -- it, parallel requests all read the same attempt_count, all count themselves
  -- as the first guess, and none of them trips the threshold below — so a
  -- leaked code could be tried as many times as an attacker could send in
  -- parallel. Holding the row for the rest of the transaction also makes
  -- `attempt_count + 1` below an accurate count rather than a stale one.
  --
  -- The row is re-checked after the lock because the peek above was unlocked: a
  -- concurrent resend may have consumed or replaced the challenge in between.
  -- Superseded is reported as an ordinary invalid code, like every other miss.
  select * into v_challenge
  from public.otp_challenges
  where id = v_challenge_id
    and consumed_at is null
    and expires_at > now()
  for update;

  if v_challenge is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_code');
  end if;

  if not private.otp_matches(p_code, v_challenge.otp_hash) then
    update public.otp_challenges
    set attempt_count = attempt_count + 1
    where id = v_challenge.id;

    if v_challenge.attempt_count + 1 >= v_challenge.max_attempts then
      update public.otp_challenges set consumed_at = now() where id = v_challenge.id;
      update public.recovery_requests
      set status = 'failed'
      where id = v_challenge.recovery_request_id and status = 'sent';
    end if;

    return jsonb_build_object('ok', false, 'code', 'invalid_code');
  end if;

  update public.otp_challenges set consumed_at = now() where id = v_challenge.id;
  update public.recovery_requests
  set status = 'verified', verified_at = now()
  where id = v_challenge.recovery_request_id;

  -- Everything ever paid for with this phone, granted to whoever just proved
  -- control of it. Idempotent, so re-verifying a second code is harmless.
  --
  -- Postgres has no min() for uuid, so the order credited is the earliest one
  -- for the link, picked out of an ordered array.
  insert into public.access_grants (user_id, link_id, via_order_id)
  select
    v_user,
    o.link_id,
    (array_agg(o.id order by o.created_at))[1]
  from public.orders o
  where o.phone_e164 = v_phone and o.status = 'approved'
  group by o.link_id
  on conflict (user_id, link_id) do nothing;

  insert into public.customer_contacts (user_id, phone_e164)
  values (v_user, v_phone)
  on conflict (user_id, phone_e164) do nothing;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('slug', l.slug, 'title_en', l.title_en, 'title_bn', l.title_bn)
      order by l.slug
    ),
    '[]'::jsonb
  )
  into v_granted
  from public.access_grants g
  join public.pages l on l.id = g.link_id
  where g.user_id = v_user and g.revoked_at is null;

  return jsonb_build_object('ok', true, 'links', v_granted);
end
$function$;
revoke all on function api.recover_access(p_phone text, p_code text) from public, anon, authenticated;
grant execute on function api.recover_access(p_phone text, p_code text) to authenticated;

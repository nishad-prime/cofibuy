-- Anonymous visit tracking for the admin dashboard.
--
-- One row per page view, written by the storefront itself through a narrow
-- anon RPC. The table deliberately carries no raw IP: the visitor's country
-- is what the storefront Worker already resolved from Cloudflare's edge geo
-- (which is IP-derived), and bots never reach the beacon because the zone's
-- WAF challenge stops them before the app loads. Retention is 180 days, cut
-- daily by cron.

create table public.page_views (
  id bigint generated always as identity primary key,
  page_id uuid not null references public.pages (id) on delete cascade,
  country text,
  device_type text not null default 'desktop',
  os text,
  browser text,
  referrer text,
  created_at timestamptz not null default now()
);

comment on table public.page_views is
  'Anonymous storefront visits. One row per tracked page load; country comes from the edge geo, device fields from the user agent. No IP is stored.';

create index page_views_page_time_idx on public.page_views (page_id, created_at desc);
create index page_views_time_idx on public.page_views (created_at desc);
create index page_views_country_idx on public.page_views (country) where country is not null;

-- No direct access at all: the table is written only by the security-definer
-- tracker and read only by staff analytics RPCs.
revoke all on public.page_views from public, anon, authenticated;

create or replace function api.track_page_view(
  p_slug text,
  p_country text,
  p_device_type text,
  p_os text,
  p_browser text,
  p_referrer text
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_page public.pages;
  v_country text;
  v_device text;
  v_os text;
  v_browser text;
  v_referrer text;
begin
  -- Only live pages are tracked; unknown or inactive slugs answer ok:true so
  -- the beacon has nothing to distinguish and nothing to retry on.
  select * into v_page
  from public.pages
  where slug = p_slug and is_active
  limit 1;

  if v_page.id is null then
    return jsonb_build_object('ok', true, 'tracked', false);
  end if;

  -- Country: uppercase two-letter code or nothing. Anything else is noise.
  v_country := nullif(btrim(p_country), '');
  if v_country !~ '^[A-Z]{2}$' then
    v_country := null;
  end if;

  -- Device: one of three buckets; the client's word is not trusted further.
  v_device := nullif(btrim(p_device_type), '');
  if v_device not in ('mobile', 'desktop', 'tablet') then
    v_device := 'desktop';
  end if;

  v_os := left(nullif(btrim(p_os), ''), 40);
  v_browser := left(nullif(btrim(p_browser), ''), 40);
  v_referrer := left(nullif(btrim(p_referrer), ''), 200);

  insert into public.page_views
    (page_id, country, device_type, os, browser, referrer)
  values
    (v_page.id, v_country, v_device, v_os, v_browser, v_referrer);

  return jsonb_build_object('ok', true, 'tracked', true);
end
$function$;

revoke all on function api.track_page_view(text, text, text, text, text, text)
  from public, authenticated;
grant execute on function api.track_page_view(text, text, text, text, text, text)
  to anon, authenticated;

-- Retention: 180 days of raw views is plenty for trend lines; older rows go
-- daily, right after the anonymous-account prune.
create or replace function private.prune_page_views()
 returns void
 language plpgsql
 set search_path to ''
as $function$
begin
  delete from public.page_views where created_at < now() - interval '180 days';
end
$function$;

revoke all on function private.prune_page_views() from public, anon, authenticated;

do $$
declare
  v_schema text;
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; prune_page_views installed but unscheduled.';
    return;
  end if;

  select n.nspname
  into v_schema
  from pg_depend d
  join pg_extension e on e.oid = d.refobjid
  join pg_proc p on p.oid = d.objid
  join pg_namespace n on n.oid = p.pronamespace
  where e.extname = 'pg_cron' and p.proname = 'schedule'
  limit 1;

  if v_schema is null then
    raise notice 'pg_cron is not installed; skipping the page-view prune schedule.';
    return;
  end if;

  execute format(
    'select %I.schedule(%L, %L, %L)',
    v_schema,
    'cofibuy-prune-page-views',
    '23 4 * * *',
    'select private.prune_page_views()'
  );

  raise notice 'page-view prune schedule installed.';
end
$$;

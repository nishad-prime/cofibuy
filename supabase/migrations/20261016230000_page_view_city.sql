-- City joins the visit record: the storefront Worker injects Cloudflare's
-- city alongside the country, and the analytics group by both.

alter table public.page_views add column if not exists city text;

create or replace function api.track_page_view(
  p_slug text,
  p_country text,
  p_city text,
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
  v_city text;
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

  v_city := left(nullif(btrim(p_city), ''), 80);

  -- Device: one of three buckets; the client's word is not trusted further.
  v_device := nullif(btrim(p_device_type), '');
  if v_device not in ('mobile', 'desktop', 'tablet') then
    v_device := 'desktop';
  end if;

  v_os := left(nullif(btrim(p_os), ''), 40);
  v_browser := left(nullif(btrim(p_browser), ''), 40);
  v_referrer := left(nullif(btrim(p_referrer), ''), 200);

  insert into public.page_views
    (page_id, country, city, device_type, os, browser, referrer)
  values
    (v_page.id, v_country, v_city, v_device, v_os, v_browser, v_referrer);

  return jsonb_build_object('ok', true, 'tracked', true);
end
$function$;

drop function if exists api.track_page_view(text, text, text, text, text, text);
revoke all on function api.track_page_view(text, text, text, text, text, text, text)
  from public, authenticated;
grant execute on function api.track_page_view(text, text, text, text, text, text, text)
  to anon, authenticated;

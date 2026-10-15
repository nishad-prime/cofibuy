-- The analytics the dashboard draws from: visit-aware traffic stats and a
-- views column on the daily trend.
--
-- Everything here is computed from data the shop already stores - orders,
-- page_views, gateways - with the staff guard every admin RPC carries: the
-- anonymous signup carries the authenticated role, so the grant alone would
-- hand every buyer the shop's numbers.

-- The daily trend gains a views column. The return type changes, so the old
-- signature is dropped first; the dashboard is updated in the same release.
drop function if exists api.admin_analytics(integer);

create or replace function api.admin_analytics(p_days integer default 30)
 returns table(day date, views bigint, orders_created bigint, orders_approved bigint, revenue_approved numeric)
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- The window is generated first and left-joined, so a day with no traffic is
  -- a zero row, not a missing one: a chart that silently skips quiet days
  -- draws a line through time that does not exist. The WITH lives in a subquery
  -- because plpgsql's RETURN QUERY parser is happier with a plain SELECT.
  return query
  select
    t.day,
    t.views,
    t.orders_created,
    t.orders_approved,
    t.revenue_approved
  from (
  with calendar as (
    select generate_series(
      (now() - make_interval(days => greatest(p_days, 1) - 1))::date,
      now()::date,
      interval '1 day'
    )::date as day
  ),
  views as (
    select created_at::date as day, count(*) as n
    from public.page_views
    where created_at >= (now() - make_interval(days => greatest(p_days, 1) - 1))::date
    group by 1
  ),
  created as (
    select created_at::date as day, count(*) as n
    from public.orders
    where created_at >= (now() - make_interval(days => greatest(p_days, 1) - 1))::date
    group by 1
  ),
  approved as (
    select reviewed_at::date as day, count(*) as n, coalesce(sum(amount), 0) as revenue
    from public.orders
    where status = 'approved'
      and reviewed_at >= (now() - make_interval(days => greatest(p_days, 1) - 1))::date
    group by 1
  )
  select
    c.day,
    coalesce(v.n, 0) as views,
    coalesce(cr.n, 0) as orders_created,
    coalesce(ap.n, 0) as orders_approved,
    coalesce(ap.revenue, 0) as revenue_approved
  from calendar c
  left join views v on v.day = c.day
  left join created cr on cr.day = c.day
  left join approved ap on ap.day = c.day
  order by c.day
  ) t;
end
$function$;

revoke all on function api.admin_analytics(integer) from public, anon, authenticated;
grant execute on function api.admin_analytics(integer) to authenticated;

create or replace function api.admin_traffic_stats(p_days integer default 30)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_start date;
  v_views bigint;
  v_created bigint;
  v_submitted bigint;
  v_approved bigint;
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_start := (now() - make_interval(days => greatest(p_days, 1) - 1))::date;

  select count(*) into v_views from public.page_views where created_at >= v_start;
  select count(*) into v_created from public.orders where created_at >= v_start;
  select count(*) into v_submitted
  from public.orders where submitted_at >= v_start;
  select count(*) into v_approved
  from public.orders
  where status = 'approved' and reviewed_at >= v_start;

  return jsonb_build_object(
    'days', greatest(p_days, 1),
    'funnel', jsonb_build_object(
      'views', v_views,
      'orders_created', v_created,
      'orders_submitted', v_submitted,
      'orders_approved', v_approved,
      'conversion_rate', case
        when v_views > 0 then round(v_approved::numeric * 100 / v_views, 2)
        else null
      end
    ),
    'countries', coalesce((
      select jsonb_agg(jsonb_build_object('country', t.country, 'views', t.n) order by t.n desc)
      from (
        select country, count(*) as n
        from public.page_views
        where created_at >= v_start and country is not null
        group by country
        order by n desc
        limit 10
      ) t
    ), '[]'::jsonb),
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object('device_type', t.device_type, 'views', t.n) order by t.n desc)
      from (
        select device_type, count(*) as n
        from public.page_views
        where created_at >= v_start
        group by device_type
        order by n desc
      ) t
    ), '[]'::jsonb),
    'referrers', coalesce((
      select jsonb_agg(jsonb_build_object('referrer', t.referrer, 'views', t.n) order by t.n desc)
      from (
        select referrer, count(*) as n
        from public.page_views
        where created_at >= v_start and referrer is not null
        group by referrer
        order by n desc
        limit 10
      ) t
    ), '[]'::jsonb),
    'gateways', coalesce((
      select jsonb_agg(
        jsonb_build_object('kind', t.kind, 'orders', t.n, 'revenue', t.revenue) order by t.revenue desc
      )
      from (
        select g.kind, count(*) as n, coalesce(sum(o.amount), 0) as revenue
        from public.orders o
        join public.payment_gateways g on g.id = o.gateway_id
        where o.status = 'approved' and o.reviewed_at >= v_start
        group by g.kind
      ) t
    ), '[]'::jsonb),
    'turnaround', jsonb_build_object(
      'avg_minutes', (
        select round(avg(extract(epoch from reviewed_at - submitted_at) / 60)::numeric, 1)
        from public.orders
        where status = 'approved' and reviewed_at >= v_start and submitted_at is not null
      ),
      'median_minutes', (
        select round(
          percentile_cont(0.5) within group (
            order by extract(epoch from reviewed_at - submitted_at) / 60
          )::numeric, 1)
        from public.orders
        where status = 'approved' and reviewed_at >= v_start and submitted_at is not null
      )
    ),
    'rejections', coalesce((
      select jsonb_agg(jsonb_build_object('reason', t.reason, 'orders', t.n) order by t.n desc)
      from (
        select coalesce(nullif(btrim(reject_reason_en), ''), reject_code, 'other') as reason,
               count(*) as n
        from public.orders
        where status = 'rejected' and reviewed_at >= v_start
        group by 1
        order by n desc
        limit 5
      ) t
    ), '[]'::jsonb),
    'pages', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug', t.slug,
          'title_en', t.title_en,
          'title_bn', t.title_bn,
          'views', t.views,
          'orders_created', t.orders_created,
          'orders_approved', t.orders_approved,
          'revenue', t.revenue,
          'conversion_rate', case
            when t.views > 0 then round(t.orders_approved::numeric * 100 / t.views, 2)
            else null
          end
        ) order by t.revenue desc
      )
      from (
        select
          l.slug,
          l.title_en,
          l.title_bn,
          coalesce(v.n, 0) as views,
          coalesce(cr.n, 0) as orders_created,
          coalesce(ap.n, 0) as orders_approved,
          coalesce(ap.revenue, 0) as revenue
        from public.pages l
        left join (
          select page_id, count(*) as n
          from public.page_views
          where created_at >= v_start
          group by 1
        ) v on v.page_id = l.id
        left join (
          select link_id, count(*) as n
          from public.orders
          where created_at >= v_start
          group by 1
        ) cr on cr.link_id = l.id
        left join (
          select link_id, count(*) as n, sum(o.amount) as revenue
          from public.orders o
          where o.status = 'approved' and o.reviewed_at >= v_start
          group by 1
        ) ap on ap.link_id = l.id
        where l.is_active
        order by coalesce(ap.revenue, 0) desc, l.slug
        limit 12
      ) t
    ), '[]'::jsonb)
  );
end
$function$;

revoke all on function api.admin_traffic_stats(integer) from public, anon, authenticated;
grant execute on function api.admin_traffic_stats(integer) to authenticated;

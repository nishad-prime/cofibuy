-- ---------------------------------------------------------------------------
-- The dashboard's numbers.
--
-- `admin_stats` counted states but was never rendered: the panel opened on the
-- queue because that was the only thing the shop could look at. A dashboard
-- needs more than today's counts - it needs a trend (is revenue growing?), a
-- per-page breakdown (what actually sells?), and the totals that give those
-- numbers context.
--
-- Three additions, all staff-gated like every admin read:
--
--   1. `admin_stats` grows the counters the cards want: totals, distinct
--      customers, and 30-day windows for revenue and orders.
--   2. `admin_analytics(p_days)` returns one row per day for the window - a
--      zero row for a day nothing happened, because a chart with holes reads
--      as broken data rather than as a quiet Tuesday.
--   3. `admin_page_performance(p_limit)` ranks pages by approved revenue, so
--      the operator learns which of their pages pays, not just that money
--      arrives.
--
-- Revenue means approved orders, wherever they were approved - a manual
-- approval and a settled bKash payment are the same money in the same bank.
-- ---------------------------------------------------------------------------

create or replace function api.admin_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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
    'expired_total', (select count(*) from public.orders where status = 'expired'),
    'total_orders', (select count(*) from public.orders),
    'customers', (
      select count(distinct user_id) from public.orders where user_id is not null
    ),
    'revenue', (select coalesce(sum(amount), 0) from public.orders where status = 'approved'),
    'revenue_30d', (
      select coalesce(sum(amount), 0) from public.orders
      where status = 'approved' and created_at >= now() - interval '30 days'
    ),
    'orders_30d', (
      select count(*) from public.orders
      where created_at >= now() - interval '30 days'
    ),
    'active_pages', (select count(*) from public.pages where is_active),
    'active_gateways', (select count(*) from public.payment_gateways where is_active)
  );
end
$$;

revoke all on function api.admin_stats() from public, anon, authenticated;
grant execute on function api.admin_stats() to authenticated;

create or replace function api.admin_analytics(p_days integer default 30)
returns table (
  day date,
  orders_created bigint,
  orders_approved bigint,
  revenue_approved numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- Analytics is shop-wide money. A customer's anonymous signup carries the
  -- authenticated role, so the grant alone would hand every buyer the shop's
  -- revenue - the staff check is the only thing between them and it.
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- The window is generated first and left-joined, so a day with no orders is a
  -- zero row, not a missing one: a chart that silently skips quiet days draws
  -- a line through time that does not exist. The WITH lives in a subquery
  -- because plpgsql's RETURN QUERY parser is happier with a plain SELECT.
  return query
  select
    t.day,
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
      and reviewed_at is not null
      and reviewed_at >= (now() - make_interval(days => greatest(p_days, 1) - 1))::date
    group by 1
  )
  select
    calendar.day as day,
    coalesce(created.n, 0) as orders_created,
    coalesce(approved.n, 0) as orders_approved,
    coalesce(approved.revenue, 0) as revenue_approved
  from calendar
  left join created on created.day = calendar.day
  left join approved on approved.day = calendar.day
  order by calendar.day
  ) as t;
end
$$;

revoke all on function api.admin_analytics(integer) from public, anon, authenticated;
grant execute on function api.admin_analytics(integer) to authenticated;

create or replace function api.admin_page_performance(p_limit integer default 5)
returns table (
  slug text,
  title_en text,
  title_bn text,
  orders_approved bigint,
  revenue numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- Same rule: per-page revenue is shop-wide money, not customer money.
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select
    l.slug,
    l.title_en,
    l.title_bn,
    count(o.id),
    coalesce(sum(o.amount), 0)
  from public.pages l
  join public.orders o on o.link_id = l.id and o.status = 'approved'
  where l.slug is not null
  group by l.id, l.slug, l.title_en, l.title_bn
  order by coalesce(sum(o.amount), 0) desc, count(o.id) desc
  limit least(greatest(coalesce(p_limit, 5), 1), 25);
end
$$;

revoke all on function api.admin_page_performance(integer) from public, anon, authenticated;
grant execute on function api.admin_page_performance(integer) to authenticated;

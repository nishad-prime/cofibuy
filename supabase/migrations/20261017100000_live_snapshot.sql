-- The live counters the dashboard polls every few seconds: only the scalars
-- that can move while an operator watches. Cheap by construction — one
-- indexed count per figure, no joins, no aggregation windows — so a 3-second
-- poll costs nothing at current volume. Non-staff sessions are refused with
-- the same error the other admin reads use, never answered with nulls.

create or replace function api.admin_live_snapshot()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path = ''
as $function$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'views_total', (select count(*) from public.page_views),
    'views_today', (
      select count(*) from public.page_views
      where created_at >= date_trunc('day', now())
    ),
    'orders_created_30d', (
      select count(*) from public.orders
      where created_at >= now() - interval '30 days'
    ),
    'awaiting_review', (
      select count(*) from public.orders where status = 'under_review'
    ),
    'revenue_30d', coalesce((
      select sum(coalesce(amount_received, amount)) from public.orders
      where status = 'approved' and reviewed_at >= now() - interval '30 days'
    ), 0),
    'customers', (
      select count(distinct user_id) from public.orders
    )
  );
end
$function$;

revoke all on function api.admin_live_snapshot() from public, anon, authenticated;
grant execute on function api.admin_live_snapshot() to authenticated;

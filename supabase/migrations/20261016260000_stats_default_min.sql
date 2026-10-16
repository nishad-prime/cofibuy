-- The site's default minimum, exposed to staff so the pages table can show
-- the real number behind "site default" instead of a placeholder.

create or replace function api.admin_stats()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
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
    'revenue', (
      select coalesce(sum(coalesce(amount_received, amount)), 0)
      from public.orders where status = 'approved'
    ),
    'revenue_30d', (
      select coalesce(sum(coalesce(amount_received, amount)), 0) from public.orders
      where status = 'approved' and created_at >= now() - interval '30 days'
    ),
    'orders_30d', (
      select count(*) from public.orders
      where created_at >= now() - interval '30 days'
    ),
    'active_pages', (select count(*) from public.pages where is_active),
    'active_gateways', (select count(*) from public.payment_gateways where is_active),
    'default_min', (select min_amount from public.site_settings where id = 1)
  );
end
$function$;

revoke all on function api.admin_stats() from public, anon, authenticated;
grant execute on function api.admin_stats() to authenticated;

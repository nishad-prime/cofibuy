-- The amount the operator actually received, and the visit context that ties
-- an order to its customer's visit (Part 1 + Part 2 of the analytics pass).
--
-- Revenue semantics: every admin aggregate reads coalesce(amount_received,
-- amount) from here on — the dashboard reports money that arrived. The
-- customer-facing pages keep showing the requested amount.

alter table public.orders
  add column if not exists amount_received numeric,
  add column if not exists country text,
  add column if not exists city text,
  add column if not exists device_type text,
  add column if not exists os text,
  add column if not exists browser text,
  add column if not exists referrer text;

comment on column public.orders.amount_received is
  'What the operator actually received, recorded at approval. Null until an operator sets it; revenue aggregates coalesce this over amount.';
comment on column public.orders.country is
  'Visit context snapshot, captured at order creation from the edge geo. No IP is stored anywhere.';
comment on column public.orders.city is
  'City from the edge geo, as coarse as Cloudflare reports it.';

alter table public.orders
  add constraint orders_amount_received_positive
  check (amount_received is null or amount_received > 0);

-- ---------------------------------------------------------------------------
-- approve_order: records the received amount
-- ---------------------------------------------------------------------------

create or replace function api.approve_order(p_order_id uuid, p_amount_received numeric default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_order public.orders;
  v_actor uuid := auth.uid();
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_amount_received is not null and p_amount_received <= 0 then
    raise exception 'received amount must be positive' using errcode = '22023';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if v_order.status = 'approved' then
    return jsonb_build_object('ok', true, 'status', 'approved', 'already', true);
  end if;

  if v_order.status <> 'under_review' then
    raise exception 'order is not under review' using errcode = '22023';
  end if;

  -- The grant is created by an after-update trigger, so access follows approval
  -- no matter which path approved it, and cannot be forgotten.
  update public.orders
  set status = 'approved',
      amount_received = p_amount_received,
      reviewed_at = now(),
      reviewed_by = v_actor,
      reject_reason_en = null,
      reject_reason_bn = null,
      reject_code = null
  where id = p_order_id;

  return jsonb_build_object('ok', true, 'status', 'approved', 'already', false);
end
$function$;

revoke all on function api.approve_order(uuid, numeric) from public, anon, authenticated;
grant execute on function api.approve_order(uuid, numeric) to authenticated;

-- The old single-argument signature goes: a call without the amount is still
-- valid (the parameter defaults), but the old overload would leave two ways
-- to approve and only one of them recording money.
drop function if exists api.approve_order(uuid);

-- ---------------------------------------------------------------------------
-- Revenue aggregates read the received amount
-- ---------------------------------------------------------------------------

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
    'active_gateways', (select count(*) from public.payment_gateways where is_active)
  );
end
$function$;

revoke all on function api.admin_stats() from public, anon, authenticated;
grant execute on function api.admin_stats() to authenticated;

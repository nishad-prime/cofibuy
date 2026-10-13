-- ---------------------------------------------------------------------------
-- Detach a rejected order from the customer who owns it.
--
-- A rejected order used to be a dead end: `create_order` treats `rejected` as
-- an open status, so the same payment kind silently re-returned the rejected
-- order and a different kind raised `kind_mismatch` - either way the customer
-- was handed straight back to the order that had just been refused and could
-- never start a fresh one.
--
-- Rather than teaching the order-creation path to look past rejections (the
-- reuse logic there is the duplicate-order safety net for genuinely open
-- statuses), the customer can now leave the rejection behind: detaching
-- clears the order's `user_id`, so `my_orders` no longer returns it and no
-- open-order set ever sees it again. The row itself stays for the operator -
-- the admin queue reads by status and id, never by `user_id` - so the audit
-- trail of what was rejected, and why, is untouched.
--
-- Only rejected orders detach, and only by their owner: every other status
-- still means something (open orders must be resolved, approved orders are
-- ownership), and a customer who could drop any order could escape a probe
-- lock by detaching it.
-- ---------------------------------------------------------------------------

create or replace function api.detach_order(p_order_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  update public.orders
  set user_id = null
  where id = p_order_id
    and user_id = auth.uid()
    and status = 'rejected';

  if not found then
    raise exception 'order not detachable' using errcode = 'P0002';
  end if;
end;
$$;

-- The order row survives for the operator - the admin queue reads by status
-- and id, never by `user_id` - so the audit trail of what was rejected, and
-- why, is untouched. Detaching is the one case where an order loses its user,
-- so the column's NOT NULL gives way here; every status that still means
-- ownership is created with a user and keeps one.
alter table public.orders
  alter column user_id drop not null;

comment on function api.detach_order(uuid) is
  'The customer leaves a rejected order behind: the order loses its user, so '
  'it stops appearing in my_orders and no longer blocks a new order. Only the '
  'owner may detach, and only a rejected order.';

revoke all on function api.detach_order(uuid) from public, anon;
grant execute on function api.detach_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- The duplicate-TrxID scan only compares transaction IDs.
--
-- The scanner used to compare every evidence value on two orders, so the same
-- 500 paid twice - or the same sender number, which is one customer's habit -
-- was reported as "this transaction ID also appears on another order", and the
-- warning fired on practically every order in the queue. It now only compares
-- values on fields the gateway's evidence schema validates as a `trxid`, which
-- is what the flag always claimed to be about.
--
-- Both definitions come verbatim from the live database and are patched only
-- in the one join each, so nothing the migrations since the last dump changed
-- is silently reverted.
-- ---------------------------------------------------------------------------

-- admin_order_duplicate_trxids: trxid-only scan
CREATE OR REPLACE FUNCTION api.admin_order_duplicate_trxids(p_order_id uuid)
 RETURNS TABLE(field_key text, value_text_norm text, other_order_ids uuid[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Only fields the gateway validates as a TrxID take part. The scan used to
  -- compare every evidence value, so two orders that both paid 500 - or shared
  -- a sender number - were reported as sharing a transaction ID, and the
  -- operator's warning fired on practically every order in the queue.
  return query
  select
    e.field_key,
    e.value_text_norm,
    array_agg(distinct other.id) as other_order_ids
  from public.order_evidence e
  join public.order_evidence dup
    on dup.field_key = e.field_key
   and dup.value_text_norm is not null
   and dup.value_text_norm = e.value_text_norm
   and dup.order_id <> e.order_id
  join public.orders other on other.id = dup.order_id
  where e.order_id = p_order_id
    and e.value_text_norm is not null
    and e.field_key in (
      select f ->> 'key'
      from public.orders o
      join public.payment_gateways g on g.id = o.gateway_id
      cross join lateral jsonb_array_elements(g.evidence_fields) f
      where o.id = p_order_id and f ->> 'validate' = 'trxid'
    )
  group by e.field_key, e.value_text_norm
  having count(distinct dup.order_id) > 0;
end
$function$;

revoke all on function api.admin_order_duplicate_trxids(p_order_id uuid) from public, anon, authenticated;
grant execute on function api.admin_order_duplicate_trxids(p_order_id uuid) to authenticated;

-- admin_orders: the queue's duplicate flag follows the same rule
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
      where e.order_id = o.id
        and e.value_text_norm is not null
        -- The flag is about transaction IDs; the same amount on two orders is
        -- two customers paying the same price, not a shared TrxID.
        and e.field_key in (
          select f ->> 'key'
          from public.payment_gateways gg
          cross join lateral jsonb_array_elements(gg.evidence_fields) f
          where gg.id = o.gateway_id and f ->> 'validate' = 'trxid'
        )
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

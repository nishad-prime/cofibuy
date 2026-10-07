-- ---------------------------------------------------------------------------
-- Pay online becomes one step.
--
-- The customer's old path was: submit the paywall form (order created), land on
-- the order page, press "pay online", wait for the function to open a bKash
-- session, leave for bKash. Two round trips to do what is one decision: pay
-- this amount, this way, now.
--
-- `pay_online_start` fuses the two RPCs the old path needed. It creates (or
-- reuses) the open order and immediately opens the bKash payment session, so
-- the pay button on the page goes straight to bKash. The refusals pass through
-- unchanged: `create_order_resolved`'s `ok: false` envelopes below_minimum and
-- locked, its exceptions (kind_mismatch, authentication) still raise, and
-- `bkash_payment_start` still owns every rule about who may charge an order.
--
-- Retry stays where it was: an order that already exists goes through
-- `bkash-create-payment` with its order id, which needs nothing from here.
-- ---------------------------------------------------------------------------

create or replace function api.pay_online_start(
  p_slug text,
  p_kind text,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order jsonb;
  v_start jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  v_order := api.create_order_resolved(p_slug, p_kind, p_amount);

  -- A refusal envelope (below_minimum, locked) is an answer, not an error: the
  -- caller shows it against the form exactly as the paywall always has.
  if not coalesce((v_order ->> 'ok')::boolean, false) then
    return v_order;
  end if;

  -- The order now exists and belongs to the caller, so the payment-start rules
  -- (bKash only, BDT only, not settled, not expired) apply unchanged.
  v_start := api.bkash_payment_start((v_order ->> 'order_id')::uuid);

  return jsonb_build_object(
    'ok', true,
    'order_id', v_start ->> 'order_id',
    'gateway_id', v_start ->> 'gateway_id',
    'amount', v_start ->> 'amount',
    'currency', v_start ->> 'currency',
    'environment', v_start ->> 'environment',
    'sandbox', v_start -> 'sandbox'
  );
end
$$;

revoke all on function api.pay_online_start(text, text, numeric) from public, anon, authenticated;
grant execute on function api.pay_online_start(text, text, numeric) to authenticated;

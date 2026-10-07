-- ---------------------------------------------------------------------------
-- pay_online_start forwards what bKash's create call needs.
--
-- The first cut returned only what the paywall displays - order, gateway,
-- amount, currency, environment - and dropped the two fields the edge function
-- hands to bKash's create-payment: the merchant invoice number and the payer
-- reference. `bkash_payment_start` computes both from the order (the invoice is
-- the reference code, which is what makes a bKash statement reconcilable
-- without the IPN), so the function went out with `invoice: "undefined"` -
-- a string, well-formed enough to pass bKash's character check, and useless
-- the day someone has to match a real payment to an order by hand.
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
    'sandbox', v_start -> 'sandbox',
    'invoice', v_start ->> 'invoice',
    'payer_reference', v_start ->> 'payer_reference'
  );
end
$$;

revoke all on function api.pay_online_start(text, text, numeric) from public, anon, authenticated;
grant execute on function api.pay_online_start(text, text, numeric) to authenticated;

-- The customer order page needs the payment instructions and the evidence
-- schema for the chosen gateway. It was reaching for those with direct
-- `.from('orders')` / `.from('payment_gateways')` queries, which cannot work:
-- those tables have no select grant and RLS hides them, so the evidence form
-- always rendered empty. Serve them from the existing security definer RPC
-- instead, so no new surface is opened up.
create or replace function api.my_order_status(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_gateway public.payment_gateways;
begin
  select * into v_order from public.orders where id = p_order_id and user_id = auth.uid();
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if v_order.gateway_id is not null then
    select * into v_gateway from public.payment_gateways g where g.id = v_order.gateway_id;
  end if;

  return jsonb_build_object(
    'id', v_order.id,
    'status', v_order.status,
    'reference_code', v_order.reference_code,
    'amount', v_order.amount,
    'attempt_count', v_order.attempt_count,
    'reject_reason_en', v_order.reject_reason_en,
    'reject_reason_bn', v_order.reject_reason_bn,
    'expires_at', v_order.expires_at,
    'gateway', case
      when v_gateway.id is null then null
      else jsonb_build_object(
        'id', v_gateway.id,
        'kind', v_gateway.kind,
        'name_en', v_gateway.name_en,
        'name_bn', v_gateway.name_bn,
        'account_number', v_gateway.account_number,
        'account_name', v_gateway.account_name,
        'instructions_md_en', v_gateway.instructions_md_en,
        'instructions_md_bn', v_gateway.instructions_md_bn,
        'reference_prompt_en', v_gateway.reference_prompt_en,
        'reference_prompt_bn', v_gateway.reference_prompt_bn,
        'supports_reference', v_gateway.supports_reference,
        'evidence_fields', v_gateway.evidence_fields
      )
    end
  );
end
$$;
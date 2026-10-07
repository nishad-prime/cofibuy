-- ---------------------------------------------------------------------------
-- 19: pay_online_start
--
-- The one-step RPC fuses order creation and payment-session start. Its rules
-- are inherited - `create_order_resolved` owns the order, `bkash_payment_start`
-- owns the charge - so these tests pin only the seams the fusion adds: the
-- auth floor, the refusal envelope that passes through as an answer, and the
-- fact that the order a successful call leaves behind is the customer's own.
-- ---------------------------------------------------------------------------

begin;
select test_data.reset();

select test_data.link('report', 500, false);
select test_data.pgw_gateway();

-- The auth floor: without a session there is no customer to owe the order to.
select is(
  test_data.as_role(
    'anon',
    'select api.pay_online_start(''report'', ''bkash Payment'', 500)'
  ) ->> 'state',
  '42501',
  'pay_online_start refuses an anonymous caller'
);

-- A below-minimum amount must come back as an answer, not a raise: the paywall
-- form renders the refusal against the amount field exactly as it always has.
select test_data.as_user(test_data.new_user());

select is(
  test_data.as_role(
    'authenticated',
    $q$select coalesce(
      api.pay_online_start(
        'report',
        (select kind from public.payment_gateways where provider = 'bkash_pgw' limit 1),
        10
      ) ->> 'code',
      'none'
    )$q$
  ) #> '{rows,0,coalesce}',
  '"below_minimum"',
  'a too-small amount returns the below_minimum envelope'
);

-- The happy path, up to the boundary of the RPC's own responsibilities. Both
-- halves are pure SQL - the bKash token dance belongs to the edge function -
-- so a full success is reachable in a test, and the order it leaves behind is
-- the caller's own draft.
select test_data.as_user(test_data.new_user());

select is(
  test_data.as_role(
    'authenticated',
    $q$select api.pay_online_start(
      'report',
      (select kind from public.payment_gateways where provider = 'bkash_pgw' limit 1),
      500
    ) ->> 'ok' as res$q$
  ) #> '{rows,0,res}',
  '"true"',
  'one call takes the customer from nothing to an open payment session'
);

-- The create-payment call the edge function makes next reads the invoice and the
-- payer reference off this payload; a missing one went to bKash as "undefined".
-- The invoice must be a reference code the order table actually knows. The value
-- is stashed in a GUC because the alternative - comparing inside one statement -
-- either re-runs the volatile call per row or races the created_at ordering.
select test_data.as_role(
  'authenticated',
  $q$select set_config(
    'test.invoice',
    api.pay_online_start(
      'report',
      (select kind from public.payment_gateways where provider = 'bkash_pgw' limit 1),
      500
    ) ->> 'invoice',
    true
  ) as res$q$
);

select is(
  test_data.as_role(
    'postgres',
    $q$select (select count(*) from public.orders
      where reference_code = current_setting('test.invoice', true))::text as res$q$
  ) #> '{rows,0,res}',
  '"1"',
  'and it carries the order reference as the merchant invoice'
);

select * from finish();
rollback;

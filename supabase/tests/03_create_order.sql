-- Order creation and the probe path.
--
-- The interesting behaviour here is what happens when a customer gets the amount
-- wrong. Guessing the threshold must be useless: the reply cannot differ, and a
-- run of guesses must cost something.

select plan(33);

select test_data.reset();

select test_data.link('guide', 500, false);
select test_data.gateway('bkash');

-- A draft link, so "not published" and "does not exist" can be told apart.
insert into public.paywall_links (slug, title_en, is_active)
values ('unpublished', 'Draft', false);

-- ---------------------------------------------------------------------------
-- Authentication
-- ---------------------------------------------------------------------------

select test_data.as_anon();

select throws_ok(
  $$select api.create_order('guide', null, 500)$$,
  '42501',
  'an anonymous visitor cannot start an order'
);

-- ---------------------------------------------------------------------------
-- Targets that do not exist, or are not for sale
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.new_user());

select throws_ok(
  $$select api.create_order('no-such-link', null, 500)$$,
  'P0002',
  'an unknown slug is refused'
);

select throws_ok(
  $$select api.create_order('unpublished', null, 500)$$,
  'P0002',
  'an unpublished link is refused'
);

select throws_ok(
  $$select api.create_order('guide', '00000000-0000-0000-0000-000000000000', 500)$$,
  'P0002',
  'an unknown payment method is refused'
);

-- Deactivating a gateway takes it off the shelf without deleting it, so a
-- customer mid-checkout cannot pay into an account the operator has retired.
update public.payment_gateways set is_active = false;

select throws_ok(
  $$select api.create_order('guide', (select id from public.payment_gateways where name_en = 'bKash'), 500)$$,
  'P0002',
  'a deactivated payment method is refused'
);

update public.payment_gateways set is_active = true;
select test_data.as_anon();

-- ---------------------------------------------------------------------------
-- A valid order
-- ---------------------------------------------------------------------------

select is(
  test_data.new_customer_orders('guide', 'bKash', 750) ->> 'ok',
  'true',
  'a valid amount starts an order'
);

select is(
  (select status::text from test_data.order_for((select user_id from public.orders limit 1))),
  'awaiting_proof',
  'the order waits for a screenshot'
);

select is(
  (select amount::numeric from public.orders where status = 'awaiting_proof'),
  750,
  'the amount is what the customer said they sent'
);

select is(
  (select reference_code from public.orders where status = 'awaiting_proof') ~ '^[2-9A-HJ-NP-Z]{8}$',
  true,
  'the order carries a reference code for the payment reference field'
);

-- The terms are snapshotted, so raising the minimum later cannot invalidate an
-- order that is already waiting for a screenshot.
select is(
  (select min_amount_snapshot::numeric from public.orders where status = 'awaiting_proof'),
  500,
  'the minimum is snapshotted onto the order'
);

update public.site_settings set min_amount = 5000 where id = 1;

select is(
  (select min_amount_snapshot::numeric from public.orders where status = 'awaiting_proof'),
  500,
  'a later change to the global minimum does not touch it'
);

-- ---------------------------------------------------------------------------
-- The boundary
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');

-- Exactly at the minimum counts. Being one taka short should not cost someone a
-- screenshot they have already paid for.
select is(
  test_data.new_customer_orders('guide', 'bKash', 500) ->> 'ok',
  'true',
  'an amount exactly equal to the minimum is accepted'
);

select is(
  test_data.new_customer_orders('guide', 'bKash', 499.99) ->> 'ok',
  'false',
  'one taka under the minimum is not'
);

-- ---------------------------------------------------------------------------
-- Probing
--
-- The response for a rejected amount is a fixed shape. If it ever gained a field
-- that varied with how close the guess was, the minimum would be discoverable by
-- trying amounts and watching for a difference.
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');

select is(
  test_data.new_customer_orders('guide', 'bKash', 499.99),
  '{"code": "below_minimum", "ok": false}'::jsonb,
  'a near miss is answered with nothing about the threshold'
);

select is(
  test_data.new_customer_orders('guide', 'bKash', 1),
  '{"code": "below_minimum", "ok": false}'::jsonb,
  'a wildly low guess gets the identical answer'
);

select is(
  (select count(*)::int from public.orders where status <> 'draft'),
  0,
  'a probe never becomes a real order'
);

select is(
  (select count(*)::int from public.orders),
  2,
  'each customer probing gets their own draft row'
);

select is(
  (select min(probe_count) from public.orders),
  1,
  'each is counted once'
);

-- ---------------------------------------------------------------------------
-- The lock
--
-- One customer guessing repeatedly. Six trips it, and asking again afterwards
-- must not quietly hand out a fresh budget.
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();

do $$
begin
  perform test_data.orders('guide', 'bKash', 10);
  perform test_data.orders('guide', 'bKash', 10);
  perform test_data.orders('guide', 'bKash', 10);
  perform test_data.orders('guide', 'bKash', 10);
  perform test_data.orders('guide', 'bKash', 10);
end
$$;

select is(
  (select probe_count from test_data.subject_order()),
  5,
  'each guess by the same customer is counted'
);

select is(
  (select status::text from test_data.subject_order()),
  'draft',
  'five guesses have not locked yet'
);

select is(
  test_data.orders('guide', 'bKash', 10) ->> 'code',
  'below_minimum',
  'the sixth guess is still answered normally'
);

select is(
  (select status::text from test_data.subject_order()),
  'locked',
  'but the sixth guess locks the link for that customer'
);

select is(
  test_data.orders('guide', 'bKash', 900) ->> 'code',
  'locked',
  'a locked customer is told so rather than being quietly re-admitted'
);

select is(
  test_data.orders('guide', 'bKash', 900) ->> 'ok',
  'false',
  'and a generous amount is not accepted either'
);

select is(
  (select count(*)::int from public.orders where user_id = test_data.subject_id()),
  1,
  'a locked customer cannot start a second order'
);

-- A lock is about one customer, not about the link.
select is(
  test_data.new_customer_orders('guide', 'bKash', 900) ->> 'ok',
  'true',
  'a different customer is unaffected by someone else being locked'
);

-- ---------------------------------------------------------------------------
-- One open order per link
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();

select is(
  test_data.orders('guide', 'bKash', 800) ->> 'ok',
  'true',
  'the first valid order starts'
);

select is(
  test_data.orders('guide', 'bKash', 900) ->> 'ok',
  'true',
  'asking again reuses it rather than failing'
);

select is(
  (select count(*)::int from public.orders where user_id = test_data.subject_id()),
  1,
  'only one order exists for that customer'
);

select is(
  (test_data.subject_order()).amount::numeric,
  800,
  'the reused order keeps the amount the customer first stated'
);

select is(
  test_data.orders('guide', 'bKash', 900) ->> 'reference_code',
  (test_data.subject_order()).reference_code,
  'and the same reference code comes back'
);

-- ---------------------------------------------------------------------------
-- A hidden minimum
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('hidden-price', 750, true);
select test_data.gateway('bkash');
select test_data.new_subject();

select is(
  test_data.orders('hidden-price', 'bKash', 1000) ->> 'min_amount',
  null,
  'a successful order on a hidden link does not disclose the minimum'
);

select is(
  test_data.orders('hidden-price', 'bKash', 1000) ->> 'min_hidden',
  'true',
  'but it does say the minimum is hidden'
);

select test_data.as_anon();

select * from finish();

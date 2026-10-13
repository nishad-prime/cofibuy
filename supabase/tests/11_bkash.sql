-- bKash PGW: automated payment capture.
--
-- The manual bKash method asks for a screenshot and a TrxID and a staff decision. This
-- file covers the other one, where bKash tells the server what happened and the money
-- settles itself. The two share `gateway_kind = 'bkash'` and nothing else, so most of
-- what is worth testing here is the boundary between "we were told" and "we checked".
--
-- The invariants, in the order they matter:
--
--   1. Only the server settles. Every money-path function is service_role only, so a
--      customer cannot mark their own order paid by calling anything directly.
--   2. The return URL is not proof. `status=success` arrives from the customer's own
--      browser, so settlement is driven by a server-confirmed result and by nothing the
--      client sends.
--   3. One payment settles one order, and one transaction settles one order. The partial
--      unique indexes are the backstop, and they are asserted rather than assumed.
--   4. The amount charged is the amount on the order. A mismatch must never grant access.
--   5. The TrxID budget. Grant/Refresh Token may be called twice an hour and exceeding
--      that stops the shop taking payments, so the refresh lease is tested for granting
--      exactly one winner.

select plan(77);

select test_data.reset();

select test_data.link('auto', 500, false);
select test_data.link('other', 500, false);
select test_data.link('paid', 500, false);
select test_data.gateway('bkash');
select test_data.pgw_gateway();

-- The token cache is keyed by credential bundle, and the fixture gateway has none until
-- it is given credentials. This is the same setup the Edge Function performs at
-- settlement time, done here as the owner so the cache assertions below have a bundle to
-- address. Retargeting an existing row by id rather than inserting keeps the fixture's
-- single automated method unambiguous for the "the fixture's method is the one under
-- test" lookups used later in this file.
select test_data.as_user(test_data.owner());
select api.admin_upsert_gateway(
  jsonb_build_object(
    'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
    'kind', (select kind from public.payment_gateways where provider = 'bkash_pgw' limit 1),
    'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
    -- Spelled out rather than left to the default. `admin_upsert_gateway` defaults an
    -- absent environment to sandbox, which is the right direction - a merchant is never
    -- promoted to live by an edit that forgot to mention it - but this file settles real
    -- money paths, so the gateway has to be live by name rather than by omission. The
    -- production form always sends the field, so this is a fixture's habit and not a
    -- behaviour anyone relies on.
    'environment', 'live',
    'credential_bundle', jsonb_build_object(
      'app_key', 'fixture-app-key', 'app_secret', 'fixture-app-secret',
      'username', 'fixture-username', 'password', 'fixture-password'))
);
select test_data.as_service();

-- ---------------------------------------------------------------------------
-- The gateway registry
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.payment_gateways
       (kind, provider, name_en, account_number, account_name, evidence_fields)
     values ('bkash', 'stripe', 'Stripe', '1', 'X', '[]'::jsonb)$$,
  '23514',
  'unknown payment provider: stripe',
  'an unknown provider is refused at the constraint'
);

select throws_ok(
  $$insert into public.payment_gateways
       (kind, provider, name_en, account_number, account_name, evidence_fields)
     values ('bkash_instant', 'bkash_pgw', 'Mixed', '1', 'X',
             '[{"key":"trxid","type":"text","label_en":"TrxID","required":true,"max_len":24}]'::jsonb)$$,
  '23514',
'new row for relation "payment_gateways" violates check constraint "payment_gateways_automatic_has_no_forms"',
  'an automated gateway cannot also ask for evidence'
);

select is(
  (select provider from public.payment_gateways where provider is not null),
  'bkash_pgw',
  'the fixture is an automated bKash method'
);

select is(
  (select count(*) from public.payment_gateways where provider is null),
  1,
  'the manual method is untouched and still has no provider'
);

-- `admin_upsert_gateway` is the only write path, so the constraint above is a backstop
-- rather than the rule. The function has to reject it too, with something an operator
-- can act on rather than a raw enum error.
select test_data.as_anon();
select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bkash', 'provider', 'stripe',
                         'name_en', 'X', 'account_number', '1', 'account_name', 'Y'))$$,
  '42501',
  'forbidden',
  'anon cannot register a gateway'
);

select test_data.as_user(test_data.new_staff());
select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bkash', 'provider', 'stripe',
                         'name_en', 'X', 'account_number', '1', 'account_name', 'Y'))$$,
  '42501',
  'forbidden',
  'staff cannot register a gateway'
);

select test_data.as_user(test_data.owner());
select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bkash', 'provider', 'stripe',
                         'name_en', 'X', 'account_number', '1', 'account_name', 'Y'))$$,
  '22023',
  'unknown payment provider: stripe',
  'the owner cannot register an unknown provider either'
);

--
-- Its own kind, and that is the point rather than a detail. Sharing `bkash_instant` with the
-- fixture gateway put a second active method of the same kind into the routing pool, so
-- which one an order got was down to a weighted coin flip. That was survivable while both
-- behaved identically; the moment one is sandbox and the other is live, "survivable" is a
-- test that passes or fails depending on the run.
select is(
  (api.admin_upsert_gateway(
     jsonb_build_object('kind', 'bkash_instant_second', 'provider', 'bkash_pgw',
                        'name_en', 'bKash instant', 'account_number', '01700000000',
                        'account_name', 'Cofibuy'))).provider,
  'bkash_pgw',
  'the owner can register an automated method'
);

-- Which is the fail-safe worth pinning: a method nobody has configured is sandbox. It is
-- why an edit that forgets the environment cannot promote a shop to live by accident.
select is(
  (api.admin_upsert_gateway(
     jsonb_build_object('kind', 'bkash_instant_third', 'provider', 'bkash_pgw',
                        'name_en', 'bKash instant three'))).environment,
  'sandbox',
  'and a newly registered method defaults to sandbox'
);

-- ---------------------------------------------------------------------------
-- The public payload
-- ---------------------------------------------------------------------------

select test_data.as_anon();
select is(
  (select g ->> 'provider' from jsonb_array_elements(
    (api.get_public_page('auto') -> 'gateways')
  ) g where g ->> 'name_en' = 'bKash (instant)'),
  'bkash_pgw',
  'the customer can see which methods take an online payment'
);

-- Compared against the payload's own length rather than a fixed number: the registry
-- has grown by one gateway above, and what matters is that nothing is silently missing
-- the key, not how many methods happen to exist.
select is(
  (select count(*)::int from jsonb_array_elements(
    (api.get_public_page('auto') -> 'gateways')
  ) g where g ? 'provider'),
  (select jsonb_array_length(api.get_public_page('auto') -> 'gateways'))::int,
  'every gateway in the payload carries provider, manual ones included'
);

select is(
  (select g ->> 'provider' from jsonb_array_elements(
    (api.get_public_page('auto') -> 'gateways')
  ) g where g ->> 'name_en' = 'bKash'),
  null,
  'a manual method reports no provider rather than a made-up one'
);

-- The wrapper added a key by rewriting the gateway array. The projection underneath
-- encodes the hidden-minimum rule, the single most important expression in the schema,
-- and it is reached through the moved-aside function. If the join in the wrapper dropped
-- the rest of the document this is what would notice.
select is(
  (api.get_public_page('auto') ->> 'min_amount')::numeric,
  500,
  'the wrapper preserved the rest of the payload'
);

select is(
  (api.get_public_page('auto') ->> 'maintenance_mode'),
  'false',
  'and the outer wrapper still adds maintenance_mode'
);

select test_data.as_user(test_data.new_user());
select is(
  (api.get_public_page('auto') ->> 'min_amount')::numeric,
  500,
  'the minimum is still readable when it is not hidden'
);

select test_data.as_anon();
select is(
  test_data.can_execute('anon', 'api.public_page_payload(text)'),
  true,
  'the public payload is a public read endpoint'
);

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------

select is(
  test_data.can_execute('authenticated', 'api.bkash_payment_start(uuid)'),
  true,
  'a customer can start a payment'
);

select is(
  test_data.can_execute('anon', 'api.bkash_payment_start(uuid)'),
  false,
  'anon cannot start a payment'
);

select is(
  test_data.can_execute('authenticated', 'api.bkash_record_session(uuid, text, numeric)'),
  false,
  'a customer cannot record a payment session'
);

select is(
  test_data.can_execute('authenticated', 'api.bkash_settle_order(uuid, text, text, text, numeric)'),
  false,
  'a customer cannot settle an order'
);

select is(
  test_data.can_execute('authenticated', 'api.bkash_fail_session(uuid, text, text)'),
  false,
  'a customer cannot fail a payment session'
);

select is(
  test_data.can_execute('authenticated', 'api.bkash_token_state(uuid, text)'),
  false,
  'a customer cannot read the token cache'
);

select is(
  test_data.can_execute('authenticated', 'api.bkash_claim_refresh(uuid, text)'),
  false,
  'a customer cannot claim a token refresh'
);

select is(
  test_data.can_execute('authenticated', 'api.bkash_store_token(uuid, text, text, text, integer)'),
  false,
  'a customer cannot write the token cache'
);

select is(
  test_data.can_execute('service_role', 'api.bkash_settle_order(uuid, text, text, text, numeric)'),
  true,
  'the worker can settle'
);

-- ---------------------------------------------------------------------------
-- Starting a payment
-- ---------------------------------------------------------------------------

select test_data.pgw_order('auto') as paid_order;

select test_data.as_user(test_data.customer_of('auto'));
select lives_ok(
  $$select api.bkash_payment_start(test_data.order_for_customer('auto'))$$,
  'a customer can start a payment for their own order'
);

select is(
  (select api.bkash_payment_start(test_data.order_for_customer('auto')) ->> 'amount')::numeric,
  500,
  'the amount comes from the stored order'
);

select is(
  (select api.bkash_payment_start(test_data.order_for_customer('auto')) ->> 'currency'),
  'BDT',
  'the currency is BDT'
);

select is(
  (select api.bkash_payment_start(test_data.order_for_customer('auto')) ->> 'invoice'),
  (select o.reference_code from public.orders o
    join public.pages l on l.id = o.link_id where l.slug = 'auto'),
  'the invoice is the order reference code, which is what makes a bKash statement reconcilable'
);

-- The whole point of reading the amount from the order: there is no amount parameter for
-- a client to set, so the price cannot be anything but what the order says.
select is(
  (select p.proargnames::text from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'bkash_payment_start'),
  '{p_order_id}',
  'there is no amount parameter for a client to set'
);

select throws_ok(
  $$select api.bkash_payment_start(gen_random_uuid())$$,
  'P0002',
  'order not found',
  'someone else''s order is not found'
);

select test_data.as_anon();
select throws_ok(
  $$select api.bkash_payment_start(test_data.order_for_customer('auto'))$$,
  '42501',
  'authentication required',
  'anon cannot start a payment'
);

-- A manual method is not an online method. Offering a Pay button on it would send the
-- customer to a page expecting a PIN for a method that has no session behind it.
select test_data.manual_order('other') as manual_order;
select test_data.as_user(test_data.customer_of('other'));
select throws_ok(
  $$select api.bkash_payment_start(test_data.order_for_customer('other'))$$,
  '22023',
  'this payment method does not accept online payment',
  'a manual method refuses an online payment'
);

-- bKash accepts BDT only. The store currency is a setting across eleven codes, so this
-- is where "this backend cannot serve this shop" is said rather than at a failed API call.
select test_data.as_user(test_data.owner());
select api.admin_set_settings(jsonb_build_object('currency', 'USD'));
select test_data.as_user(test_data.customer_of('auto'));
select throws_ok(
  $$select api.bkash_payment_start(test_data.order_for_customer('auto'))$$,
  '22023',
  'online payment is only available in BDT',
  'an online payment is refused when the store currency is not BDT'
);

select test_data.as_user(test_data.owner());
select api.admin_set_settings(jsonb_build_object('currency', 'BDT'));
select test_data.as_user(test_data.customer_of('auto'));

-- ---------------------------------------------------------------------------
-- Payment sessions
-- ---------------------------------------------------------------------------

select test_data.as_service();
select lives_ok(
  $$select api.bkash_record_session(test_data.order_for_customer('auto'), 'TR001PAY0001', 500)$$,
  'the worker can record a session'
);

select throws_ok(
  $$select api.bkash_record_session(test_data.order_for_customer('auto'), 'TR001PAY0002', 499)$$,
  '22023',
'bkash amount does not match the order',
  'a session cannot be recorded for a different amount than the order'
);

-- The idempotency key. A repeated callback or a retried request collides here rather
-- than opening a second attempt at the same money.
select lives_ok(
  $$select api.bkash_record_session(test_data.order_for_customer('auto'), 'TR001PAY0001', 500)$$,
  'recording the same payment id again is idempotent, not an error'
);

select is(
  (select count(*) from public.payment_sessions where provider_payment_id = 'TR001PAY0001'),
  1,
  'and it leaves exactly one row'
);

select throws_ok(
  $$insert into public.payment_sessions
       (order_id, provider, provider_payment_id, amount, currency)
     values (test_data.order_for_customer('auto'), 'bkash_pgw', 'not a valid id!', 500, 'BDT')$$,
  '23514',
  'new row for relation "payment_sessions" violates check constraint "payment_sessions_payment_id_shape"',
  'a payment id that cannot be one is refused'
);

select throws_ok(
  $$insert into public.payment_sessions
       (order_id, provider, provider_payment_id, amount, currency)
     values (test_data.order_for_customer('auto'), 'bkash_pgw', 'TR001USD0001', 500, 'USD')$$,
  '23514',
  'new row for relation "payment_sessions" violates check constraint "payment_sessions_currency_bdt"',
  'a non-BDT session is refused'
);

select is(
  test_data.as_role('anon', 'select count(*)::int as n from public.payment_sessions') ->> 'state',
  '42501',
  'a customer cannot read the settlement trail'
);

select is(
  test_data.as_role('authenticated', 'select count(*)::int as n from public.payment_sessions') ->> 'state',
  '42501',
  'the TrxID is not readable by the customer it is evidence about'
);

select is(
  (select relrowsecurity from pg_class where oid = 'public.payment_sessions'::regclass),
  true,
  'payment_sessions has RLS enabled'
);

-- ---------------------------------------------------------------------------
-- Settling
-- ---------------------------------------------------------------------------

select test_data.as_service();
select is(
  (select (api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'TR001PAY0001', 'TRXAAA111', '01712345678', 500))
     ->> 'ok'),
  'true',
  'a confirmed payment settles the order'
);

select is(
  (select o.status::text from public.orders o
    join public.pages l on l.id = o.link_id where l.slug = 'auto'),
  'approved',
  'the order is approved'
);

select is(
  (select count(*) from public.access_grants
    where via_order_id = test_data.order_for_customer('auto')),
  1,
  'exactly one access grant was created'
);

select is(
  (select o.reviewed_by from public.orders o
    join public.pages l on l.id = o.link_id where l.slug = 'auto'),
  null,
  'reviewed_by stays null: nobody in this shop clicked approve'
);

select is(
  (select o.reviewed_at is not null from public.orders o
    join public.pages l on l.id = o.link_id where l.slug = 'auto'),
  true,
  'reviewed_at is set, which is what the constraint requires and what is true'
);

-- The two-hop settlement shows up in the audit trail. `guard_order_status` has no
-- awaiting_proof -> approved edge precisely so nothing can skip review, and this is the
-- evidence that the automated path went around it legitimately rather than being granted
-- a new edge that everything else could then use.
select is(
  (select count(*) from public.audit_log
     where target_id = test_data.order_for_customer('auto')::text
       and action = 'order.status_changed'),
  2,
  'settlement walked awaiting_proof -> under_review -> approved'
);

select is(
  (select provider_trx_id from public.payment_sessions where provider_payment_id = 'TR001PAY0001'),
  'TRXAAA111',
  'the TrxID is recorded'
);

select is(
  (select provider_account from public.payment_sessions where provider_payment_id = 'TR001PAY0001'),
  '01712345678',
  'the payer account is recorded'
);

-- A customer reloading the return page, or bKash delivering the same callback twice.
select is(
  (select (api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'TR001PAY0001', 'TRXAAA111', '01712345678', 500))
     ->> 'already'),
  'true',
  'settling the same payment twice is a no-op'
);

select is(
  (select count(*) from public.access_grants
    where via_order_id = test_data.order_for_customer('auto')),
  1,
  'and does not issue a second access grant'
);

select throws_ok(
  $$select api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'TR001PAY0001', '   ', '01712345678', 500)$$,
  '22023',
  'a completed payment must carry a trx id',
  'a completed payment must carry a TrxID'
);

select throws_ok(
  $$select api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'TR001PAY0001', 'TRXBBB222', '01712345678', 400)$$,
  '22023',
  'confirmed amount does not match the order',
  'a confirmed amount that differs from the order is refused'
);

select throws_ok(
  $$select api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'TR001NOSUCH', 'TRXCCC333', '01712345678', 500)$$,
  'P0002',
  'no payment session for TR001NOSUCH',
  'an unknown payment id cannot settle anything'
);

-- A customer paying twice is a refund conversation, not a second unlock. The index
-- refuses it rather than quietly granting again.
select api.bkash_record_session(test_data.order_for_customer('auto'), 'TR001PAY0002', 500);
select throws_ok(
  $$select api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'TR001PAY0002', 'TRXDDD444', '01712345678', 500)$$,
  '23505',
  'duplicate key value violates unique constraint "payment_sessions_one_completed_per_order"',
  'a second payment cannot settle an order that already settled'
);

-- The other half of double-crediting: one bKash transaction, two orders.
--
-- Its own link rather than the `other` slug already used above. That slug carries two
-- orders by now - one manual, one automated - and `order_for_customer` returns whichever
-- the planner reaches first, so naming the slug alone does not identify the order this
-- assertion is about. It happened to be harmless while every gateway behaved the same
-- way; once the automated one was given an environment of its own, the ambiguity turned
-- into a test that could be asserting against the wrong row.
select test_data.link('otherpgw', 500, false);
select test_data.pgw_order('otherpgw') as other_order;
select api.bkash_record_session(test_data.order_for_customer('otherpgw'), 'TR001PAY0003', 500);
select throws_ok(
  $$select api.bkash_settle_order(
      test_data.order_for_customer('otherpgw'), 'TR001PAY0003', 'TRXAAA111', '01712345678', 500)$$,
  '23505',
  'duplicate key value violates unique constraint "payment_sessions_trx_unique"',
  'the same TrxID cannot settle a second order'
);

-- ---------------------------------------------------------------------------
-- Refusals that are not about money
-- ---------------------------------------------------------------------------

select test_data.pgw_order('paid') as paid_2;
select api.bkash_record_session(test_data.order_for_customer('paid'), 'TR001PAY0004', 500);

select throws_ok(
  $$select api.bkash_settle_order(
      test_data.order_for_customer('paid'), 'TR001PAY0001', 'TRXEEE555', '01712345678', 500)$$,
  '22023',
  'payment belongs to a different order',
  'a payment belonging to another order cannot settle this one'
);

-- Not asserted here as a call: `test_data.as_user` sets JWT claims but leaves the
-- database role as `postgres`, so a function granted only to `service_role` still runs
-- and would quietly settle the order. What the customer cannot do is execute it, and
-- that is asserted against the grant above rather than through a call that the harness
-- would let through.
select test_data.as_service();
select lives_ok(
  $$select api.bkash_fail_session(
      test_data.order_for_customer('paid'), 'TR001PAY0004', 'wrong pin')$$,
  'and the worker can record a failed attempt'
);

select is(
  (select s.status from public.payment_sessions s where s.provider_payment_id = 'TR001PAY0004'),
  'failed',
  'which is visible to staff afterwards'
);

-- ---------------------------------------------------------------------------
-- Token cache and the two-calls-an-hour budget
-- ---------------------------------------------------------------------------

select test_data.as_service();

select throws_ok(
  $$select api.bkash_token_state((select id from private.secret_bundles limit 1), 'production')$$,
  '22023',
  'unknown bkash environment: production',
  'an unknown environment is refused'
);

select is(
  (api.bkash_token_state((select id from private.secret_bundles limit 1), 'sandbox')) ->> 'bootstrap',
  'true',
  'with no token cached, the caller is told to bootstrap with Grant Token'
);

select is(
  (api.bkash_token_state((select id from private.secret_bundles limit 1), 'sandbox')) ->> 'usable',
  'false',
  'and that there is nothing usable yet'
);

-- The whole reason the token is cached in the database: two checkouts arriving together
-- must produce one API call, not two. Grant and Refresh share a two-per-hour budget and
-- going over blocks refresh for an hour, which means the shop stops taking payments.
select is(
  (api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'sandbox')),
  true,
  'the first caller wins the refresh lease'
);

select is(
  (api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'sandbox')),
  false,
  'a second caller does not'
);

select is(
  (api.bkash_token_state((select id from private.secret_bundles limit 1), 'sandbox')) ->> 'refreshing',
  'true',
  'and the lease is visible while it is held'
);

select lives_ok(
  $$select api.bkash_store_token((select id from private.secret_bundles limit 1), 'sandbox', 'id-token-value', 'refresh-token-value', 3600)$$,
  'the winner stores what it fetched'
);

select is(
  (api.bkash_token_state((select id from private.secret_bundles limit 1), 'sandbox')) ->> 'id_token',
  'id-token-value',
  'the cached token is served to the next caller'
);

select is(
  (api.bkash_token_state((select id from private.secret_bundles limit 1), 'sandbox')) ->> 'needs_refresh',
  'false',
  'a fresh token is not refreshed again'
);

select is(
  (api.bkash_token_state((select id from private.secret_bundles limit 1), 'sandbox')) ->> 'refreshing',
  'false',
  'storing releases the lease'
);

-- Refreshing is per environment, so a sandbox burst cannot spend the live budget.
select is(
  (api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'live')),
  true,
  'the live environment has its own lease'
);

select is(
  (api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'sandbox')),
  true,
  'and the sandbox lease is free again'
);

select throws_ok(
  $$select api.bkash_store_token((select id from private.secret_bundles limit 1), 'sandbox', '', 'refresh-token-value', 3600)$$,
  '22023',
  'bkash returned an empty token',
  'an empty token is not cached'
);

-- ---------------------------------------------------------------------------
-- What staff can see
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.customer_of('paid'));
select throws_ok(
  $$select api.admin_order_payments(test_data.order_for_customer('paid'))$$,
  '42501',
  'forbidden',
  'a customer cannot read the payment trail'
);

select test_data.as_user(test_data.new_staff());
select is(
  (select jsonb_array_length(
    (api.admin_order_payments(test_data.order_for_customer('auto'))) -> 'payments')),
  2,
  'staff can see every attempt against the order'
);

select is(
  (select (api.admin_order_payments(test_data.order_for_customer('auto')))
     #>> '{payments,0,trx_id}'),
  'TRXAAA111',
  'including the TrxID, which is how a dispute gets answered'
);
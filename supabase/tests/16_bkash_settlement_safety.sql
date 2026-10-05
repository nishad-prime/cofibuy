-- bKash settlement safety.
--
-- The three guarantees in `20261005020000_bkash_settlement_safety.sql`, asserted directly.
--
-- This file exists because the previous one could not express the most important claim in
-- the system. `11_bkash.sql` settles money, which meant its fixture had to be a live
-- gateway, which meant there was nowhere in the suite that a sandbox gateway could be
-- watched *failing* to settle. The interesting behaviour was the refusal, and the only way
-- to test a refusal is to have a gateway that triggers it.
--
-- The invariants, in the order they matter:
--
--   1. A sandbox payment settles nothing at all. Not "settles and is reversible" - the
--      session stays initiated, the order stays awaiting_proof, and no access grant exists.
--      Each of those is asserted separately, because "the order is not approved" alone
--      would still pass if the guard had fired halfway through.
--   2. A credential stored with a stray space authenticates as the credential it was meant
--      to be, and a shop that saved before trimming is repaired rather than left broken.
--   3. The token lease can be released, and the refresh token is reachable by the only
--      caller allowed to reach it.

select plan(47);

select test_data.reset();

select test_data.link('auto', 500, false);
select test_data.gateway('bkash');

-- A sandbox merchant: the gateway a shop runs while wiring the integration up.
select test_data.pgw_gateway(true, 'bkash_instant', 'sandbox') as sandbox_gateway;

select test_data.as_user(test_data.owner());
select api.admin_upsert_gateway(
  jsonb_build_object(
    'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
    'kind', 'bkash_instant', 'provider', 'bkash_pgw', 'name_en', 'bKash (sandbox)',
    'environment', 'sandbox',
    'credential_bundle', jsonb_build_object(
      'app_key', 'fixture-app-key', 'app_secret', 'fixture-app-secret',
      'username', 'fixture-username', 'password', 'fixture-password'))
);
select test_data.as_service();

select test_data.pgw_order('auto') as sandbox_order;
select test_data.as_user(test_data.customer_of('auto'));

-- ---------------------------------------------------------------------------
-- A sandbox payment can be started
-- ---------------------------------------------------------------------------

-- Starting one is not the dangerous half. The customer reaches bKash, which is how the
-- credential plumbing and the redirect are proven against a sandbox merchant without
-- money moving. Refusing here would mean the integration could never be tested at all.
select lives_ok(
  $$select api.bkash_payment_start(test_data.order_for_customer('auto'))$$,
  'a sandbox gateway still starts a payment'
);

select is(
  (select api.bkash_payment_start(test_data.order_for_customer('auto')) ->> 'sandbox'),
  'true',
  'and says so, so the frontend can label it a test payment'
);

select is(
  (select api.bkash_payment_start(test_data.order_for_customer('auto')) ->> 'environment'),
  'sandbox',
  'the environment travels with the answer rather than being looked up again'
);

select is(
  (select api.bkash_payment_start(test_data.order_for_customer('auto')) ->> 'gateway_id'),
  (select id::text from public.payment_gateways where provider = 'bkash_pgw' limit 1),
  'alongside the gateway to take credentials from'
);

select test_data.as_service();
select lives_ok(
  $$select api.bkash_record_session(test_data.order_for_customer('auto'), 'SANDBOXPAY01', 500)$$,
  'the worker records the sandbox session'
);

-- ---------------------------------------------------------------------------
-- ... and settles nothing
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'SANDBOXPAY01', 'SANDBOXTRX1', '01712345678', 500)$$,
  '22023',
  'sandbox gateways cannot settle an order: bkash reported success for a payment it did not charge, so approving it would grant access for no money. Set the gateway to live to settle.',
  'a sandbox payment is refused, by name'
);

-- The part that actually matters. A refusal that had already written something would look
-- identical from the caller: the same exception, the same body, the same order status.
-- What it would not look like is a customer who paid a real bKash PIN, was told the payment
-- failed, and has an `access_grant` row saying it worked.
select is(
  (select status::text from public.payment_sessions where provider_payment_id = 'SANDBOXPAY01'),
  'initiated',
  'the session was never marked completed'
);

select is(
  (select status::text from public.orders where id = test_data.order_for_customer('auto')),
  'awaiting_proof',
  'the order was never approved'
);

select is(
  (select count(*) from public.access_grants
    where link_id = (select link_id from public.orders
                      where id = test_data.order_for_customer('auto'))),
  0,
  'and no access was granted'
);

-- The `orders` row is untouched, not merely left in the same status by a compensating
-- write. `reviewed_at` moving is the tell: it is set in the same statement that approves,
-- so if the guard had fired after the lock rather than before it, this would be non-null
-- with the status rolled back on top.
select is(
  (select reviewed_at is null from public.orders
     where id = test_data.order_for_customer('auto')),
  true,
  'and the approval statement never ran'
);

select is(
  (select count(*) from public.payment_sessions where provider_payment_id = 'SANDBOXPAY01'
     and (executed_at is not null or provider_trx_id is not null)),
  0,
  'no trx id was recorded against a payment we refused'
);

-- The refusal is not a one-shot: bKash may be called again for the same payment, and a
-- guard that allowed the second attempt would be no guard at all.
select throws_ok(
  $$select api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'SANDBOXPAY01', 'SANDBOXTRX2', '01712345678', 500)$$,
  '22023',
  'sandbox gateways cannot settle an order: bkash reported success for a payment it did not charge, so approving it would grant access for no money. Set the gateway to live to settle.',
  'and it refuses every time'
);

-- The same payment id, on a live gateway, still settles. Proves the guard is about the
-- environment rather than about the payment, and that it is not simply refusing everything.
select test_data.as_user(test_data.owner());
select api.admin_upsert_gateway(
  jsonb_build_object(
    'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
    'kind', 'bkash_instant', 'provider', 'bkash_pgw', 'name_en', 'bKash (sandbox)',
    'environment', 'live',
    'credential_bundle', jsonb_build_object(
      'app_key', 'fixture-app-key', 'app_secret', 'fixture-app-secret',
      'username', 'fixture-username', 'password', 'fixture-password'))
);
select test_data.as_service();

select is(
  (select (api.bkash_settle_order(
      test_data.order_for_customer('auto'), 'SANDBOXPAY01', 'LIVETRX1', '01712345678', 500))
     ->> 'ok'),
  'true',
  'the same payment settles once the gateway is live'
);

select is(
  (select status::text from public.orders where id = test_data.order_for_customer('auto')),
  'approved',
  'and the order is approved'
);

select is(
  (select count(*) from public.access_grants
    where link_id = (select link_id from public.orders
                      where id = test_data.order_for_customer('auto'))),
  1,
  'with exactly one access grant'
);

select is(
  (select reviewed_by::text is null from public.orders
     where id = test_data.order_for_customer('auto')),
  true,
  'and no reviewer, because nobody at the shop clicked approve'
);

-- ---------------------------------------------------------------------------
-- Authorising the execute step
-- ---------------------------------------------------------------------------

select test_data.link('second', 500, false);
select test_data.pgw_order('second') as second_order;

-- A session has to exist before there is anything to claim. `record_session` is
-- service_role only, which is why the harness has to step out of the customer's shoes to
-- write one and back in to ask for it.
select test_data.as_service();
select lives_ok(
  $$select api.bkash_record_session(test_data.order_for_customer('second'), 'SECONDPAY01', 500)$$,
  'the worker records a session for the second order'
);
select test_data.as_user(test_data.customer_of('second'));

select lives_ok(
  $$select api.bkash_payment_claim(
      test_data.order_for_customer('second'), 'SECONDPAY01')$$,
  'the customer may claim their own pending payment'
);

select is(
  (select api.bkash_payment_claim(
      test_data.order_for_customer('second'), 'SECONDPAY01') ->> 'already_settled'),
  'false',
  'which is not already settled'
);

select throws_ok(
  $$select api.bkash_payment_claim(
      test_data.order_for_customer('second'), 'NOSUCHPAY01')$$,
  'P0002',
  'no payment session for NOSUCHPAY01',
  'a payment id with no session is refused'
);

select throws_ok(
  $$select api.bkash_payment_claim(
      test_data.order_for_customer('second'), '   ')$$,
  '22023',
  'no payment id',
  'and so is a blank one'
);

-- The boundary that matters, and it is worth being precise about which boundary is which.
-- Here the order is the caller's own; only the payment id belongs elsewhere. The claim
-- scopes its session lookup to the order, so a real payment id paired with the wrong order
-- does not match. Without that scoping a caller could hold a payment they paid for and
-- point it at an order of their choosing.
select throws_ok(
  $$select api.bkash_payment_claim(
      test_data.order_for_customer('second'), 'SANDBOXPAY01')$$,
  'P0002',
  'no payment session for SANDBOXPAY01',
  'a payment id belonging to another order does not match'
);

-- The other boundary: a real payment id, against an order that is not the caller's. The
-- order lookup fails first, and it fails identically for an order that does not exist at
-- all, because telling a stranger that an id is real is itself the leak.
select test_data.as_user(test_data.customer_of('second'));
select throws_ok(
  $$select api.bkash_payment_claim(
      test_data.order_for_customer('auto'), 'SANDBOXPAY01')$$,
  'P0002',
  'order not found',
  'another customers order cannot be claimed at all'
);

select is(
  test_data.as_role('anon', $$select api.bkash_payment_claim('00000000-0000-0000-0000-000000000000', 'x')$$)
    ->> 'state',
  '42501',
  'an anonymous caller cannot claim anything'
);

-- An already-settled payment answers rather than raising, because the return page is
-- reloaded on refresh and the customer should land on the unlocked order. The execute
-- function reads this and skips bKash, which matters because a payment id may be executed
-- exactly once and a second execute is worse than a wasted request.
select test_data.as_user(test_data.customer_of('auto'));
select is(
  (select api.bkash_payment_claim(
      test_data.order_for_customer('auto'), 'SANDBOXPAY01') ->> 'already_settled'),
  'true',
  'a settled payment reports itself as settled'
);

select is(
  (select api.bkash_payment_claim(
      test_data.order_for_customer('auto'), 'SANDBOXPAY01') ->> 'status'),
  'approved',
  'with the order status attached'
);

-- ---------------------------------------------------------------------------
-- Credentials are stored trimmed
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('auto', 500, false);
select test_data.pgw_gateway(true, 'bkash_instant', 'sandbox') as creds_gateway;
select test_data.as_user(test_data.owner());

select lives_ok(
  $$select private.store_credential_bundle(
      (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
      'bkash_pgw',
      jsonb_build_object(
        'username', '  user-name  ', 'password', '\tpass word\n',
        'app_key', ' app-key ', 'app_secret', 'app-secret '))$$,
  'credentials pasted with surrounding whitespace are accepted'
);

select is(
  (select d.secret ->> 'username'
     from private.secret_bundles b
     join vault.decrypted_secrets d on d.id = b.vault_secret_id
    where b.subject_id = (select id from public.payment_gateways
                            where provider = 'bkash_pgw' limit 1)),
  'user-name',
  'and stored without the leading space'
);

select is(
  (select d.secret ->> 'app_secret'
     from private.secret_bundles b
     join vault.decrypted_secrets d on d.id = b.vault_secret_id
    where b.subject_id = (select id from public.payment_gateways
                            where provider = 'bkash_pgw' limit 1)),
  'app-secret',
  'and without the trailing one'
);

-- A value that is only whitespace is still blank. The check has to survive the trim, or a
-- secret of `'   '` passes as present and fails later as an opaque 401.
select throws_ok(
  $$select private.store_credential_bundle(
      (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
      'bkash_pgw', jsonb_build_object('username', '   ', 'password', 'p',
        'app_key', 'k', 'app_secret', 's'))$$,
  '22023',
  'credential username cannot be blank',
  'a whitespace-only credential is still blank'
);

select throws_ok(
  $$select private.store_credential_bundle(
      (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
      'bkash_pgw', jsonb_build_object('username', 42, 'password', 'p',
        'app_key', 'k', 'app_secret', 's'))$$,
  '22023',
  'credential username must be a string',
  'and a non-string credential is refused rather than stringified'
);

-- A partial save merges, and the values it does not mention keep their stored form. This
-- is the path that rotates one secret: bKash's `app_secret` changes and the other three
-- must survive.
select lives_ok(
  $$select private.store_credential_bundle(
      (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
      'bkash_pgw', jsonb_build_object('app_secret', 'rotated-secret'))$$,
  'a partial save is a rotation'
);

select is(
  (select d.secret ->> 'app_secret'
     from private.secret_bundles b
     join vault.decrypted_secrets d on d.id = b.vault_secret_id
    where b.subject_id = (select id from public.payment_gateways
                            where provider = 'bkash_pgw' limit 1)),
  'rotated-secret',
  'and the rotated value is what is stored'
);

select is(
  (select d.secret ->> 'username'
     from private.secret_bundles b
     join vault.decrypted_secrets d on d.id = b.vault_secret_id
    where b.subject_id = (select id from public.payment_gateways
                            where provider = 'bkash_pgw' limit 1)),
  'user-name',
  'while the untouched credentials are left alone'
);

select is(
  (select count(*) from private.secret_bundles
    where subject_id = (select id from public.payment_gateways
                         where provider = 'bkash_pgw' limit 1)),
  1,
  'and it is still one bundle, not a second one'
);

-- ---------------------------------------------------------------------------
-- The token lease
-- ---------------------------------------------------------------------------

select test_data.as_service();

select is(
  (select api.bkash_token_state(
      (select id from private.secret_bundles limit 1), 'sandbox') ->> 'bootstrap'),
  'true',
  'a bundle with no token must bootstrap rather than refresh'
);

select is(
  api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'sandbox'),
  true,
  'and the first caller wins the lease'
);

select is(
  api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'sandbox'),
  false,
  'the second caller does not'
);

select is(
  (select api.bkash_token_state(
      (select id from private.secret_bundles limit 1), 'sandbox') ->> 'refreshing'),
  'true',
  'which is reported, so a loser waits instead of calling bKash'
);

-- The release is what stops one failure from costing every checkout a minute, for as long
-- as the credentials stay wrong.
select lives_ok(
  $$select api.bkash_release_refresh((select id from private.secret_bundles limit 1), 'sandbox')$$,
  'a failed refresh can release its lease'
);

select is(
  api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'sandbox'),
  true,
  'and the next caller gets it'
);

-- Refresh is per bundle *and* per environment. Two gateways on one merchant account share
-- a bundle but not a budget only if the environment differs; a live burst must not spend
-- the sandbox allowance and vice versa.
select is(
  api.bkash_claim_refresh((select id from private.secret_bundles limit 1), 'live'),
  true,
  'the live environment has its own lease'
);

select lives_ok(
  $$select api.bkash_store_token(
      (select id from private.secret_bundles limit 1), 'sandbox',
      'id-token-value', 'refresh-token-value', 3600)$$,
  'the winner stores the token it minted'
);

-- Without this the refresh path is unreachable: a caller holding a token that needs
-- rotating has no legal move but to grant a fresh one, which spends one of the two calls
-- allowed per hour and invalidates a token other in-flight requests are still holding.
select is(
  (select api.bkash_token_state(
      (select id from private.secret_bundles limit 1), 'sandbox') ->> 'refresh_token'),
  'refresh-token-value',
  'and the refresh token is reachable by the caller that holds the lease'
);

select is(
  test_data.as_role('authenticated', $$select api.bkash_token_state(
      (select id from private.secret_bundles limit 1), 'sandbox')$$) ->> 'state',
  '42501',
  'but a signed-in customer still cannot read a merchant token'
);

select is(
  test_data.as_role('anon', $$select api.bkash_token_state(
      (select id from private.secret_bundles limit 1), 'sandbox')$$) ->> 'state',
  '42501',
  'nor an anonymous one'
);

select throws_ok(
  $$select api.bkash_release_refresh(
      (select id from private.secret_bundles limit 1), 'production')$$,
  '22023',
  'unknown bkash environment: production',
  'an unknown environment is refused'
);

select * from finish();

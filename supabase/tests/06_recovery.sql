-- 06_recovery.sql
--
-- A customer who paid with a phone number can get back in with a code sent to
-- that number on Telegram. The worker that sends it lives in another repository
-- and holds a service key; everything here is the database half of that
-- arrangement.
--
-- The shape of it is driven by one rule: a wrong guess must be indistinguishable
-- from a right guess made against a phone that never paid. Otherwise the form
-- becomes a way to ask the database which numbers are customers.

set client_min_messages = warning;
set application_name = 'test-06-recovery';

select plan(53);

-- ---------------------------------------------------------------------------
-- Asking for a code
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.enable_recovery();
select test_data.new_subject();
select test_data.as_subject('a');

select is(
  (api.request_recovery('01712345678') ->> 'ok'),
  'true',
  'a signed-in customer can ask for a code'
);

-- The response is the same whatever the number. A form that says "no purchases
-- found" is a form that lists your customers to whoever asks.
select is(
  (api.request_recovery('01799999999') ->> 'ok'),
  'true',
  'and a number that has never paid gets the same answer'
);

select is(
  (api.request_recovery('01712345678') ->> 'request_id') is null,
  false,
  'and is handed a request to wait on'
);

-- Stored normalised. 017 and +880 are the same number, and recovery only works
-- if the one in the form is the one that was captured with the payment.
select api.request_recovery('+8801755555555');
select is(
  (select phone_e164 from public.recovery_requests where phone_e164 = '+8801755555555'),
  '+8801755555555',
  'stored normalised, so 017 and +880 are the same number'
);

select throws_ok(
  $$select api.request_recovery('not a number')$$,
  '22023',
  'that is not a valid Bangladeshi mobile number',
  'a number that is not one is refused'
);

select test_data.as_anon();
select throws_ok(
  $$select api.request_recovery('01712345678')$$,
  '42501',
  'authentication required',
  'and somebody not signed in cannot ask'
);

select test_data.as_subject('a');
select is(
  (api.recover_access('01712345678', '482913') ->> 'ok'),
  'false',
  'and a code for a number with no orders grants nothing'
);

-- Five a hour. Past that the answer stops being a yes or a no, because enough
-- wrong codes stop meaning anything.
select test_data.as_subject('a');
select api.request_recovery('01711111111');
select api.request_recovery('01711111111');
select api.request_recovery('01711111111');
select api.request_recovery('01711111111');
select is(
  (api.request_recovery('01711111111') ->> 'ok')::text,
  'true',
  'a number can be asked five times an hour'
);

select throws_ok(
  $$select api.request_recovery('01711111111')$$,
  '22023',
  'too many recovery requests, please try again later',
  'and a sixth is refused'
);

-- The limit is per number, not per account. Otherwise a signed-in customer
-- could walk through a list of numbers, one request each.
select is(
  (api.request_recovery('01722222222') ->> 'ok')::text,
  'true',
  'a different number is unaffected'
);

-- ---------------------------------------------------------------------------
-- The worker picks it up
-- ---------------------------------------------------------------------------

select test_data.as_service();

-- A customer must not be able to reach the worker surface. With a service key
-- in hand, these three functions are all the recovery data anything can reach.
-- The grant, not the guard. Claiming reads other people's phone numbers, so
-- this has to be a permission rather than a check that only one role passes.
select is(
  test_data.can_execute('authenticated', 'api.claim_pending_recovery(integer)'),
  false,
  'a customer cannot reach the worker claim function'
);

select is(
  test_data.can_execute('anon', 'api.claim_pending_recovery(integer)'),
  false,
  'and neither can the public'
);

select is(
  test_data.can_execute('service_role', 'api.claim_pending_recovery(integer)'),
  true,
  'but the worker holding a service key can'
);

select test_data.as_service();
select is(
  (select count(*) from api.claim_pending_recovery(10)),
  10::bigint,
  'the worker claims everything pending'
);

-- Claiming marks the row sent, so a request in flight is not handed out twice.
select is(
  (select count(*) from public.recovery_requests where status = 'sent'),
  10,
  'and the claim is recorded on the row'
);

select is(
  (select count(*) from api.claim_pending_recovery(10)),
  0::bigint,
  'a second poll finds nothing left to claim'
);

select test_data.as_service();
select is(
  (api.record_otp_sent(
    -- `now()` is the transaction time, so every row in a test shares a created_at
  -- and ordering by it is a coin toss. Status is what actually distinguishes them.
  (select id from public.recovery_requests where phone_e164 = '+8801712345678' and status = 'sent' limit 1),
    test_data.otp_hash('482913')
  ) ->> 'ok'),
  'true',
  'the worker records the code it sent'
);

-- The code itself is never written down. A dump of this table is a list of
-- hashes, which buys an attacker nothing against a live code.
select is(
  (select count(*) from public.otp_challenges where otp_hash like '%482913%'),
  0,
  'and the raw code is not in the database'
);

select is(
  (select count(*) from public.otp_challenges),
  1,
  'while the hash is'
);

select throws_ok(
  $$select api.record_otp_sent(
      (select id from public.recovery_requests where phone_e164 = '+88099999999'),
      test_data.otp_hash('482913'))$$,
  '22023',
  'request is not awaiting a code',
  'a code cannot be recorded against a request that was never claimed'
);

-- ---------------------------------------------------------------------------
-- Using the code
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.enable_recovery();
select test_data.new_subject('payer');
select test_data.as_subject('payer');
select test_data.orders('guide', 'bKash', 750, 'payer') ->> 'ok';
select test_data.submit(test_data.subject_id('payer'), (test_data.subject_order('payer')).id) ->> 'ok';
select test_data.reviewer();
select test_data.as_subject('staff');
select is(
  (api.approve_order((test_data.subject_order('payer')).id) ->> 'ok'),
  'true',
  'an order is paid for with 01712345678'
);

-- Somebody else, on a new session, holding only the phone number.
select test_data.new_subject();
select test_data.as_subject('a');
select is(
  (api.request_recovery('01712345678') ->> 'ok'),
  'true',
  'a new session asks to recover that number'
);

select test_data.as_service();
select api.claim_pending_recovery(1);
select api.record_otp_sent(
  (select id from public.recovery_requests where phone_e164 = '+8801712345678'),
  test_data.otp_hash('482913')
);

select test_data.as_subject('a');
select is(
  (api.recover_access('01712345678', '000000') ->> 'ok'),
  'false',
  'a wrong code is refused'
);

-- The counter has to survive the refusal. A limit that is rolled back by the
-- very raise that reports it would let a leaked code be guessed at for ever.
select is(
  (select attempt_count from public.otp_challenges),
  1,
  'and the attempt is counted'
);

select is(
  (api.recover_access('01712345678', '482913') ->> 'ok'),
  'true',
  'and the right one works'
);

-- One code, one use. A code that kept working would stay useful to anyone who
-- ever saw it, which is the whole reason it is sent to a phone at all.
select is(
  (api.recover_access('01712345678', '482913') ->> 'ok'),
  'false',
  'and the same code cannot be used a second time'
);

-- A number that has never paid, and a wrong code for one that has: the response
-- has to be the same object, or the form is a way to ask which numbers are
-- customers.
select is(
  api.recover_access('01799999999', '000000'),
  api.recover_access('01712345678', '000000'),
  'a number that never paid is refused exactly as a wrong code is'
);

select is(
  (select count(*) from public.access_grants where user_id = test_data.subject_id('a')),
  1::bigint,
  'and is given nothing'
);

-- ---------------------------------------------------------------------------
-- What recovery gives back
-- ---------------------------------------------------------------------------

select is(
  (api.get_unlocked_page('guide') ->> 'slug'),
  'guide',
  'the recovered session opens the paid body'
);

select is(
  (select count(*) from api.my_grants()),
  1::bigint,
  'with one grant, not one per order'
);

-- A second code for the same number, as if they came back tomorrow.
select test_data.as_service();
select test_data.as_subject('a');
select api.request_recovery('01712345678');
select test_data.as_service();
select api.claim_pending_recovery(1);
select api.record_otp_sent(
  -- `now()` is the transaction time, so every row in a test shares a created_at
  -- and ordering by it is a coin toss. Status is what actually distinguishes them.
  (select id from public.recovery_requests where phone_e164 = '+8801712345678' and status = 'sent' limit 1),
  test_data.otp_hash('654321')
);

select test_data.as_subject('a');
select is(
  (api.recover_access('01712345678', '654321') ->> 'ok'),
  'true',
  'verifying again later works'
);

select is(
  (select count(*) from public.access_grants where user_id = test_data.subject_id('a')),
  1,
  'and does not stack a second grant for the same link'
);

select is(
  (select count(*) from public.customer_contacts where user_id = test_data.subject_id('a')),
  1,
  'and records the phone as a contact for the session that proved it'
);

-- ---------------------------------------------------------------------------
-- Running out of guesses
-- ---------------------------------------------------------------------------

select test_data.as_subject('a');
select api.request_recovery('01712345678');
select test_data.as_service();
select api.claim_pending_recovery(1);
select api.record_otp_sent(
  -- `now()` is the transaction time, so every row in a test shares a created_at
  -- and ordering by it is a coin toss. Status is what actually distinguishes them.
  (select id from public.recovery_requests where phone_e164 = '+8801712345678' and status = 'sent' limit 1),
  test_data.otp_hash('111111')
);

select test_data.as_subject('a');
select is(
  (api.recover_access('01712345678', '222222') ->> 'ok'),
  'false',
  'the first guess is refused'
);
select is(
  (api.recover_access('01712345678', '333333') ->> 'ok'),
  'false',
  'the second guess is refused'
);
select is(
  (api.recover_access('01712345678', '444444') ->> 'ok'),
  'false',
  'the third guess is refused'
);
select is(
  (api.recover_access('01712345678', '555555') ->> 'ok'),
  'false',
  'the fourth guess is refused'
);

-- Five guesses, and then the code they were guessing for is worthless too.
-- Otherwise an attacker who got hold of a code would have as long as they liked
-- to try every other one against it.
select is(
  (api.recover_access('01712345678', '666666') ->> 'ok'),
  'false',
  'the fifth is refused'
);

select is(
  (api.recover_access('01712345678', '111111') ->> 'ok'),
  'false',
  'and the right code is refused once the guesses are spent'
);

select is(
  (select count(*) from public.otp_challenges where consumed_at is null),
  0,
  'with the code spent'
);

select is(
  (select count(*) from public.recovery_requests where phone_e164 = '+8801712345678' and status = 'failed'),
  1::bigint,
  'and the request is marked failed'
);

-- ---------------------------------------------------------------------------
-- A resend replaces the code before it
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.enable_recovery();
select test_data.new_subject();
select test_data.as_subject('a');
select api.request_recovery('01712345678');

select test_data.as_service();
select api.claim_pending_recovery(1);
select api.record_otp_sent(
  (select id from public.recovery_requests where status = 'sent' limit 1),
  test_data.otp_hash('111111')
);

-- The customer asks again because the first message never arrived.
select test_data.as_subject('a');
select api.request_recovery('01712345678');
select test_data.as_service();
select api.claim_pending_recovery(1);
select api.record_otp_sent(
  (select id from public.recovery_requests where status = 'sent' order by sent_at desc nulls last, id limit 1),
  test_data.otp_hash('222222')
);

select is(
  (select count(*) from public.otp_challenges where consumed_at is null),
  1,
  'two codes sent, one still live'
);

select test_data.as_subject('a');
select is(
  (api.recover_access('01712345678', '111111') ->> 'ok'),
  'false',
  'the first code is dead once a second is sent'
);

select is(
  (api.recover_access('01712345678', '222222') ->> 'ok'),
  'true',
  'and only the second one works'
);

-- ---------------------------------------------------------------------------
-- When Telegram cannot reach the number
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.enable_recovery();
select test_data.new_subject();
select test_data.as_subject('a');
select api.request_recovery('01712345678');
select test_data.as_service();
select api.claim_pending_recovery(1);

select is(
  (api.mark_undeliverable(
    (select id from public.recovery_requests where status = 'sent' limit 1),
    'no such telegram account'
  ) ->> 'ok'),
  'true',
  'the worker records that the number has no reachable chat'
);

-- Said out loud rather than left hanging. Waiting for a message that cannot
-- arrive is worse than being told it will not.
select is(
  (select status from public.recovery_requests limit 1),
  'undeliverable'::public.recovery_status,
  'and the request says so'
);

select is(
  (select count(*) from public.audit_log where action = 'recovery.undeliverable'),
  1,
  'with an audit entry, so the reason is on record'
);

select throws_ok(
  $$select api.mark_undeliverable((select id from public.recovery_requests limit 1))$$,
  '22023',
  'request is not awaiting delivery',
  'and it cannot be marked twice'
);

-- ---------------------------------------------------------------------------
-- A worker that dies mid-send
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.enable_recovery();
select test_data.new_subject();
select test_data.as_subject('a');
select api.request_recovery('01712345678');
select test_data.as_service();
select api.claim_pending_recovery(1);

-- Nothing is coming: the worker is gone. Left as `sent`, the request is
-- invisible to the next poll and the customer waits out the full fifteen
-- minutes for a code that was never sent.
select is(
  private.reap_stale_claims(),
  0,
  'a claim that was just made is left alone'
);

update public.recovery_requests
set sent_at = now() - interval '4 minutes'
where status = 'sent';

select is(
  private.reap_stale_claims(),
  1,
  'and an abandoned one is returned to the queue'
);

select is(
  (select count(*) from api.claim_pending_recovery(1)),
  1::bigint,
  'so the next poll picks it up again'
);

-- ---------------------------------------------------------------------------
-- Off by default
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.new_subject();
select test_data.as_subject('a');
select throws_ok(
  $$select api.request_recovery('01712345678')$$,
  '22023',
  'account recovery is not available',
  'recovery is off until it is turned on'
);

select throws_ok(
  $$select api.recover_access('01712345678', '482913')$$,
  '22023',
  'account recovery is not available',
  'and verifying is off with it'
);

select * from finish();

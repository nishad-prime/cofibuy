-- 08_housekeeping.sql
--
-- The sweeps. Nothing here is visible to a customer, and that is the point:
-- a paywall that quietly cleans up after itself is a paywall nobody has to
-- think about running.
--
-- Two of these are about money that has not arrived. An abandoned order must
-- not sit in the queue forever, and a customer whose order expired simply
-- starts again, with the terms snapshotted afresh on the new one.

set client_min_messages = warning;
set application_name = 'test-08-housekeeping';

select plan(25);

-- ---------------------------------------------------------------------------
-- An order nobody finished
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.as_subject('a');
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';

select is(
  private.sweep() ->> 'expired_orders',
  '0',
  'a fresh order is left alone'
);

update public.orders set expires_at = now() - interval '1 minute';

select is(
  (select status from public.orders limit 1),
  'awaiting_proof'::public.order_status,
  'and stays put until it is actually late'
);

select is(
  private.sweep() ->> 'expired_orders',
  '1',
  'a lapsed order is expired'
);

select is(
  (select status from public.orders limit 1),
  'expired'::public.order_status,
  'so it leaves the queue'
);

-- Running it again must not count the same row twice, or a dashboard of
-- "expired today" would drift by however often the cron fires.
select is(
  private.sweep() ->> 'expired_orders',
  '0',
  'and expiring twice counts once'
);

-- ---------------------------------------------------------------------------
-- A locked order expires too
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.as_subject('a');
select test_data.orders('guide', 'bKash', 400, 'a') ->> 'code';
select test_data.orders('guide', 'bKash', 400, 'a') ->> 'code';
select test_data.orders('guide', 'bKash', 400, 'a') ->> 'code';
select test_data.orders('guide', 'bKash', 400, 'a') ->> 'code';
select test_data.orders('guide', 'bKash', 400, 'a') ->> 'code';
select test_data.orders('guide', 'bKash', 400, 'a') ->> 'ok';

select is(
  (select status from public.orders limit 1),
  'locked'::public.order_status,
  'six guesses lock the order'
);

-- A lock only an admin can clear is a dead end for somebody who mistyped an
-- amount, and the minimum is protected by never being disclosed rather than by
-- this. So the lock expires on its own.
update public.orders set expires_at = now() - interval '1 minute';

select is(
  private.sweep() ->> 'expired_orders',
  '1',
  'a lock lapses with everything else'
);

-- ---------------------------------------------------------------------------
-- An order that was already decided is left as it is
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.as_subject('a');
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';
select test_data.submit(test_data.subject_id('a'), (test_data.subject_order()).id) ->> 'ok';
select test_data.reviewer();
select test_data.as_subject('staff');
select is(
  (api.approve_order((test_data.subject_order()).id) ->> 'ok'),
  'true',
  'an order is approved'
);

update public.orders set expires_at = now() - interval '1 day';

select is(
  private.sweep() ->> 'expired_orders',
  '0',
  'an approved order is never expired by the sweep'
);

select is(
  (select status from public.orders limit 1),
  'approved'::public.order_status,
  'and the grant it carries is still live'
);

select is(
  (select count(*) from public.access_grants where revoked_at is null),
  1::bigint,
  'with the access it paid for'
);

-- ---------------------------------------------------------------------------
-- Recovery requests left hanging
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
  test_data.otp_hash('482913')
);

select is(
  (private.sweep() ->> 'reaped_claims')::int,
  0,
  'and the sweep does not inadvertently reap it'
);

select is(
  (select status from public.recovery_requests limit 1),
  'sent'::public.recovery_status,
  'a recovery request that was never used is still in flight'
);

select is(
  (select count(*) from public.otp_challenges where consumed_at is null),
  1::bigint,
  'and its code is still live'
);

update public.recovery_requests set expires_at = now() - interval '1 minute';

select private.sweep();

select is(
  (select status from public.recovery_requests limit 1),
  'expired'::public.recovery_status,
  'a recovery request that was never used is expired'
);

-- ---------------------------------------------------------------------------
-- Accounts that were never accounts
-- ---------------------------------------------------------------------------

-- A visitor who opened the paywall, got as far as a draft, and closed the tab.
-- Their row is deleted, and anything that hung off it goes with them.
select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.as_subject('a');
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';
select test_data.new_subject('stray');

select is(
  private.prune_anonymous_users(),
  0,
  'nobody is pruned the week they signed up'
);

-- Aged individually, because `reset()` clears the app tables and not
-- auth.users: every account this file made earlier is still sitting there.
update auth.users set created_at = now() - interval '8 days'
where id = test_data.subject_id('stray');

select is(
  private.prune_anonymous_users(),
  1,
  'but an account that never became a customer goes'
);

select is(
  (select count(*) from auth.users where id = test_data.subject_id('stray')),
  0::bigint,
  'and is gone'
);

select is(
  (select count(*) from auth.users where id = test_data.subject_id('a')),
  1::bigint,
  'while a customer with an order is kept'
);

-- A grant is as good a reason to keep somebody as an order: they paid, and
-- deleting the account would take the thing they paid for with it.
select test_data.new_subject('granted');
insert into public.access_grants (user_id, link_id)
select test_data.subject_id('granted'), id from public.pages limit 1;

update auth.users set created_at = now() - interval '8 days'
where id in (test_data.subject_id('a'), test_data.subject_id('granted'));

select is(
  private.prune_anonymous_users(),
  0,
  'and so is somebody holding a grant'
);

-- Staff are not customers, but they are not anonymous either.
select test_data.new_subject('worker');
insert into public.staff (user_id, role)
values (test_data.subject_id('worker'), 'staff');

update auth.users set created_at = now() - interval '8 days'
where id = test_data.subject_id('worker');

select is(
  private.prune_anonymous_users(),
  0,
  'nor is a member of the team'
);

select is(
  private.prune_anonymous_users(),
  0,
  'and running it twice prunes nothing more'
);

-- ---------------------------------------------------------------------------
-- The sweeps are not for customers to run
-- ---------------------------------------------------------------------------

select test_data.as_subject('a');

select is(
  test_data.can_execute('authenticated', 'private.expire_stale_orders()'),
  false,
  'a customer cannot expire orders'
);

select is(
  test_data.can_execute('authenticated', 'private.prune_anonymous_users()'),
  false,
  'or delete accounts'
);

select is(
  test_data.can_execute('service_role', 'private.sweep()'),
  false,
  'and the recovery worker cannot either'
);

select * from finish();

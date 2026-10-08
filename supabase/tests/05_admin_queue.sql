-- 05_admin_queue.sql
--
-- The panel is the one surface that shows everything to somebody who is only
-- meant to see a queue. Two tiers exist so that handing the daily review to an
-- account cannot also hand it the ability to rewrite what a link costs.
--
-- The first section is the one that matters most: every function the panel
-- calls is checked with a customer, a service key, and a staff account held
-- against it, because a guard written once and copied is a guard that was
-- correct on the day it was copied.

set client_min_messages = warning;
set application_name = 'test-05-admin';

select plan(83);

-- ---------------------------------------------------------------------------
-- A customer is nobody
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.as_anon();

select throws_ok($$select api.admin_orders()$$, '42501', 'forbidden', 'a customer cannot list the queue');
select throws_ok(
  $$select api.admin_order_detail(gen_random_uuid())$$,
  '42501',
  'forbidden',
  'a customer cannot read an order detail'
);
select throws_ok(
  $$select api.admin_order_duplicate_trxids(gen_random_uuid())$$,
  '42501',
  'forbidden',
  'a customer cannot ask which orders share a TrxID'
);
select throws_ok($$select api.approve_order(gen_random_uuid())$$, '42501', 'forbidden', 'a customer cannot approve');
select throws_ok(
  $$select api.reject_order(gen_random_uuid(), 'because')$$,
  '42501',
  'forbidden',
  'a customer cannot reject'
);
select throws_ok(
  $$select api.admin_reset_probes(gen_random_uuid())$$,
  '42501',
  'forbidden',
  'a customer cannot reset a probe lock'
);
select throws_ok($$select api.admin_stats()$$, '42501', 'forbidden', 'a customer cannot read the counts');
select throws_ok($$select * from api.admin_pages()$$, '42501', 'forbidden', 'a customer cannot list links');
select throws_ok($$select * from api.admin_gateways()$$, '42501', 'forbidden', 'a customer cannot list gateways');
select throws_ok($$select * from api.admin_settings()$$, '42501', 'forbidden', 'a customer cannot read the settings');
select throws_ok($$select * from api.admin_team()$$, '42501', 'forbidden', 'a customer cannot list the team');

-- A service key is not staff. It is how the app reaches the database, not a
-- licence to walk the panel, and treating it as one would mean any leaked
-- server key reads the whole queue.
select test_data.as_service();
select throws_ok($$select api.admin_orders()$$, '42501', 'forbidden', 'a service key cannot list the queue');
select throws_ok($$select api.admin_stats()$$, '42501', 'forbidden', 'a service key cannot read the counts');

-- ---------------------------------------------------------------------------
-- Staff review the queue; only an owner configures the site
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.new_staff('staff'));

select is(
  (select count(*) from api.admin_orders()),
  0::bigint,
  'staff can list the queue'
);

select throws_ok($$select * from api.admin_pages()$$, '42501', 'forbidden', 'staff cannot list links');
select throws_ok($$select * from api.admin_settings()$$, '42501', 'forbidden', 'staff cannot read the settings');
select throws_ok($$select * from api.admin_team()$$, '42501', 'forbidden', 'staff cannot list the team');
select throws_ok(
  $$select api.admin_upsert_page('{"slug": "x", "title_en": "x", "title_bn": "x"}'::jsonb)$$,
  '42501',
  'forbidden',
  'staff cannot create a link'
);
select throws_ok(
  $$select api.admin_set_staff('someone@example.com', 'staff')$$,
  '42501',
  'forbidden',
  'staff cannot add to the team'
);

select test_data.as_user(test_data.new_staff('owner'));
select is(
  (select count(*) from api.admin_pages()),
  0::bigint,
  'an owner can list links'
);
select is(
  (select count(*) from api.admin_team() where role = 'owner'),
  1::bigint,
  'an owner can list the team and see who is on it'
);

-- ---------------------------------------------------------------------------
-- The queue as the reviewer sees it
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.as_anon();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';
select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id) ->> 'ok';

select test_data.as_user(test_data.new_staff('staff'));

select is(
  (select status from api.admin_orders() limit 1),
  'under_review'::public.order_status,
  'a submitted order sits in the queue'
);

select is(
  (select submitted_at is not null from api.admin_orders() limit 1),
  true,
  'and the queue says when it arrived'
);

select is(
  (select amount from api.admin_orders() limit 1),
  750::numeric,
  'and what it is for'
);

-- A reference that does not exist is an empty list, not an error. The reviewer
-- pastes a code from a screenshot; a typo should say so by returning nothing.
select is(
  (select count(*) from api.admin_orders(null, 'NOPE-0000')),
  0::bigint,
  'an unknown reference finds nothing'
);

select is(
  (select count(*) from api.admin_orders(null, (select reference_code from public.orders limit 1))),
  1::bigint,
  'the real reference finds the order'
);

-- The same code typed in a different case still finds it: it is normalised on
-- the way in, so it has to be normalised on the way out too.
select is(
  (
    select count(*)
    from api.admin_orders(null, upper((select reference_code from public.orders limit 1)))
  ),
  1::bigint,
  'and is matched case-insensitively'
);

select is(
  (select count(*) from api.admin_orders('approved')),
  0::bigint,
  'filtering by a status with no orders is empty'
);

-- ---------------------------------------------------------------------------
-- What a reviewer is shown
-- ---------------------------------------------------------------------------

select is(
  (api.admin_order_detail((test_data.subject_order()).id) ->> 'status'),
  'under_review',
  'the detail reports the status'
);

-- The hidden minimum is hidden from customers and visible to the reviewer. If
-- somebody is paying 400 against a 500 minimum, this is the number that
-- explains the rejection.
select is(
  (api.admin_order_detail((test_data.subject_order()).id) ->> 'min_amount')::numeric,
  500::numeric,
  'the reviewer sees the real minimum'
);

-- Same order, asked as the customer. The threshold exists to make a rejection
-- explainable to the reviewer; it is not something to hand to the payer.
select test_data.as_user(test_data.subject_id());
select is(
  (api.my_order_status((test_data.subject_order()).id) ->> 'min_amount') is null,
  true,
  'while the customer is told nothing'
);
select test_data.as_user((select user_id from public.staff limit 1));

select is(
  jsonb_typeof(api.admin_order_detail((test_data.subject_order()).id) -> 'evidence'),
  'array',
  'the detail carries the evidence'
);

select throws_ok(
  $$select api.admin_order_detail(gen_random_uuid())$$,
  'P0002',
  'order not found',
  'an order that does not exist is not found'
);

-- ---------------------------------------------------------------------------
-- A TrxID on two orders is flagged, not blocked
-- ---------------------------------------------------------------------------

select is(
  jsonb_array_length(api.admin_order_detail((test_data.subject_order()).id) -> 'duplicates'),
  0,
  'an order with a unique TrxID has no duplicates'
);

-- A second customer paying with the same TrxID. Usually somebody resubmitting
-- from a second browser, so it is a flag for a human rather than a refusal: a
-- wrong block here strands a paid order.
select test_data.new_subject('b');
select test_data.as_subject('b');
select test_data.orders('guide', 'bKash', 750, 'b') ->> 'ok';
select test_data.submit(test_data.subject_id('b'), (test_data.subject_order('b')).id) ->> 'ok';

select test_data.reviewer();
select test_data.as_subject('staff');

select is(
  (
    select has_duplicate_trxid
    from api.admin_orders(null, (select reference_code from public.orders where user_id = test_data.subject_id('b')))
  ),
  true,
  'the second order carrying that TrxID is flagged'
);

select is(
  (select count(*) from api.admin_order_duplicate_trxids((test_data.subject_order()).id) d where d.field_key = 'trxid'),
  1::bigint,
  'and the collision is reported under the field it happened on'
);

select is(
  (select array_length(other_order_ids, 1)
   from api.admin_order_duplicate_trxids((test_data.subject_order()).id)
   where field_key = 'trxid')::int,
  1,
  'naming the one other order'
);

-- Same code, different case. The comparison runs on the normalised value, so a
-- TrxID retyped by hand still counts as the same TrxID.
select test_data.reset();
select test_data.as_subject('a');
select test_data.new_subject();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';
select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id) ->> 'ok';
select test_data.new_subject('b');
select test_data.as_subject('b');
select test_data.orders('guide', 'bKash', 750, 'b') ->> 'ok';
select test_data.submit(test_data.subject_id('b'), (test_data.subject_order('b')).id, '{"trxid": "abc123xyz9"}') ->> 'ok';
select test_data.reviewer();
select test_data.as_subject('staff');

select is(
  (select count(*) from api.admin_order_duplicate_trxids((test_data.subject_order()).id) d where d.field_key = 'trxid'),
  1::bigint,
  'the same TrxID typed in another case still collides'
);

-- The scan is about transaction IDs, not about any shared value: two customers
-- paying the same price is the queue's Tuesday, not a fraud signal.
select test_data.reset();
select test_data.as_subject('a');
select test_data.new_subject();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';
select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"trxid": "aaaa1111bbbb"}') ->> 'ok';
select test_data.new_subject('b');
select test_data.as_subject('b');
select test_data.orders('guide', 'bKash', 750, 'b') ->> 'ok';
select test_data.submit(test_data.subject_id('b'), (test_data.subject_order('b')).id, '{"trxid": "zzzz9999yyyy"}') ->> 'ok';
select test_data.reviewer();
select test_data.as_subject('staff');

select is(
  (select count(*) from api.admin_order_duplicate_trxids((test_data.subject_order('b')).id)),
  0::bigint,
  'the same amount on two orders is not a shared transaction ID'
);

select is(
  (
    select has_duplicate_trxid
    from api.admin_orders(null, (select reference_code from public.orders where user_id = test_data.subject_id('b')))
  ),
  false,
  'and the queue does not flag it either'
);

-- ---------------------------------------------------------------------------
-- Approving
-- ---------------------------------------------------------------------------

select is(
  (api.approve_order((test_data.subject_order()).id) ->> 'ok'),
  'true',
  'staff approve an order in review'
);

select is(
  (select status from public.orders where id = (test_data.subject_order()).id),
  'approved'::public.order_status,
  'and the order is approved'
);

-- The double-clicked button. The second call is the same question asked twice,
-- and answering it with an error would leave the reviewer thinking the first
-- one failed.
select is(
  (api.approve_order((test_data.subject_order()).id) ->> 'already'),
  'true',
  'approving again is the same answer rather than an error'
);

select test_data.as_subject('a');
select is(
  (
    select count(*)
    from api.my_grants()
    where slug = 'guide'
  ),
  1::bigint,
  'approval grants access, with nothing else having to remember to'
);
select is(
  (api.get_unlocked_page('guide') ->> 'slug'),
  'guide',
  'and the paid body opens for that customer'
);

select test_data.as_subject('staff');
select throws_ok(
  $$select api.reject_order((test_data.subject_order()).id, 'changed my mind')$$,
  '22023',
  'order is not under review',
  'an approved order cannot then be rejected'
);

-- ---------------------------------------------------------------------------
-- Rejecting
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.as_subject('a');
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';
select test_data.reviewer();
select test_data.as_subject('staff');

select throws_ok(
  $$select api.reject_order((test_data.subject_order()).id, '   ')$$,
  '22023',
  'a rejection reason is required',
  'a rejection with no reason is refused'
);

select test_data.as_subject('a');
select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id) ->> 'ok';
select test_data.as_subject('staff');

select is(
  (api.reject_order((test_data.subject_order()).id, 'Amount does not match', 'পরিমাণ মিলছে না', 'amount_mismatch') ->> 'status'),
  'rejected',
  'an order in review is rejected'
);

select is(
  (select reject_reason_en from public.orders where id = (test_data.subject_order()).id),
  'Amount does not match',
  'the reason the reviewer gave is kept'
);

select is(
  (select reject_code from public.orders where id = (test_data.subject_order()).id),
  'amount_mismatch',
  'along with a machine-readable code the UI can branch on'
);

-- The payer is told why, in their language. A rejection with no explanation is
-- the one thing that turns a small mistake into a support ticket.
select test_data.as_subject('a');
select is(
  (api.my_order_status((test_data.subject_order()).id) ->> 'reject_reason_bn'),
  'পরিমাণ মিলছে না',
  'and the customer is told why in Bangla'
);
select is(
  api.get_unlocked_page('guide') is null,
  true,
  'and a rejection leaves the body closed'
);

-- A reviewer who realises they read the screenshot wrong needs to say so
-- without waiting for a second submission.
select test_data.as_subject('staff');
select is(
  (api.reject_order((test_data.subject_order()).id, 'Wrong screenshot', 'ভুল ছবি') ->> 'status'),
  'rejected',
  'a rejection can be revised'
);
select is(
  (select reject_reason_en from public.orders where id = (test_data.subject_order()).id),
  'Wrong screenshot',
  'and the reason is replaced rather than appended to'
);

-- ---------------------------------------------------------------------------
-- Releasing a probe lock
-- ---------------------------------------------------------------------------

-- A customer who guessed wrong six times is locked out of that link. That is a
-- deliberate wall, so the way back has to be a person, not a timer: six more
-- guesses from the same account would clear it otherwise.
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
  (select status from public.orders where id = (test_data.subject_order()).id),
  'locked'::public.order_status,
  'six guesses under the minimum lock the order'
);

select is(
  (test_data.orders('guide', 'bKash', 400, 'a') ->> 'code'),
  'locked',
  'and the customer is told so'
);

select test_data.reviewer();
select test_data.as_subject('staff');

select is(
  (api.admin_reset_probes((test_data.subject_order()).id) ->> 'ok'),
  'true',
  'staff release a lock'
);

select is(
  (select status from public.orders where id = (test_data.subject_order()).id),
  'awaiting_proof'::public.order_status,
  'and the order waits for its screenshot again'
);

select is(
  (select probe_count from public.orders where id = (test_data.subject_order()).id),
  0,
  'with the counter cleared'
);

select is(
  (select locked_at from public.orders where id = (test_data.subject_order()).id) is null,
  true,
  'and no lock left behind'
);

select throws_ok(
  $$select api.admin_reset_probes(gen_random_uuid())$$,
  'P0002',
  'order not found',
  'releasing an order that does not exist is not found'
);

-- Released means released: the customer can now pay properly, and the six
-- guesses are not waiting to re-lock them.
select test_data.as_subject('a');
select is(
  (test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok'),
  'true',
  'the customer can now start a real order'
);

-- ---------------------------------------------------------------------------
-- The counts on the dashboard
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.new_subject('b');
select test_data.new_subject('c');

-- Three customers, one order each: paid, refused, and abandoned.
select test_data.as_subject('a');
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';
select test_data.submit(test_data.subject_id('a'), (test_data.subject_order('a')).id) ->> 'ok';

select test_data.as_subject('b');
select test_data.orders('guide', 'bKash', 750, 'b') ->> 'ok';
select test_data.submit(test_data.subject_id('b'), (test_data.subject_order('b')).id) ->> 'ok';

select test_data.as_subject('c');
select test_data.orders('guide', 'bKash', 750, 'c') ->> 'ok';

select test_data.reviewer();
select test_data.as_subject('staff');

select is(
  (api.approve_order((test_data.subject_order('a')).id) ->> 'ok'),
  'true',
  'one order is approved'
);
select is(
  (api.reject_order((test_data.subject_order('b')).id, 'TrxID not found', 'TrxID পাওয়া যায়নি') ->> 'status'),
  'rejected',
  'the other is rejected'
);

select is(
  (api.admin_stats() ->> 'approved_total')::int,
  1,
  'the dashboard counts what was approved'
);

-- Revenue counts approved money, not money people intend to pay. Counting
-- anything else makes the number a thing to brag about before it arrives.
select is(
  (api.admin_stats() ->> 'revenue')::numeric,
  750::numeric,
  'and totals only approved amounts'
);

select is(
  (api.admin_stats() ->> 'rejected')::int,
  1,
  'and counts rejections'
);

select is(
  (api.admin_stats() ->> 'awaiting_review')::int,
  0,
  'and nothing is left waiting on a decision'
);

-- The one order nobody submitted. It is money that has not arrived, so it is
-- counted apart from revenue.
select is(
  (api.admin_stats() ->> 'awaiting_proof')::int,
  1,
  'and an order still waiting on a screenshot is counted separately'
);

select is(
  (api.admin_stats() ->> 'active_pages')::int,
  1,
  'and knows the catalogue'
);

select is(
  (api.admin_stats() ->> 'active_gateways')::int,
  1,
  'and the payment methods it is taking'
);

-- The wider dashboard numbers: three customers placed three orders in this
-- window, one expired later (subject c's order lapses on its own), and the
-- 30-day windows cover everything the fixtures just created.
select is(
  (api.admin_stats() ->> 'total_orders')::int,
  3,
  'and counts every order ever placed'
);

select is(
  (api.admin_stats() ->> 'customers')::int,
  3,
  'and counts distinct customers, not orders'
);

select is(
  (api.admin_stats() ->> 'orders_30d')::int,
  3,
  'and the 30-day window covers the fixtures'
);

select is(
  (api.admin_stats() ->> 'revenue_30d')::numeric,
  750::numeric,
  'and the revenue window matches the all-time figure here'
);

-- The analytics series: one row per day for the window, zeros included - a
-- chart that skips quiet days draws a line through time that does not exist.
select is(
  (select count(*) from api.admin_analytics(30))::int,
  30,
  'the analytics window is one row per day, zeros included'
);

select is(
  (select sum(orders_created) from api.admin_analytics(30))::int,
  3,
  'and the daily created counts sum to every order'
);

select is(
  (select sum(revenue_approved) from api.admin_analytics(30))::numeric,
  750::numeric,
  'and the daily revenue sums to the approved money'
);

-- Per-page performance: the one page that sold, ranked with its money.
select is(
  (select count(*) from api.admin_page_performance(5))::int,
  1::bigint,
  'the performance table lists selling pages'
);

select is(
  (select revenue from api.admin_page_performance(5))::numeric,
  750::numeric,
  'and carries the page revenue'
);

-- Analytics is shop-wide money, and a customer's anonymous signup carries the
-- authenticated role - the grant alone would hand every buyer the revenue.
select is(
  test_data.as_role('anon', 'select * from api.admin_analytics(30)') ->> 'state',
  '42501',
  'anonymous callers cannot read the analytics series'
);

select is(
  test_data.as_role('anon', 'select * from api.admin_page_performance(5)') ->> 'state',
  '42501',
  'nor the per-page performance'
);

select test_data.as_user(test_data.new_user());
select is(
  test_data.as_role('authenticated', 'select * from api.admin_analytics(30)') ->> 'state',
  '42501',
  'and neither can a signed-in customer: staff is the gate, not the role'
);

select * from finish();

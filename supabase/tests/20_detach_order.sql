-- Detaching from a rejected order.
--
-- A rejection used to be a dead end: create_order treats `rejected` as an open
-- status, so the customer was always handed straight back to the order that
-- had just been refused. Detaching clears the order's user, which takes it out
-- of my_orders and out of every open-order check. The tests here pin the
-- guardrails around who may detach and what they may detach.

select plan(11);

select test_data.reset();

select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.gateway('nagad');

select test_data.new_subject();

select is(
  (test_data.submitted_order(test_data.subject_id())).status::text,
  'under_review',
  'the fixture starts from an order with evidence attached'
);

select is(
  (test_data.reviewed_by_staff(
    (select id from public.orders limit 1), 'reject', 'unreadable screenshot'
  ) ->> 'status'),
  'rejected',
  'staff rejected the order'
);

-- The customer is back in the picture for the rest of the file.
select test_data.as_user(test_data.subject_id());

-- ---------------------------------------------------------------------------
-- The dead end, reproduced
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.create_order('guide', 'nagad', 750)$$,
  '22023',
  'kind_mismatch: open order already uses payment kind bkash',
  'while the rejection is attached, a different payment kind is refused'
);

select is(
  test_data.orders('guide', 'bKash', 750) ->> 'status',
  'rejected',
  'and the same payment kind just re-returns the rejected order'
);

-- The fixture's order helper signs out at the end; the guardrails below read
-- the caller's identity, so the customer is deliberately back in the picture.
select test_data.as_user(test_data.subject_id());

-- ---------------------------------------------------------------------------
-- The guardrails
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.detach_order('00000000-0000-0000-0000-000000000000')$$,
  'P0002',
  'order not detachable',
  'an unknown order is refused by its would-be owner'
);

select test_data.as_anon();

select throws_ok(
  $$select api.detach_order((select id from public.orders limit 1))$$,
  '42501',
  'authentication required',
  'an anonymous visitor cannot detach anything'
);

select test_data.as_user(test_data.subject_id());

-- ---------------------------------------------------------------------------
-- The detach
-- ---------------------------------------------------------------------------

select lives_ok(
  $$select api.detach_order((select id from public.orders where status = 'rejected' limit 1))$$,
  'the owner detaches their rejected order'
);

select is(
  (select count(*)::int from public.orders where user_id = test_data.subject_id()),
  0,
  'the detached order no longer belongs to the customer'
);

select is(
  (select status::text from public.orders where user_id is null and status = 'rejected'),
  'rejected',
  'but the order row survives for the operator'
);

-- ---------------------------------------------------------------------------
-- After the detach: a fresh order is possible again, on any kind
-- ---------------------------------------------------------------------------

select is(
  test_data.orders('guide', 'bKash', 750) ->> 'ok',
  'true',
  'the same payment kind now starts a fresh order'
);

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.gateway('nagad');

select test_data.new_subject();
select test_data.reviewed_by_staff(
  (select id from test_data.submitted_order(test_data.subject_id())), 'reject', 'no reply'
);
select test_data.as_user(test_data.subject_id());
select api.detach_order((select id from public.orders where status = 'rejected' limit 1));

select is(
  test_data.orders('guide', 'Nagad', 750) ->> 'ok',
  'true',
  'so does a different one - the kind_mismatch dead end is gone'
);

select * from finish();

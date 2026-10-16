-- The live snapshot the dashboard polls: its shapes, and that it refuses
-- everyone but staff.

select plan(8);

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');

select throws_ok(
  $$select api.admin_live_snapshot()$$,
  '42501',
  'forbidden',
  'an anonymous visitor gets no snapshot'
);

select test_data.new_subject();
select test_data.as_subject();
select api.create_order('guide', 'bkash', 750);
select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id);

select test_data.as_anon();
select test_data.reviewer('staff');
select test_data.as_subject('staff');

select is(
  jsonb_typeof(api.admin_live_snapshot()),
  'object',
  'a staff session answers an object'
);

select is(
  (select count(*)::text from jsonb_object_keys(api.admin_live_snapshot()) k),
  '6',
  'the payload carries exactly the six moving scalars'
);

select is(
  (api.admin_live_snapshot() ->> 'views_total')::int >= 0,
  true,
  'views_total is a number'
);

select is(
  (api.admin_live_snapshot() ->> 'awaiting_review')::int,
  1,
  'the submitted order counts as awaiting review'
);

select is(
  (api.admin_live_snapshot() ->> 'orders_created_30d')::int >= 1,
  true,
  'the fresh order counts among the window creations'
);

select is(
  (api.admin_live_snapshot() ->> 'customers')::int >= 1,
  true,
  'the ordering customer counts'
);

select is(
  (api.admin_live_snapshot() ->> 'revenue_30d')::numeric >= 0,
  true,
  'revenue answers a non-negative number even with nothing approved'
);

select * from finish();

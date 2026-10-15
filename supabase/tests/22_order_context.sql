-- The order's visit context and the received amount.
--
-- The client's word is clamped, not trusted: a wrong country, device bucket
-- or overlong string degrades to null instead of an error. Approval records
-- what actually arrived, and refuses a non-positive one.

select plan(10);

-- ---------------------------------------------------------------------------
-- The context, clamped
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.as_subject();

select api.create_order('guide', 'bkash', 750, '{"country": "BD", "city": "Dhaka", "device_type": "mobile", "os": "Android", "browser": "Chrome", "referrer": "google.com"}'::jsonb);

select is(
  (select country from public.orders where user_id = test_data.subject_id() limit 1),
  'BD',
  'a well-formed context country is stored'
);

select is(
  (select device_type from public.orders where user_id = test_data.subject_id() limit 1),
  'mobile',
  'a known device bucket is stored'
);

-- A second order (after the first is rejected) with garbage everywhere: the
-- context degrades instead of failing the order.
select test_data.as_subject();
select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id);
select test_data.as_anon();
select test_data.reviewer('staff');
select test_data.as_subject('staff');
select api.reject_order((test_data.subject_order()).id, 'test', 'test');
select test_data.as_subject();
select api.detach_order((test_data.subject_order()).id);

select api.track_page_view('guide', null, null, 'desktop', null, null, null);
select api.create_order(
  'guide',
  'bkash',
  750,
  '{"country": "bd", "city": "", "device_type": "fridge", "os": "A very long operating system name indeed, far past forty characters", "browser": "SomeBrowser/9000 and then some more text", "referrer": "https://ref.example.com/path?query=1"}'::jsonb
);
select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id);

select is(
  (select country from public.orders where user_id = test_data.subject_id() order by created_at desc limit 1),
  null,
  'a lowercase country is dropped'
);

select is(
  (select device_type from public.orders where user_id = test_data.subject_id() order by created_at desc limit 1),
  null,
  'an unknown device bucket is dropped'
);

select is(
  (select length(os) from public.orders where user_id = test_data.subject_id() order by created_at desc limit 1) <= 40,
  true,
  'an overlong OS string is truncated'
);

-- ---------------------------------------------------------------------------
-- Approval records the received amount
-- ---------------------------------------------------------------------------

select test_data.as_anon();
select test_data.reviewer('staff');
select test_data.as_subject('staff');

select throws_ok(
  $$select api.approve_order(
    (select id from public.orders where user_id = test_data.subject_id() order by created_at desc limit 1),
    -5
  )$$,
  '22023',
  'received amount must be positive',
  'a non-positive received amount is refused'
);

select api.approve_order(
  (select id from public.orders where user_id = test_data.subject_id() order by created_at desc limit 1),
  600
);

select is(
  (select amount_received from public.orders where user_id = test_data.subject_id() order by created_at desc limit 1)::text,
  '600',
  'the received amount is recorded at approval'
);

select throws_ok(
  $$select api.approve_order(
    (select id from public.orders where user_id = test_data.subject_id() order by created_at desc limit 1),
    -5
  )$$,
  '22023',
  'received amount must be positive',
  'a non-positive received amount is refused'
);

-- The stats answer with the received amount folded in.
select is(
  (api.admin_traffic_stats(30) -> 'locations') is not null,
  true,
  'the locations array answers'
);

select is(
  jsonb_typeof(api.admin_traffic_stats(30) -> 'locations'),
  'array',
  'the locations payload is an array even with no city data'
);

select * from finish();
-- The order's visit context, the received amount, and the rejected lifecycle.
--
-- The client's word is clamped, not trusted: a wrong country, device bucket
-- or overlong string degrades to null instead of an error. Approval records
-- what actually arrived. A customer who owns the page cannot order it again,
-- and a rejected order stays rejected.

select plan(11);

-- ---------------------------------------------------------------------------
-- The context, clamped
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.as_subject();

select api.create_order(
  'guide',
  'bkash',
  750,
  '{"country": "BD", "city": "Dhaka", "device_type": "mobile", "os": "Android", "browser": "Chrome", "referrer": "google.com"}'::jsonb
);

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

-- ---------------------------------------------------------------------------
-- Approval records the received amount, and ownership blocks re-ordering
-- ---------------------------------------------------------------------------

select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id);
select test_data.as_anon();
select test_data.reviewer('staff');
select test_data.as_subject('staff');

select api.approve_order((test_data.subject_order()).id, 600);

select is(
  (select amount_received::text from public.orders where id = (test_data.subject_order()).id),
  '600',
  'the received amount is recorded at approval'
);

select test_data.as_subject();

select is(
  (api.create_order('guide', 'bkash', 750, '{"country": "BD", "device_type": "mobile"}'::jsonb) ->> 'code'),
  'already_owned',
  'a customer with access is refused before any payment'
);

-- ---------------------------------------------------------------------------
-- The rejected lifecycle, on a second customer
-- ---------------------------------------------------------------------------

select test_data.new_subject('b');
select test_data.as_subject('b');

-- Garbage everywhere: the context degrades instead of failing the order.
select api.create_order(
  'guide',
  'bkash',
  750,
  '{"country": "bd", "city": "", "device_type": "fridge", "os": "A very long operating system name indeed, far past forty characters", "browser": "SomeBrowser/9000 and then some more text", "referrer": "https://ref.example.com/path?query=1"}'::jsonb
);

select is(
  (select country from public.orders where user_id = test_data.subject_id('b') limit 1),
  null,
  'a lowercase country is dropped'
);

select is(
  (select device_type from public.orders where user_id = test_data.subject_id('b') limit 1),
  null,
  'an unknown device bucket is dropped'
);

select is(
  (select length(os) from public.orders where user_id = test_data.subject_id('b') limit 1) <= 40,
  true,
  'an overlong OS string is truncated'
);

select test_data.submit(test_data.subject_id('b'), (test_data.subject_order('b')).id);
select test_data.as_anon();
select test_data.reviewer('staff');
select test_data.as_subject('staff');
select api.reject_order((test_data.subject_order('b')).id, 'test', 'test');
select test_data.as_subject('staff');
update public.orders
set expires_at = now() - interval '1 hour'
where user_id = test_data.subject_id('b') and status = 'rejected';
select private.expire_stale_orders();

select is(
  (select status::text from public.orders where user_id = test_data.subject_id('b') and status = 'rejected' limit 1),
  'rejected',
  'a rejected order is not expired by the sweep'
);

-- A rejected customer starts fresh: the new order is theirs, the dead row
-- stays behind as history.
select test_data.as_subject('b');
select api.create_order('guide', 'bkash', 750);
select is(
  (select count(*)::text from public.orders
    where user_id = test_data.subject_id('b') and status = 'awaiting_proof'),
  '1',
  'a rejected customer opens a fresh order instead of reusing the dead one'
);

-- ---------------------------------------------------------------------------
-- The stats answer with the shapes the dashboard reads
-- ---------------------------------------------------------------------------

select test_data.as_anon();
select test_data.reviewer('staff');
select test_data.as_subject('staff');

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

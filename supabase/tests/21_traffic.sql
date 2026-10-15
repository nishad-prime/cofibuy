-- Visit tracking and the traffic analytics the dashboard draws.
--
-- The beacon is anonymous by design, so the tests are about what it refuses:
-- only live pages are recorded, only sane values survive normalisation, and
-- the stats answer staff-only with the real shapes the dashboard reads.

select plan(15);

-- ---------------------------------------------------------------------------
-- What gets recorded
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);

select is(
  (api.track_page_view('guide', 'BD', 'mobile', 'Android', 'Chrome', 'google.com')) ->> 'tracked',
  'true',
  'a view of a live page is recorded'
);

select is(
  (api.track_page_view('no-such-page', 'BD', 'mobile', 'Android', 'Chrome', null)) ->> 'tracked',
  'false',
  'an unknown slug is answered but not recorded'
);

select is(
  (select count(*) from public.page_views)::text,
  '1',
  'exactly one row landed'
);

select is(
  (select country from public.page_views limit 1),
  'BD',
  'the country is stored as given'
);

-- ---------------------------------------------------------------------------
-- Normalisation: the client's word is not trusted
-- ---------------------------------------------------------------------------

select api.track_page_view('guide', 'bd', 'fridge', 'A very long operating system name indeed, far past forty characters', 'SomeBrowser/9000 and then some more text', 'https://ref.example.com/path?query=1');

select is(
  (select country from public.page_views order by id desc limit 1),
  null,
  'a lowercase country is dropped, not guessed'
);

select is(
  (select device_type from public.page_views order by id desc limit 1),
  'desktop',
  'an unknown device bucket falls back to desktop'
);

select is(
  (select length(os) from public.page_views order by id desc limit 1) <= 40,
  true,
  'the OS string is truncated'
);

select is(
  (select length(browser) from public.page_views order by id desc limit 1) <= 40,
  true,
  'the browser string is truncated'
);

select is(
  (select length(referrer) from public.page_views order by id desc limit 1) <= 200,
  true,
  'the referrer is truncated'
);

-- ---------------------------------------------------------------------------
-- The stats: staff-only, and shaped as the dashboard reads them
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.admin_traffic_stats(7)$$,
  '42501',
  'forbidden',
  'a non-staff session cannot read traffic stats'
);

select throws_ok(
  $$select api.admin_analytics(7)$$,
  '42501',
  'forbidden',
  'the daily trend is staff-only too'
);

select test_data.reviewer('staff');
select test_data.as_subject('staff');

select is(
  (api.admin_traffic_stats(7) -> 'funnel' ->> 'views'),
  '2',
  'the funnel counts the recorded views'
);

select is(
  jsonb_array_length(api.admin_traffic_stats(7) -> 'devices'),
  2,
  'the device split reports the recorded buckets'
);

select is(
  jsonb_typeof(api.admin_traffic_stats(7) -> 'pages'),
  'array',
  'the per-page performance arrives as an array'
);

select is(
  (select count(*)::text from api.admin_analytics(7)),
  '7',
  'the daily trend answers one row per day, zero days included'
);

select * from finish();

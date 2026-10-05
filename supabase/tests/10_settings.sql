-- Public settings and maintenance mode.
--
-- The assertions that matter here are the reachability ones. `site_settings` has
-- RLS on with no policies and no grants, so anything the storefront learns has to
-- come through a function -- and the test has to prove that the function is the
-- only way, or a future `grant select` would quietly republish the whole table.

select plan(33);
select test_data.reset();

-- A published link with its price visible, one with the minimum hidden, and a
-- gateway, because the wrapper has to reproduce the hidden-minimum rule exactly.
select test_data.link('guide');
select test_data.link('hidden-price', 700, true);
select test_data.gateway();

-- ---------------------------------------------------------------------------
-- The public read
-- ---------------------------------------------------------------------------

select test_data.as_anon();

select is(
  (select api.get_public_settings() ->> 'maintenance_mode'),
  'false',
  'a fresh shop is not in maintenance'
);

select is(
  (select api.get_public_settings() ->> 'min_amount'),
  (select min_amount::text from public.site_settings where id = 1),
  'a visible global minimum is published'
);

-- Hiding the global minimum must remove the number from this payload too, not just
-- from the label. The schema's rule is that a hidden minimum has no read path at all,
-- so a settings projection that still carried it would quietly undo `get_public_link`.
update public.site_settings set hide_min_amount = true;

select is(
  (select api.get_public_settings() ->> 'min_amount'),
  null,
  'a hidden global minimum is withheld'
);

select is(
  (select api.get_public_settings() ->> 'hide_min_amount'),
  'true',
  'but the fact that it is hidden is published'
);

update public.site_settings set hide_min_amount = false;

select is(
  (select api.get_public_settings() ->> 'default_lang'),
  'bn',
  'the default language is published'
);

select is(
  (select api.get_public_settings() ->> 'currency'),
  'BDT',
  'the currency defaults to BDT'
);

select ok(
  (select api.get_public_settings() ? 'contact'),
  'the contact key is present even when null'
);

-- The table is still not reachable, even though a curated read of it is.
select is(
  test_data.as_role('anon', 'select count(*) from public.site_settings') ->> 'state',
  '42501',
  'anon cannot select the settings table'
);

select is(
  test_data.as_role('authenticated', 'select count(*) from public.site_settings') ->> 'state',
  '42501',
  'a signed-in customer cannot read the table either'
);

-- Nothing privileged leaks through the projection.
select is(
  (select api.get_public_settings() ? 'staff'),
  false,
  'no staff data in the public payload'
);

select is(
  (select count(*) from jsonb_object_keys(api.get_public_settings())),
  7,
  'the projection is exactly the seven published keys'
);

-- ---------------------------------------------------------------------------
-- The owner-only setter
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.new_user());

select throws_ok(
  $$select api.admin_set_settings('{"maintenance_mode": true}'::jsonb)$$,
  '42501',
  'forbidden',
  'a customer cannot put the shop into maintenance'
);

select test_data.as_user(test_data.new_staff('staff'));

select throws_ok(
  $$select api.admin_set_settings('{"maintenance_mode": true}'::jsonb)$$,
  '42501',
  'forbidden',
  'staff cannot put the shop into maintenance'
);

select test_data.as_service();

select throws_ok(
  $$select api.admin_set_settings('{"maintenance_mode": true}'::jsonb)$$,
  '42501',
  'forbidden',
  'the service role is not an owner either'
);

-- The setter used to drop unknown keys silently, so a typo looked like it saved.
-- Asserted as owner, so the owner gate is not what answers instead.
select test_data.as_user(test_data.new_staff('owner'));

select throws_ok(
  $$select api.admin_set_settings('{"manance_mode": true}'::jsonb)$$,
  'P0001',
  'unknown settings key: manance_mode',
  'a misspelled key is refused rather than ignored'
);

select lives_ok(
  $$select api.admin_set_settings('{"maintenance_mode": true}'::jsonb)$$,
  'the owner can set maintenance mode'
);

select is(
  (select maintenance_mode from public.site_settings where id = 1),
  true,
  'and it lands'
);

select lives_ok(
  $$select api.admin_set_settings('{"currency": "USD"}'::jsonb)$$,
  'the owner can change the currency'
);

select is(
  (select currency from public.site_settings where id = 1),
  'USD',
  'and it lands'
);

select throws_ok(
  $$select api.admin_set_settings('{"currency": "ZZZ"}'::jsonb)$$,
  '22023',
  'unsupported currency: ZZZ',
  'an unknown currency code is refused'
);

select throws_ok(
  $$select api.admin_set_settings('{"currency": "US"}'::jsonb)$$,
  '22023',
  'unsupported currency: US',
  'a malformed currency code is refused'
);

select test_data.as_anon();

select is(
  (select api.get_public_settings() ->> 'currency'),
  'USD',
  'the public projection reflects the new currency'
);

-- ---------------------------------------------------------------------------
-- Reporting, not raising
--
-- The link still resolves while the shop is closed. A customer should be able to
-- read what they would have bought and why they cannot pay for it right now.
-- ---------------------------------------------------------------------------

select test_data.as_anon();

select is(
  (select api.get_public_link('guide') ->> 'maintenance_mode'),
  'true',
  'the storefront is told the shop is closed'
);

select is(
  (select api.get_public_link('guide') ->> 'slug'),
  'guide',
  'and the link still resolves'
);

select ok(
  (select jsonb_typeof(api.get_public_link('guide') -> 'gateways') = 'array'),
  'with its gateways intact'
);

-- The hidden-minimum rule lives in the moved-aside projection. If the wrapper had
-- replaced rather than extended it, this would start publishing the amount.
select is(
  api.get_public_link('hidden-price') ->> 'min_amount',
  null,
  'the hidden minimum is still hidden through the wrapper'
);

select is(
  (api.get_public_link('hidden-price') ->> 'min_hidden')::boolean,
  true,
  'and the hiding is still reported'
);

-- ---------------------------------------------------------------------------
-- Refusing orders
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.new_user());

select throws_ok(
  $$select api.create_order('guide', null, 500)$$,
  'P0001',
  'shop temporarily closed',
  'a customer cannot open an order while the shop is closed'
);

-- Checked before the slug is resolved, so the refusal does not depend on whether
-- the link happens to exist or which gateway was named.
select throws_ok(
  $$select api.create_order('no-such-link', null, 500)$$,
  'P0001',
  'shop temporarily closed',
  'the maintenance answer wins even for an unknown slug'
);

select is(
  (select count(*) from public.orders),
  0,
  'and no order row was written'
);

select test_data.as_user(test_data.new_staff('owner'));
select api.admin_set_settings('{"maintenance_mode": false}'::jsonb);

select test_data.as_user(test_data.new_user());

select lives_ok(
  $$select api.create_order('guide', (select kind from public.payment_gateways where is_active order by sort_order limit 1), 500)$$,
  'orders work again once the shop reopens'
);

-- ---------------------------------------------------------------------------
-- The moved-aside functions are not a back door
-- ---------------------------------------------------------------------------

select is(
  test_data.can_execute('anon', 'api.public_link_payload(text)'),
  false,
  'anon cannot bypass the wrapper'
);

select is(
  test_data.can_execute('authenticated', 'api.create_order_unchecked(text,uuid,numeric)'),
  false,
  'a signed-in customer cannot bypass the maintenance gate'
);

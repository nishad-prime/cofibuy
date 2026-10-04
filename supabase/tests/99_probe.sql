-- Gateway upsert identity.
--
-- `admin_upsert_gateway` serves both create and edit, told apart by the presence
-- of an `id`. An edit that failed to carry the id forward would silently insert
-- a second gateway and leave the old account number live, which is the failure
-- these assertions guard.

set client_min_messages = warning;
select plan(4);
select test_data.reset();
select test_data.as_user(test_data.new_staff('owner'));

select is(
  (select (api.admin_upsert_gateway('{"kind": "bkash", "name_en": "bKash", "account_number": "01700000000", "account_name": "Merchant", "is_active": true}'::jsonb)).id is not null),
  true,
  'a gateway can be created without an id'
);

-- The edit runs inside this assertion so that the two after it can look at the
-- row it left behind, rather than at the row the create happened to write.
select is(
  (select (api.admin_upsert_gateway(jsonb_build_object(
    'id', (select id from public.payment_gateways),
    'kind', 'bkash',
    'name_en', 'bKash',
    'account_number', '01799999999',
    'account_name', 'Merchant',
    'is_active', true
  ))).id = (select id from public.payment_gateways)),
  true,
  'editing a gateway keeps its identity'
);

select is(
  (select account_number from public.payment_gateways),
  '01799999999',
  'and the edit writes the new account number'
);

select is(
  (select count(*)::int from public.payment_gateways),
  1,
  'without leaving a duplicate behind'
);

select * from finish();
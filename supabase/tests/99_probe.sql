set client_min_messages = warning;
select plan(1);
select test_data.reset();
select test_data.as_user(test_data.new_staff('owner'));
select is(
  (select (api.admin_upsert_gateway('{"kind": "bkash", "name_en": "bKash", "account_number": "01700000000", "account_name": "Merchant", "is_active": true}'::jsonb)).id is not null),
  true,
  'a gateway can be created without an id'
);
select is(
  (select (api.admin_upsert_gateway(jsonb_build_object(
    'id', (select id from public.payment_gateways),
    'kind', 'bkash',
    'name_en', 'bKash',
    'account_number', '01799999999',
    'account_name', 'Merchant',
    'is_active', true
  ))).id = (select id from public.payment_gateways where account_number = '01799999999')),
  true,
  'editing a gateway keeps its identity'
);
select * from finish();

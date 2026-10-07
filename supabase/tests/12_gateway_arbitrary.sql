-- Arbitrary payment methods.
--
-- A shop should be able to accept CellFin, Rocket, or a wallet that did not exist when
-- this schema was written, without a migration and a deploy. That is only true if `kind`
-- is free text and if the destination the customer sends money to is data rather than two
-- fixed columns - so these are the tests that hold both of those open.
--
-- The line between "arbitrary" and "unvalidated" is deliberate. An operator may name a
-- method anything, but a blank name, a name long enough to wreck an admin table, an
-- account detail with no label, and two details sharing a key are all still refused:
-- arbitrary is about which methods exist, not about accepting anything at all.

select plan(34);

select test_data.reset();

select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.pgw_gateway();

-- ---------------------------------------------------------------------------
-- Arbitrary kinds
-- ---------------------------------------------------------------------------

-- The whole point. Three names that have never been in any list, in any migration.
select test_data.as_user(test_data.owner());
select is(
  (api.admin_upsert_gateway(
     jsonb_build_object('kind', 'cellfin', 'name_en', 'CellFin',
                        'account_fields', '[]'::jsonb))).kind,
  'cellfin',
  'a method nobody has heard of can be added'
);

select is(
  (api.admin_upsert_gateway(
     jsonb_build_object('kind', 'rocket', 'name_en', 'Rocket',
                        'account_fields', '[]'::jsonb))).kind,
  'rocket',
  'and so can the next one'
);

-- People type the name they know, not a slug somebody else chose. "Nagad (Agent)" is what
-- an operator will actually type, and rejecting it would push them back to the dropdown
-- this all exists to remove.
select is(
  (api.admin_upsert_gateway(
     jsonb_build_object('kind', 'Nagad (Agent)', 'name_en', 'Nagad agent point',
                        'account_fields', '[]'::jsonb))).kind,
  'Nagad (Agent)',
  'a kind with spaces and capitals is stored as typed'
);

select test_data.as_user(test_data.new_staff());
select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'cellfin', 'name_en', 'Sneaky'))$$,
  '42501',
  'forbidden',
  'staff still cannot add a method'
);

select test_data.as_user(test_data.owner());

-- Bounded, but only where the length would actually hurt.
select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', '   ', 'name_en', 'Blank'))$$,
  '22023',
  'a payment method needs a kind',
  'a kind of only spaces is refused'
);

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', repeat('x', 49), 'name_en', 'Too long'))$$,
  '22023',
  'kind is longer than 48 characters',
  'an absurdly long kind is refused'
);

-- The old behaviour was an unhandled enum error, which surfaced to the operator as
-- "invalid input value for enum gateway_kind" with no hint about what to type instead.
select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', null, 'name_en', 'Missing'))$$,
  '22023',
  'a payment method needs a kind',
  'a missing kind is refused with something actionable'
);

-- ---------------------------------------------------------------------------
-- The enum is gone, not merely unused
-- ---------------------------------------------------------------------------

-- Asserted because leaving the type behind would mean something still returns it, and the
-- next person to add a function would silently depend on a dead vocabulary.
select is(
  (select count(*)::int from pg_type where typname = 'gateway_kind'),
  0,
  'the gateway_kind enum no longer exists'
);

-- The two functions that used to name it in their return tables are the ones that would
-- have failed the conversion. Asserted on behaviour, because a signature that still said
-- `gateway_kind` would reject a new kind at runtime.
select test_data.as_user(test_data.new_user());
select test_data.pgw_order('guide') as guide_order;
-- The fixture leaves the session anonymous on its way out, so the customer has to be
-- named again before anything reads as them. Without this, `my_orders()` returns nothing
-- and the assertion below passes for the wrong reason only if it is not checking a value.
select test_data.as_user(test_data.customer_of('guide'));
select is(
  (select gateway_kind::text from api.my_orders() where id = test_data.order_for_customer('guide')),
  (select kind from public.payment_gateways where provider = 'bkash_pgw' limit 1),
  'my_orders reports a kind as text'
);

select test_data.as_user(test_data.new_staff());
select is(
  (select kind::text from api.admin_orders(null, null, 100)
     where id = test_data.order_for_customer('guide')),
  (select kind from public.payment_gateways where provider = 'bkash_pgw' limit 1),
  'admin_orders reports a kind as text'
);

-- ---------------------------------------------------------------------------
-- Dynamic account details
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.owner());

-- A bank transfer needs more than a wallet number: an account name is not enough to send
-- to the right branch, and an operator should not need a developer to add the rest.
select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'kind', 'bank', 'name_en', 'Bank transfer',
        'account_fields', jsonb_build_array(
          jsonb_build_object('key', 'account_number', 'label_en', 'Account number',
                             'value', '0123456789'),
          jsonb_build_object('key', 'account_name', 'label_en', 'Account name',
                             'label_bn', 'হিসাবের নাম', 'value', 'Cofibuy'),
          jsonb_build_object('key', 'routing', 'label_en', 'Routing number',
                             'value', '1102251325'),
          jsonb_build_object('key', 'branch', 'label_en', 'Branch',
                             'value', 'Dhanmondi')
        )))$$,
  'a bank transfer can carry four separate details'
);

select is(
  (select jsonb_array_length(g.account_fields)
     from public.payment_gateways g
    where g.kind = 'bank' and g.name_en = 'Bank transfer'),
  4,
  'all four are stored'
);

-- Order is the operator's, and it is the order the customer reads them in. Preserved
-- because on a bank page the account number has to come first no matter what order the
-- rows happened to be typed in.
select is(
  (select g.account_fields -> 0 ->> 'key'
     from public.payment_gateways g
    where g.kind = 'bank' and g.name_en = 'Bank transfer'),
  'account_number',
  'the details keep the order they were entered in'
);

select is(
  (select g.account_fields -> 2 ->> 'value'
     from public.payment_gateways g
    where g.kind = 'bank' and g.name_en = 'Bank transfer'),
  '1102251325',
  'and their values'
);

-- The Bangla label is optional and falls back, exactly like evidence fields.
select is(
  (select g.account_fields -> 2 ->> 'label_bn'
     from public.payment_gateways g
    where g.kind = 'bank' and g.name_en = 'Bank transfer'),
  null,
  'a detail without a Bangla label stores null rather than an empty string'
);

-- An operator submitting the form with nothing configured must not be told they are wrong.
select is(
  (api.admin_upsert_gateway(
     jsonb_build_object('kind', 'bkash', 'name_en', 'bKash'))).account_fields,
  '[]'::jsonb,
  'a method with no details is allowed'
);

select is(
  (api.admin_upsert_gateway(
     jsonb_build_object('kind', 'bkash', 'name_en', 'bKash',
                        'account_fields', null))).account_fields,
  '[]'::jsonb,
  'and so is an explicit null, which is what an untouched editor sends'
);

-- ---------------------------------------------------------------------------
-- What a bad detail list costs
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bank', 'name_en', 'No label',
        'account_fields', jsonb_build_array(
          jsonb_build_object('key', 'account_number', 'value', '0123456789'))))$$,
  '22023',
  'account field account_number needs a non-blank label_en',
  'a detail the customer cannot read is refused'
);

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bank', 'name_en', 'No value',
        'account_fields', jsonb_build_array(
          jsonb_build_object('key', 'account_number', 'label_en', 'Account number'))))$$,
  '22023',
  'account field account_number needs a non-blank value',
  'a detail with nothing to copy is refused'
);

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bank', 'name_en', 'Bad key',
        'account_fields', jsonb_build_array(
          jsonb_build_object('key', 'Account Number', 'label_en', 'Account number',
                             'value', '0123456789'))))$$,
  '22023',
  'account field key Account Number does not match ^[a-z][a-z0-9_]{0,31}$',
  'a detail key that is not an identifier is refused'
);

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bank', 'name_en', 'Duplicate keys',
        'account_fields', jsonb_build_array(
          jsonb_build_object('key', 'account_number', 'label_en', 'Account number',
                             'value', '0123456789'),
          jsonb_build_object('key', 'account_number', 'label_en', 'Also the number',
                             'value', '9999999999'))))$$,
  '22023',
  'duplicate account field key account_number',
  'two details sharing a key are refused'
);

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bank', 'name_en', 'Not a list',
        'account_fields', '{"key":"x"}'::jsonb))$$,
  '22023',
  'account_fields must be a JSON array',
  'a detail list that is not a list is refused'
);

-- Twelve matches evidence_fields, and for the same reason: this is a page a customer reads
-- on a phone, not a data import.
select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'bank', 'name_en', 'Too many',
        'account_fields', (
          select jsonb_agg(jsonb_build_object(
                   'key', 'row_' || n, 'label_en', 'Row ' || n, 'value', n::text))
            from generate_series(1, 13) n)))$$,
  '22023',
  'account_fields accepts at most 12 rows',
  'a detail list longer than a phone screen is refused'
);

-- ---------------------------------------------------------------------------
-- Automated methods have nothing to send money to
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', (select kind from public.payment_gateways where provider = 'bkash_pgw' limit 1),
    'provider', 'bkash_pgw',
        'name_en', 'bKash (instant)',
        'account_fields', jsonb_build_array(
          jsonb_build_object('key', 'account_number', 'label_en', 'Account number',
                             'value', '01700000000'))))$$,
  '23514',
  'new row for relation "payment_gateways" violates check constraint "payment_gateways_automatic_has_no_forms"',
  'an automated method cannot advertise an account to send money to'
);

select is(
  (select g.account_fields from public.payment_gateways g where g.provider = 'bkash_pgw'),
  '[]'::jsonb,
  'an automated method carries no details'
);

-- ---------------------------------------------------------------------------
-- What the customer sees
-- ---------------------------------------------------------------------------

-- Deliberately not creating another automated method here. Two gateways sharing a display
-- name would make the lookups below ambiguous, and an assertion that silently matches the
-- wrong row is worse than no assertion. The fixture's method is the one under test.
select test_data.as_user(test_data.owner());
select lives_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object(
        'id', (select id from public.payment_gateways where provider = 'bkash_pgw' limit 1),
        'kind', (select kind from public.payment_gateways where provider = 'bkash_pgw' limit 1),
    'provider', 'bkash_pgw', 'name_en', 'bKash (instant)',
        'is_active', true, 'sort_order', 5,
        'account_fields', '[]'::jsonb, 'evidence_fields', '[]'::jsonb))$$,
  'the automated method can still be edited'
);

select test_data.as_anon();
select is(
  (select g ->> 'kind' from jsonb_array_elements(
    (api.get_public_page('guide') -> 'gateways')
  ) g where g ->> 'name_en' = 'Bank transfer'),
  'bank',
  'an arbitrary kind reaches the customer payload'
);

-- The destination IS on the paywall now, by operator decision: the checkout
-- shows the account and the proof form the moment a method is selected, and
-- there is no separate order page to reveal it after. The old rule - "revealed
-- by the order, once, to the person who placed it" - died with that page.
select is(
  (select g ? 'account_fields' from jsonb_array_elements(
    (api.get_public_page('guide') -> 'gateways')
  ) g where g ->> 'name_en' = 'Bank transfer'),
  true,
  'the paywall carries the destination to send the money to'
);

select is(
  (select g ? 'evidence_fields' from jsonb_array_elements(
    (api.get_public_page('guide') -> 'gateways')
  ) g where g ->> 'name_en' = 'Bank transfer'),
  true,
  'and the proof fields it asks for'
);

select is(
  (select g ->> 'provider' from jsonb_array_elements(
    (api.get_public_page('guide') -> 'gateways')
  ) g where g ->> 'name_en' = 'bKash (instant)'),
  'bkash_pgw',
  'and the customer still learns which methods are automated'
);

-- Every gateway advertises its destination now: the checkout shows the account
-- on the page the moment the method is selected, and there is no separate order
-- page to reveal it after. This is the same operator decision that put
-- `account_number` on the paywall (see the assertion above).
select is(
  (select bool_and(g ? 'account_fields') from jsonb_array_elements(
    (api.get_public_page('guide') -> 'gateways')
  ) g),
  true,
  'every gateway of any kind advertises a destination'
);

-- The view is a second door to the same rows, and it is granted to anon directly, so it
-- has to agree with the payload rather than quietly serving the pre-migration shape.
-- Trimming the payload was worth nothing on its own while this view still projected the
-- destination columns: `select account_fields from payment_gateways_public` was a second
-- anonymous door onto every account the shop owns. The view now serves the method list, and
-- the columns are unreachable through it.
select is(
  (test_data.as_role('anon',
     'select id, kind, provider, name_en from public.payment_gateways_public
       where name_en = ''Bank transfer''')
     ->> 'rows'),
  format('[{"id": "%s", "kind": "bank", "name_en": "Bank transfer", "provider": null}]',
         (select id::text from public.payment_gateways
           where kind = 'bank' and name_en = 'Bank transfer')),
  'the public gateway view still serves the method list'
);

select throws_ok(
  $$select account_fields from public.payment_gateways_public$$,
  '42703',
  'column "account_fields" does not exist',
  'and the destination is no longer readable through the view'
);

select is(
  (test_data.as_role('anon',
     'select provider from public.payment_gateways_public
       where name_en = ''bKash (instant)''')
     ->> 'rows'),
  '[{"provider": "bkash_pgw"}]',
  'and the provider, without which the view would deny reading it at all'
);
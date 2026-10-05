-- Routing an order to an account.
--
-- What this file is really about is that "bKash" stopped being a choice between a wallet
-- number and a redirect. The customer names a kind; the shop decides which of its accounts
-- for that kind the money goes to, in proportion to the weight it gave each. Three things
-- have to hold for that to be worth anything:
--
--   1. the draw is actually proportional to weight, and not merely random;
--   2. a kind can never resolve to both a manual and an automatic account;
--   3. the destination is released by the order, to the person who placed it.

select plan(28);

select test_data.reset();

select test_data.link('guide', 500, false);

-- Two kinds of manual account. The fixture writes a fixed account number and a fixed name
-- for every gateway of a kind, which would make "which account was drawn" ambiguous, so
-- these are written directly and named apart.
insert into public.payment_gateways (kind, name_en, account_number, account_name, weight, sort_order)
values
  ('bkash', 'bKash light', '01700000001', 'Cofibuy', 1, 1),
  ('bkash', 'bKash heavy', '01700000003', 'Cofibuy', 9, 2);

insert into public.payment_gateways (kind, name_en, account_number, account_name, weight, sort_order)
values
  ('nagad', 'Nagad one',   '01700000004', 'Cofibuy', 1, 1),
  ('nagad', 'Nagad two',   '01700000005', 'Cofibuy', 1, 2);

select test_data.gateway('bank');

-- ---------------------------------------------------------------------------
-- The weight itself
-- ---------------------------------------------------------------------------

select is(
  (select weight from public.payment_gateways where name_en = 'Nagad one'),
  1,
  'weight defaults to one share'
);

select throws_ok(
  $$update public.payment_gateways set weight = 0 where name_en = 'Nagad one'$$,
  '23514',
  'new row for relation "payment_gateways" violates check constraint "payment_gateways_weight_at_least_one"',
  'a zero weight is refused by the constraint'
);

select throws_ok(
  $$update public.payment_gateways set weight = -3 where name_en = 'Nagad one'$$,
  '23514',
  'new row for relation "payment_gateways" violates check constraint "payment_gateways_weight_at_least_one"',
  'and so is a negative one'
);

select test_data.as_user(test_data.owner());

select throws_ok(
  $$select api.admin_upsert_gateway(
      jsonb_build_object('kind', 'rocket', 'name_en', 'Rocket', 'weight', 0))$$,
  '22023',
  'weight must be at least 1; use is_active to disable a payment method',
  'the admin form is told which field to fix rather than getting a constraint violation'
);

select is(
  (api.admin_upsert_gateway(
     jsonb_build_object('kind', 'rocket', 'name_en', 'Rocket', 'weight', 4))).weight,
  4,
  'and an explicit weight is stored'
);

select is(
  (api.admin_upsert_gateway(jsonb_build_object('kind', 'rocket', 'name_en', 'Rocket'))).weight,
  1,
  'an omitted weight means one share, so saving an untouched form cannot quietly rebalance traffic'
);

-- ---------------------------------------------------------------------------
-- The draw
-- ---------------------------------------------------------------------------
--
-- Weights 1 and 9 out of a total of 10, so the heavy account should take 0.9 of the
-- traffic. At 2000 draws the standard deviation of that share is about 0.0067, so the
-- 0.85/0.95 band is roughly seven standard deviations wide: it cannot fail by chance, and it
-- fails immediately if the draw is inverted. Sorting on `random() * weight` reads like a
-- weighted draw and in fact picks the *lightest* account, which is why the direction of this
-- assertion matters as much as its existence.

select ok(
  test_data.draw_share('bkash', 'bKash heavy', 2000) between 0.85 and 0.95,
  'a gateway weighted 9 is drawn about nine times as often as one weighted 1'
);

select ok(
  test_data.draw_share('bkash', 'bKash light', 2000) between 0.02 and 0.15,
  'and its neighbour is left the small remainder'
);

select ok(
  test_data.draw_share('nagad', 'Nagad one', 2000) between 0.45 and 0.55,
  'two accounts of equal weight split the traffic evenly'
);

select is(
  (private.pick_gateway_for_kind('bkash')).kind,
  'bkash',
  'the draw only ever answers with an account of the kind asked for'
);

select is(
  (private.pick_gateway_for_kind('no-such-kind')).id,
  null,
  'and with nothing at all when no active account has that kind'
);

update public.payment_gateways set is_active = false where name_en = 'bKash heavy';

select is(
  test_data.draw_share('bkash', 'bKash heavy', 500),
  0::numeric,
  'an account switched off is never drawn, however heavily it was weighted'
);

update public.payment_gateways set is_active = true where name_en = 'bKash heavy';

-- ---------------------------------------------------------------------------
-- One kind, one way of paying
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.payment_gateways
       (kind, provider, name_en, account_number, account_name, evidence_fields)
     values ('bkash', 'bkash_pgw', 'bKash instant', '01700000006', 'Cofibuy', '[]'::jsonb)$$,
  '23514',
  'kind "bkash" already has an active manual payment method; one kind cannot be both manual and automatic',
  'an automatic account cannot join a kind that is already served by hand'
);

-- Switching an automatic account to manual is the one write that would otherwise match the
-- row against itself: the stored row is automatic and the incoming one is manual, so the two
-- "disagree" about a kind with a single member. Refusing it would make it impossible to take
-- a kind off automatic at all.
select lives_ok(
  $$update public.payment_gateways
       set provider = null, name_en = 'bKash instant', is_active = false
     where name_en = 'bKash instant'$$,
  'and an automatic account can be turned manual once it is out of the way'
);

select lives_ok(
  $$update public.payment_gateways set is_active = true where name_en = 'bKash instant'$$,
  'reactivating it as a manual account of the same kind is then allowed'
);

-- The guard is about the two modes disagreeing, not about how many accounts there are. A
-- second *manual* account of the same kind is exactly the weighted split this change adds,
-- so it has to be allowed; refusing it would make `weight` meaningless for manual methods.
select lives_ok(
  $$insert into public.payment_gateways
       (kind, name_en, account_number, account_name, evidence_fields)
     values ('bkash', 'bKash second', '01700000009', 'Cofibuy', '[]'::jsonb)$$,
  'a second manual account of the same kind is the weighted split, so it is allowed'
);

select throws_ok(
  $$insert into public.payment_gateways
       (kind, provider, name_en, account_number, account_name, evidence_fields)
     values ('bkash', 'bkash_pgw', 'bKash instant again', '01700000010', 'Cofibuy', '[]'::jsonb)$$,
  '23514',
  'kind "bkash" already has an active manual payment method; one kind cannot be both manual and automatic',
  'but an automatic one still cannot join them'
);

-- ---------------------------------------------------------------------------
-- The customer's order
-- ---------------------------------------------------------------------------

select test_data.as_user(test_data.new_user());

select throws_ok(
  $$select api.create_order('guide', 'no-such-kind', 500)$$,
  'P0002',
  'payment method not found',
  'a kind with no active account cannot be ordered'
);

select is(
  api.create_order('guide', 'bkash', 750) ->> 'ok',
  'true',
  'an order starts from the kind alone'
);

-- The kind is pinned by the open order. Re-pointing it would leave the customer holding a
-- transfer receipt for an account nobody is watching, so the mismatch is refused with a token
-- a client can branch on rather than an envelope it would retry forever.
select throws_ok(
  $$select api.create_order('guide', 'bank', 750)$$,
  '22023',
  'kind_mismatch: open order already uses payment kind bkash',
  'switching kind on an open order is refused with a machine-readable token'
);

select is(
  (select count(*)::int from public.orders where user_id = test_data.customer_of('guide')),
  1,
  'and the refused attempt did not open a second order'
);

select is(
  (select g.kind from public.orders o
     join public.payment_gateways g on g.id = o.gateway_id
    where o.user_id = test_data.customer_of('guide')),
  'bkash',
  'the order is still pinned to the account it was opened against'
);

select is(
  (select api.my_order_status(test_data.order_for_customer('guide')) -> 'gateway' ->> 'account_number'
     in (select account_number from public.payment_gateways where kind = 'bkash')),
  true,
  'the order reveals the account number the money is going to, to the customer who placed it'
);

select test_data.as_user(test_data.new_user());

select throws_ok(
  $$select api.my_order_status(test_data.order_for_customer('guide'))$$,
  'P0002',
  'order not found',
  'and to nobody else'
);

-- ---------------------------------------------------------------------------
-- The resolver stays internal
-- ---------------------------------------------------------------------------
--
-- `create_order` resolves the kind and takes the order for it. The resolver is the step
-- underneath, and a client able to call it directly would choose the account rather than the
-- shop, which is the whole thing this change moved away from.

select is(
  test_data.can_execute('authenticated', 'api.create_order(text,text,numeric)'),
  true,
  'the customer-facing entry point is callable'
);

select is(
  test_data.can_execute('authenticated', 'api.create_order_resolved(text,text,numeric)'),
  false,
  'the resolver underneath it is not'
);

select is(
  test_data.can_execute('anon', 'api.create_order_resolved(text,text,numeric)'),
  false,
  'nor is it callable by an anonymous visitor'
);

-- The old three-argument form took a gateway id, which is what let a client pick the
-- account. Leaving it callable under the old name would keep that door open.
select throws_ok(
  $$select api.create_order('guide', gen_random_uuid(), 500)$$,
  '42883',
  'function api.create_order(unknown, uuid, integer) does not exist',
  'and the old gateway-id signature is gone'
);

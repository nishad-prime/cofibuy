-- 07_rls.sql
--
-- Everything above this file tested what the functions decide. This tests what
-- the database lets a role reach at all, which is the half that cannot be fixed
-- by a guard inside a function.
--
-- It has to be done with `set local role`. A JWT claim is an opinion the
-- functions read; a grant is enforced by the engine. The tests run as the
-- superuser that owns every object, so a claim-only impersonation would
-- cheerfully read `public.orders` and prove nothing.

set client_min_messages = warning;
set application_name = 'test-07-rls';

select plan(44);

-- ---------------------------------------------------------------------------
-- Nothing sensitive is reachable as a table
-- ---------------------------------------------------------------------------

-- The orders table holds the phone number a payment was made from, which is the
-- whole basis of recovery. A customer who could read it could recover somebody
-- else's account by guessing, without ever receiving a code.
select is(
  test_data.as_role('authenticated', 'select * from public.orders') ->> 'state',
  '42501',
  'a customer cannot read the orders table'
);

select is(
  test_data.as_role('anon', 'select * from public.orders') ->> 'state',
  '42501',
  'and neither can the public'
);

select is(
  test_data.as_role('authenticated', 'select * from public.order_evidence') ->> 'state',
  '42501',
  'nor the evidence behind an order'
);

select is(
  test_data.as_role('authenticated', 'select * from public.access_grants') ->> 'state',
  '42501',
  'nor who has been granted access'
);

select is(
  test_data.as_role('authenticated', 'select * from public.customer_contacts') ->> 'state',
  '42501',
  'nor the phone numbers on file'
);

select is(
  test_data.as_role('authenticated', 'select * from public.staff') ->> 'state',
  '42501',
  'nor who works here'
);

select is(
  test_data.as_role('authenticated', 'select * from public.audit_log') ->> 'state',
  '42501',
  'nor the audit log'
);

-- The recovery tables are the ones a staff account has no business reading
-- either. The worker reaches them through three functions, not through SQL.
select is(
  test_data.as_role('authenticated', 'select * from public.recovery_requests') ->> 'state',
  '42501',
  'nor the recovery requests'
);

select is(
  test_data.as_role('authenticated', 'select * from public.otp_challenges') ->> 'state',
  '42501',
  'nor the code hashes'
);

-- The internal functions are schema-private and the schema is not even
-- reachable. `gen_reference_code` and `otp_matches` have no guard of their own,
-- so the schema is what stops them.
select is(
  test_data.as_role('authenticated', 'select private.gen_reference_code()') ->> 'state',
  '42501',
  'nor the internal functions'
);

select is(
  test_data.as_role('anon', 'select private.gen_reference_code()') ->> 'state',
  '42501',
  'and the schema is closed to the public as well'
);

-- ---------------------------------------------------------------------------
-- The catalogue is public, but only its published half
-- ---------------------------------------------------------------------------

select is(
  test_data.as_role('anon', 'select slug from public.pages_public') ->> 'ok',
  'true',
  'the published links are readable by anyone'
);

-- The account number used to be readable by anyone, which made the paywall's careful
-- trimming of `account_fields` worth nothing: `select account_number from
-- payment_gateways_public` handed a visitor every account the shop owns, and the customer
-- picking a method was picking from accounts belonging to every other customer. The
-- destination is released by the order instead, to the person who placed it.
select is(
  test_data.as_role('anon', 'select account_number from public.payment_gateways_public') ->> 'state',
  '42703',
  'the destination is not readable through the public gateway view'
);

select is(
  test_data.as_role('anon', 'select account_number from public.payment_gateways') ->> 'state',
  '42501',
  'nor off the base table behind it'
);

select is(
  test_data.as_role('anon', 'select account_fields from public.payment_gateways') ->> 'state',
  '42501',
  'and the resolved field values are gone the same way'
);

-- The method list itself is still public, or the paywall has nothing to render.
select is(
  (test_data.as_role('anon', 'select count(*)::int as n from public.payment_gateways_public') ->> 'rows'),
  format('[{"n": %s}]', (select count(*) from public.payment_gateways where is_active)::int),
  'while the method list stays public'
);

-- The base table is granted a column list, and the two columns that decide
-- whether a minimum is hidden are not on it. Reading the table therefore
-- cannot reveal the threshold the API is at such lengths to withhold.
select is(
  test_data.as_role('authenticated', 'select min_amount_override from public.pages') ->> 'state',
  '42501',
  'a private minimum override is not a readable column'
);

select is(
  test_data.as_role('authenticated', 'select hide_min_override from public.pages') ->> 'state',
  '42501',
  'and neither is the flag that hides it'
);

select is(
  test_data.as_role('authenticated', 'select unlock_body_md_en from public.pages') ->> 'state',
  '42501',
  'nor the paid body, which is what the grant is for'
);

-- RLS is what reduces the granted columns to published rows. A draft link has
-- every column a customer is entitled to read, so without a policy it would
-- appear in the list; the policy is the only thing hiding it.
select test_data.reset();
select test_data.link('published', 500, false);
select test_data.link('draft', 500, false, false);
select test_data.as_anon();

select is(
  (test_data.as_role('anon', 'select slug from public.pages_public order by slug') ->> 'rows')::text,
  '[{"slug": "published"}]',
  'a draft link is readable in the base table but not in the published list'
);

select is(
  (test_data.as_role('anon', 'select count(*)::int as n from public.pages') ->> 'rows')::text,
  '[{"n": 1}]',
  'and the row itself is filtered, not just omitted from the view'
);

-- ---------------------------------------------------------------------------
-- The grant surface of the api schema
-- ---------------------------------------------------------------------------

-- Everything a customer needs, and nothing that reads another customer.
select is(
  test_data.can_execute('anon', 'api.list_public_pages()'),
  true,
  'the catalogue is callable by the public'
);

select is(
  test_data.can_execute('authenticated', 'api.create_order(text,text,numeric)'),
  true,
  'and ordering is callable by a customer'
);

select is(
  test_data.can_execute('anon', 'api.create_order(text,text,numeric)'),
  false,
  'but not by the public, who cannot pay for anything'
);

select is(
  test_data.can_execute('authenticated', 'api.get_unlocked_page(text)'),
  true,
  'a customer can read what they have paid for'
);

select is(
  test_data.can_execute('anon', 'api.get_unlocked_page(text)'),
  false,
  'and the public cannot try'
);

-- The panel needs a session, so `authenticated` is the only role it is granted
-- to. The checks inside are what make staff a subset rather than the whole of
-- it; 05 holds each function to a customer and a service key.
select is(
  test_data.can_execute('authenticated', 'api.admin_orders(text,text,integer)'),
  true,
  'a signed-in user can reach the panel functions'
);

select is(
  test_data.can_execute('anon', 'api.admin_orders(text,text,integer)'),
  false,
  'but the public cannot'
);

-- The worker surface, which is the one place a phone number is handed out in
-- bulk. Narrower than anything else in the file by design.
select is(
  test_data.can_execute('service_role', 'api.claim_pending_recovery(integer)'),
  true,
  'the worker can claim pending requests'
);

select is(
  test_data.can_execute('authenticated', 'api.claim_pending_recovery(integer)'),
  false,
  'a customer cannot'
);

select is(
  test_data.can_execute('service_role', 'api.record_otp_sent(uuid,text,integer)'),
  true,
  'the worker can record a code'
);

select is(
  test_data.can_execute('authenticated', 'api.record_otp_sent(uuid,text,integer)'),
  false,
  'a customer cannot'
);

select is(
  test_data.can_execute('service_role', 'api.mark_undeliverable(uuid,text)'),
  true,
  'the worker can record an unreachable number'
);

select is(
  test_data.can_execute('authenticated', 'api.mark_undeliverable(uuid,text)'),
  false,
  'a customer cannot'
);

-- The sweep functions are not granted to anybody: housekeeping runs from
-- pg_cron, which connects as the owner.
select is(
  test_data.can_execute('authenticated', 'private.sweep()'),
  false,
  'the sweeps are not callable by a customer'
);

select is(
  test_data.can_execute('service_role', 'private.sweep()'),
  false,
  'nor by the worker'
);

-- ---------------------------------------------------------------------------
-- Proofs
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.as_subject('a');
select test_data.orders('guide', 'bKash', 750, 'a') ->> 'ok';

-- A screenshot folder that leaked would hand over other people's bank records,
-- so what is readable in the bucket matters as much as whether it can be listed.
select is(
  (test_data.as_role('authenticated', 'select name from storage.objects where bucket_id = ''proofs''') ->> 'ok')::text,
  'true',
  'a customer can list the proofs bucket'
);

select is(
  (test_data.as_role('authenticated', 'select name from storage.objects where bucket_id = ''proofs''') ->> 'rows')::text,
  '[]',
  'and this session sees nothing in it, having uploaded nothing'
);

-- The read policy is keyed on auth.uid() and on private.is_staff(), which is the
-- review path. Neither of those can be exercised here: a JWT claim and a
-- database role are set separately, and a test can only change one at a time. So
-- the policy is asserted as written rather than run.
select is(
  (
    select qual ~ 'auth.uid'
    from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'proofs_read_own_or_staff'
  )::text,
  'true',
  'the read policy is keyed on the caller'
);

select is(
  (
    select qual ~ 'is_staff'
    from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'proofs_read_own_or_staff'
  )::text,
  'true',
  'or on being somebody who reviews orders'
);

-- The insert policy is the second line of defence for a path. The evidence
-- validator refuses a shape the policy would not have written, and the policy
-- refuses one the validator would have had to take on trust.
select is(
  (
    select count(*)
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'proofs_insert_own_folder'
  )::int,
  1,
  'an insert policy guards the proofs folder'
);

select is(
  (
    select with_check ~ 'auth.uid'
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'proofs_insert_own_folder'
  )::text,
  'true',
  'and the first folder in the path must be the caller''s own'
);

-- No update or delete policy exists for the proofs bucket. Evidence is
-- append-only: a corrected screenshot is a new upload under a new attempt, so
-- the one that was reviewed has to stay exactly as it was. Page art is a
-- different bucket with its own rules - the operator may replace an image -
-- so the count is scoped to the proofs policies rather than the table.
select is(
  (
    select count(*)
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'proofs_%'
      and cmd in ('UPDATE', 'DELETE')
  )::int,
  0,
  'and nothing may edit or remove an uploaded screenshot'
);

-- The bucket itself is private. A signed URL is minted by the server for one
-- object at a time, so the bucket cannot be walked.
select is(
  (select public from storage.buckets where id = 'proofs')::text,
  'false',
  'and the proofs bucket is not public'
);

select * from finish();

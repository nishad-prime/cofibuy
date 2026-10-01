-- Test fixtures.
--
-- Every test file calls `test_data.reset()` first, so the order in which files
-- run cannot change the result and each file is readable on its own.
--
-- Auth impersonation goes through the same GUCs PostgREST sets, so a test
-- exercises the real code path: `auth.uid()` returns the caller's id because a
-- request really does carry that claim.

create schema if not exists test_data;

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- A fresh customer. The `auth.users` row exists because `staff` and `orders`
-- reference it, and because a customer with no auth row is not a state the app
-- can actually reach.
create or replace function test_data.new_user()
returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id) values (v_id);
  return v_id;
end
$$;

-- The OTP worker. It calls as `service_role`, so it has no user claim of its own
-- in production; the row exists only so an FK would fire if a worker function
-- ever started writing one.
create or replace function test_data.new_service_user()
returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id) values (v_id);
  return v_id;
end
$$;

create or replace function test_data.as_user(p_id uuid, p_role text default 'authenticated')
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_id::text, ''), true);
  perform set_config('request.jwt.claim.role', coalesce(p_role, 'anon'), true);
end
$$;

-- Named separately from a null argument to `test_data.as_user`, so returning to
-- anonymous is a deliberate call rather than an oversight.
create or replace function test_data.as_anon()
returns void
language plpgsql
as $$
begin
  perform test_data.as_user(null, 'anon');
end
$$;

create or replace function test_data.as_service()
returns void
language plpgsql
as $$
begin
  perform test_data.as_user(test_data.new_service_user(), 'service_role');
end
$$;

-- What `p_sql` does when the database role is `p_role`, as PostgREST would run
-- it: the JWT claims already say who is asking, and this is the half that
-- decides what that identity is allowed to see.
--
-- Errors are returned rather than raised, because "refused" and "sees nothing"
-- are both answers a caller can give and both are worth asserting. The role is
-- always handed back, so a failure partway through leaves the session where it
-- found it and the next file is unaffected.
create or replace function test_data.as_role(p_role text, p_sql text)
returns jsonb
language plpgsql
as $$
declare
  v_out jsonb;
  v_state text;
  v_message text;
begin
  begin
    execute format('set local role %I', p_role);
    execute
      format('select coalesce(jsonb_agg(to_jsonq), ''[]''::jsonb) from (%s) as to_jsonq', p_sql)
      into v_out;
    v_state := null;
  exception
    when others then
      v_state := sqlstate;
      v_message := sqlerrm;
  end;

  execute 'set local role postgres';

  return jsonb_build_object(
    'ok', v_state is null,
    'rows', coalesce(v_out, '[]'::jsonb),
    'state', v_state,
    'message', v_message
  );
end
$$;

-- Whether `p_role` may execute `p_fn` at all.-- Whether `p_role` may execute `p_fn` at all.
--
-- The tests impersonate by setting JWT claims, which is what the functions read
-- through auth.uid() and auth.role(). That is only half of what PostgREST does:
-- it also runs the call as the database role named in the token, and it is the
-- database role that `revoke` and `grant` act on. These tests run as the
-- superuser who owns everything, so a claim-only impersonation would happily
-- execute a function that no real customer could reach.
--
-- Asking the catalog directly is the honest way to check that, and 07 asserts
-- the whole grant surface this way.
create or replace function test_data.can_execute(p_role text, p_fn text)
returns boolean
language sql
stable
as $$
  select has_function_privilege(p_role, p_fn, 'execute')
$$;

-- Grants a role, which is the same act `api.admin_set_staff` performs. Used to
-- arrange a test, never to grant the very access under test.
create or replace function test_data.staff(p_user uuid, p_role text default 'staff')
returns public.staff
language plpgsql
as $$
declare
  v_staff public.staff;
begin
  insert into public.staff (user_id, role) values (p_user, p_role::public.staff_role) returning * into v_staff;
  return v_staff;
end
$$;

-- A customer who is also staff. The panel and the storefront share one session.
create or replace function test_data.new_staff(p_role text default 'staff')
returns uuid
language plpgsql
as $$
declare
  v_id uuid := test_data.new_user();
begin
  perform test_data.staff(v_id, p_role);
  return v_id;
end
$$;

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------

-- A published link. The unlock body is required by the publishable check, so a
-- fixture that omitted it would not be a state the app allows.
create or replace function test_data.link(
  p_slug text default 'guide',
  p_min numeric default null,
  p_hide_min boolean default null,
  p_active boolean default true
)
returns public.paywall_links
language plpgsql
as $$
declare
  v_link public.paywall_links;
begin
  insert into public.paywall_links (
    slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
    unlock_body_md_en, unlock_body_md_bn, min_amount_override, hide_min_override, is_active
  )
  values (
    p_slug, 'Field Guide', 'ফিল্ড গাইড', 'Teaser text.', 'টিজার লেখা।',
    'The full guide.', 'পূর্ণ গাইড।', p_min, p_hide_min, p_active
  )
  returning * into v_link;
  return v_link;
end
$$;

-- A gateway asking for the three things a manual bKash payment has to prove:
-- who sent it, how much, and which transaction it was. `sender_number` carries
-- the `bd_phone` validator, which is what makes the phone double as the
-- recovery identity.
create or replace function test_data.gateway(
  p_kind public.gateway_kind default 'bkash',
  p_fields jsonb default null,
  p_active boolean default true
)
returns public.payment_gateways
language plpgsql
as $$
declare
  v_gateway public.payment_gateways;
begin
  insert into public.payment_gateways (
    kind, name_en, name_bn, account_number, account_name,
    supports_reference, evidence_fields, is_active
  )
  values (
    p_kind,
    case p_kind when 'nagad' then 'Nagad' when 'bank' then 'Bank' else 'bKash' end,
    case p_kind when 'nagad' then 'নগদ' when 'bank' then 'ব্যাংক' else 'বিকাশ' end,
    '01700000000',
    'Cofibuy',
    true,
    coalesce(
      p_fields,
      '[{"key":"sender_number","type":"text","label_en":"Sender number","required":true,"validate":"bd_phone","max_len":20},
        {"key":"amount","type":"number","label_en":"Amount sent","required":true,"validate":"numeric"},
        {"key":"trxid","type":"text","label_en":"TrxID","required":true,"validate":"trxid","max_len":24},
        {"key":"screenshot","type":"image","label_en":"Screenshot","required":false,"max_mb":4}]'::jsonb
    ),
    p_active
  )
  returning * into v_gateway;
  return v_gateway;
end
$$;

-- ---------------------------------------------------------------------------
-- Reset
-- ---------------------------------------------------------------------------

-- Wipes everything, in an order the constraints allow. Both re-seeded rows are
-- preconditions rather than fixtures: `site_settings` is a singleton every
-- function reads with a literal `id = 1`, and `create_order` needs an active
-- gateway to exist at all.
create or replace function test_data.reset()
returns void
language plpgsql
as $$
begin
  perform test_data.as_anon();

  truncate table
    public.audit_log,
    public.otp_challenges,
    public.recovery_requests,
    public.customer_contacts,
    public.access_grants,
    public.order_evidence,
    public.orders,
    public.paywall_links,
    public.payment_gateways,
    public.staff,
    public.site_settings
  restart identity cascade;

  truncate table test_data.subject;

  insert into public.site_settings (id) values (1);
end
$$;

-- Recovery is gated behind a setting precisely so shipping the UI before the
-- worker cannot strand anyone. Tests that exercise it have to say so.
create or replace function test_data.enable_recovery()
returns void
language sql
as $$
  update public.site_settings set recovery_enabled = true where id = 1
$$;

-- ---------------------------------------------------------------------------
-- Calling as a customer
--
-- These take the identity change out of the test body. A test that has to
-- interleave `as_user` calls with the calls it is actually testing reads as two
-- interleaved stories, and it is easy to leave one customer impersonated while
-- believing you are testing another.
-- ---------------------------------------------------------------------------

-- The customer a multi-statement test is currently about.
--
-- SQL has no variables that survive a statement, so "the same person, one more
-- time" would otherwise mean threading a uuid through every call. This is a
-- one-row table for exactly that.
create table if not exists test_data.subject (slot text primary key, id uuid not null);

-- A fresh customer, remembered under a slot. A test that needs two people at
-- once — two orders sharing a TrxID, a customer and somebody else's account —
-- names the slots, instead of the fragile habit of "whichever row was first".
create or replace function test_data.new_subject(p_slot text default 'a')
returns uuid
language plpgsql
as $$
declare
  v_id uuid := test_data.new_user();
begin
  insert into test_data.subject (slot, id) values (p_slot, v_id)
  on conflict (slot) do update set id = excluded.id;
  return v_id;
end
$$;

create or replace function test_data.subject_id(p_slot text default 'a')
returns uuid
language sql
stable
as $$
  select id from test_data.subject where slot = p_slot
$$;

-- A staff account, remembered the same way, so a test can ask what a reviewer
-- sees without holding a uuid across statements.
create or replace function test_data.reviewer(p_role text default 'staff')
returns uuid
language plpgsql
as $$
declare
  v_id uuid := test_data.new_user();
begin
  perform test_data.staff(v_id, p_role);
  insert into test_data.subject (slot, id) values ('staff', v_id)
  on conflict (slot) do update set id = excluded.id;
  return v_id;
end
$$;

-- Impersonates the named slot, or returns to being nobody.
create or replace function test_data.as_subject(p_slot text default 'a')
returns void
language plpgsql
as $$
begin
  if p_slot = 'anon' then
    perform test_data.as_anon();
  else
    perform test_data.as_user(test_data.subject_id(p_slot));
  end if;
end
$$;

-- Creates an order as a brand-new customer and returns the response.
create or replace function test_data.new_customer_orders(
  p_slug text,
  p_gateway text,
  p_amount numeric
)
returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform test_data.as_user(test_data.new_user());
  select api.create_order(
    p_slug,
    (select id from public.payment_gateways where name_en = p_gateway),
    p_amount
  )
  into v_result;
  perform test_data.as_anon();
  return v_result;
end
$$;

-- Creates an order as an existing customer. This is how a test says "the same
-- person, one more time", which is the case the probe counter and the one-open-
-- order index are actually about.
create or replace function test_data.customer_orders(
  p_user uuid,
  p_slug text,
  p_gateway text,
  p_amount numeric
)
returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform test_data.as_user(p_user);
  select api.create_order(
    p_slug,
    (select id from public.payment_gateways where name_en = p_gateway),
    p_amount
  )
  into v_result;
  perform test_data.as_anon();
  return v_result;
end
$$;

-- Creates an order as the current subject. The common case.
create or replace function test_data.orders(
  p_slug text,
  p_gateway text,
  p_amount numeric,
  p_slot text default 'a'
)
returns jsonb
language sql
as $$
  select test_data.customer_orders(test_data.subject_id(p_slot), p_slug, p_gateway, p_amount)
$$;

create or replace function test_data.order_for(p_user uuid)
returns public.orders
language sql
stable
as $$
  select *
  from public.orders
  where user_id = p_user
  order by created_at desc, id
  limit 1
$$;

-- The id of the order the subject most recently started, for assertions that care
-- about the row rather than the response.
create or replace function test_data.subject_order(p_slot text default 'a')
returns public.orders
language sql
stable
as $$
  select * from test_data.order_for(test_data.subject_id(p_slot))
$$;

-- Submits exactly the fields given, so a test can leave one out. Everything else
-- about the call — who is asking, which order — still comes from the fixture.
create or replace function test_data.submit_fields(
  p_user uuid,
  p_order_id uuid,
  p_fields jsonb,
  p_files jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
as $$
declare
  v_result jsonb;
begin
  perform test_data.as_user(p_user);
  select api.submit_evidence(p_order_id, p_fields, p_files) into v_result;
  perform test_data.as_anon();
  return v_result;
end
$$;

-- Submits a complete, valid set of evidence for an order and returns the
-- response. `p_extras` and `p_files` are merged over the defaults so a test can
-- drop, replace, or add a single field without restating the rest.
create or replace function test_data.submit(
  p_user uuid,
  p_order_id uuid,
  p_extras jsonb default '{}'::jsonb,
  p_files jsonb default '{}'::jsonb
)
returns jsonb
language sql
as $$
  select test_data.submit_fields(
    p_user,
    p_order_id,
    '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9"}'::jsonb || p_extras,
    p_files
  )
$$;

-- A file sitting in the proofs bucket, at the path shape the storage policies
-- require. `p_owner` defaults to the uploader; set it to someone else to arrange
-- an object that exists but does not belong to the customer submitting it.
create or replace function test_data.proof(
  p_user uuid,
  p_order_id uuid,
  p_key text default 'screenshot',
  p_ext text default 'png',
  p_owner uuid default null
)
returns text
language plpgsql
as $$
declare
  v_name text :=
    p_user::text || '/' || p_order_id::text || '/' || p_key || '/'
    || gen_random_uuid()::text || '.' || p_ext;
begin
  insert into storage.objects (bucket_id, name, owner_id)
  values ('proofs', v_name, coalesce(p_owner, p_user));
  return v_name;
end
$$;

-- What was recorded for one field on one attempt.
create or replace function test_data.evidence(p_order_id uuid, p_key text, p_attempt integer default 1)
returns public.order_evidence
language sql
stable
as $$
  select *
  from public.order_evidence
  where order_id = p_order_id and field_key = p_key and attempt = p_attempt
$$;

-- How many evidence rows an attempt recorded. A field that was never sent is not
-- a row, so this also answers "was that field accepted".
create or replace function test_data.evidence_count(p_order_id uuid, p_attempt integer default 1)
returns integer
language sql
stable
as $$
  select count(*)::int from public.order_evidence where order_id = p_order_id and attempt = p_attempt
$$;

-- An order in `under_review`, with evidence already attached. The starting point
-- for anything about review.
create or replace function test_data.submitted_order(
  p_user uuid default null,
  p_slug text default 'guide',
  p_gateway text default 'bKash',
  p_trxid text default 'ABC123XYZ9',
  p_amount numeric default 750
)
returns public.orders
language plpgsql
as $$
declare
  v_user uuid := coalesce(p_user, test_data.new_user());
  v_result jsonb;
  v_order public.orders;
begin
  v_result := test_data.customer_orders(v_user, p_slug, p_gateway, p_amount);
  select * into v_order from public.orders where id = (v_result ->> 'order_id')::uuid;
  perform test_data.submit(v_user, v_order.id, jsonb_build_object('trxid', p_trxid));
  select * into v_order from public.orders where id = v_order.id;
  return v_order;
end
$$;

-- Reviews an order as a member of staff, leaving the caller impersonated as
-- nobody so a test cannot accidentally attribute the next call to the reviewer.
create or replace function test_data.reviewed_by_staff(
  p_order_id uuid,
  p_action text,
  p_reason text default null,
  p_role text default 'staff'
)
returns jsonb
language plpgsql
as $$
declare
  v_reviewer uuid := test_data.new_staff(p_role);
  v_result jsonb;
begin
  perform test_data.as_user(v_reviewer);
  if p_action = 'approve' then
    select api.approve_order(p_order_id) into v_result;
  else
    select api.reject_order(p_order_id, p_reason) into v_result;
  end if;
  perform test_data.as_anon();
  return v_result;
end
$$;

grant usage on schema test_data to anon, authenticated, service_role;
grant execute on all functions in schema test_data to anon, authenticated, service_role;

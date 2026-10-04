-- bKash PGW (Tokenized Checkout v2): automated payment capture
--
-- bKash already exists here as a *manual* method: the customer is shown an account
-- number, sends money from their own wallet, and uploads a screenshot and TrxID for
-- staff to check. `gateway_kind` has carried 'bkash' since the first migration and
-- nothing about this file changes that.
--
-- What this adds is the other bKash product, Tokenized Checkout: the merchant creates
-- a payment, the customer pays on bKash's own page, and bKash reports the outcome to
-- the server. Both stay available. The manual method costs the seller no PGW fee and
-- keeps working if a credential is wrong or bKash is down, so it is not a fallback
-- being deprecated - it is a second thing a seller may legitimately offer.
--
-- Three things shape the design.
--
--   1. A bKash `paymentId` may be executed exactly once. After one execute attempt it
--      cannot be retried whatever the outcome, so every write here is idempotent and
--      the authoritative answer after any doubt is Query Payment, not a second Execute.
--
--   2. The `status=success` on bKash's return URL is the customer's browser making the
--      claim, not bKash. Nothing in this schema treats it as proof; settlement happens
--      only after the server has confirmed the payment itself.
--
--   3. Grant and Refresh Token may each be called at most twice an hour, and exceeding
--      that blocks refreshes for a full hour - i.e. it stops the shop taking payments.
--      So the token is cached in the database rather than per Edge Function instance,
--      and refresh is behind a lease so concurrent callers cannot storm the endpoint.

-- ---------------------------------------------------------------------------
-- Gateway: brand versus mechanism
-- ---------------------------------------------------------------------------

-- `kind` stays the brand ('bkash'), which is what the admin form and the customer's
-- method list already speak. `provider` is the mechanism, and null means the manual
-- evidence flow. A gateway is either "show a number and review a screenshot" or "hand
-- off to bKash and settle on confirmation", and nothing in between, so null is a real
-- value here rather than a placeholder.
alter table public.payment_gateways
  add column provider text;

comment on column public.payment_gateways.provider is
  'Automated capture backend. null = manual evidence flow. Only automated gateways need '
  'an account number, so the admin form clears the evidence schema when this is set.';

-- An allowlist rather than a free string: the settlement RPC trusts this value to pick
-- a payment backend, so a typo must fail here rather than reach an HTTP call.
alter table public.payment_gateways
  add constraint payment_gateways_provider_known
  check (provider is null or provider = 'bkash_pgw');

-- A gateway that captures automatically has nothing to review, so asking for evidence
-- on it would show customers a TrxID box they do not need and staff a queue they can
-- only clear by hand. An automated gateway with evidence fields is a configuration
-- mistake, and this is where it is caught rather than at checkout.
alter table public.payment_gateways
  add constraint payment_gateways_automatic_has_no_evidence
  check (provider is null or evidence_fields = '[]'::jsonb);

-- ---------------------------------------------------------------------------
-- Payment sessions
-- ---------------------------------------------------------------------------

create table public.payment_sessions (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  provider text not null,
  provider_payment_id text not null,
  provider_trx_id text,
  provider_account text,
  status text not null default 'initiated',
  amount numeric(12, 2) not null,
  currency text not null default 'BDT',
  created_at timestamptz not null default now(),
  executed_at timestamptz,

  constraint payment_sessions_provider_known check (provider = 'bkash_pgw'),
  constraint payment_sessions_status_known
    check (status in ('initiated', 'completed', 'failed')),
  constraint payment_sessions_amount_positive check (amount > 0),

  -- bKash takes BDT only. The store currency is a setting across eleven codes, so this
  -- is the place that says "this backend cannot serve this shop" instead of leaving it
  -- to a failed API call at checkout.
  constraint payment_sessions_currency_bdt check (currency = 'BDT'),

  -- A completed session is a claim that money moved. Requiring the TrxID means a row
  -- cannot be marked settled by a caller that forgot to record what settled it.
  constraint payment_sessions_trx_required_when_completed
    check (status <> 'completed' or provider_trx_id is not null),

  -- bKash payment IDs are opaque and 24 characters at most; this only rejects values
  -- that cannot be one, rather than pinning a format bKash has never documented.
  constraint payment_sessions_payment_id_shape
    check (provider_payment_id ~ '^[A-Za-z0-9_-]{1,64}$')
);

comment on table public.payment_sessions is
  'One row per provider payment attempt. Exists so a bKash paymentId is recorded before '
  'the customer leaves for bKash, which is what makes an abandoned checkout '
  'reconcilable against bKash''s own records.';

-- One bKash payment maps to exactly one session. This is the idempotency key for the
-- whole integration: a repeated callback, a retried request, or two workers racing all
-- collide here rather than creating a second attempt at settling the same money.
create unique index payment_sessions_payment_id_key
  on public.payment_sessions (provider, provider_payment_id);

-- At most one completed session per order, so access is granted for exactly one
-- payment. If a customer genuinely pays twice, the second completion is refused here
-- and surfaces to staff as money received against an order already settled - which is
-- a refund conversation, not something to silently credit.
create unique index payment_sessions_one_completed_per_order
  on public.payment_sessions (order_id)
  where status = 'completed';

-- The same bKash transaction cannot settle two orders. This is the invariant that stops
-- a replayed or mis-pasted TrxID from buying the same content twice.
create unique index payment_sessions_trx_unique
  on public.payment_sessions (provider_trx_id)
  where provider_trx_id is not null;

create index payment_sessions_by_order_idx
  on public.payment_sessions (order_id, created_at desc);

-- Reconciliation: "which bKash transactions do we not have an order for?" runs off
-- merchantInvoiceNumber, which is the order's reference_code.
create index payment_sessions_by_invoice_idx
  on public.payment_sessions (provider_payment_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Token cache
-- ---------------------------------------------------------------------------
--
-- Grant/Refresh Token are capped at two calls an hour between them and going over
-- blocks refresh for an hour, which would mean the shop silently stops accepting
-- payments. Caching in the database rather than in an Edge Function's memory is the
-- difference between honouring that limit and breaching it: functions cold-start, run
-- in several instances, and two checkouts arriving together would each fetch a token.
--
-- private, because id_token and refresh_token are merchant credentials in effect - the
-- refresh token alone can mint new access tokens for 30 days.

create table private.bkash_tokens (
  environment text primary key,
  id_token text not null,
  refresh_token text not null,
  expires_at timestamptz not null,

  -- Lease held while one caller rotates the token. Not a lock: an HTTP call to bKash
  -- happens outside the transaction, so `for update` would be released before it
  -- finishes. A time-based claim is what actually stops two callers from both deciding
  -- to refresh.
  refresh_claimed_until timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint bkash_tokens_environment_known check (environment in ('sandbox', 'live'))
);

comment on table private.bkash_tokens is
  'Cached bKash id_token per environment. A row with an empty id_token is a placeholder '
  'written by the first caller to claim a refresh; it means "bootstrap with Grant Token".';

-- ---------------------------------------------------------------------------
-- Token RPCs (service_role only)
-- ---------------------------------------------------------------------------

-- What the caller needs to decide whether to refresh. Deliberately does not hand back
-- refresh_token: reading the cache and minting new tokens are different privileges, and
-- the caller that only executes payments needs neither the secret nor the ability to
-- extend its own access.
create or replace function api.bkash_token_state(p_environment text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row private.bkash_tokens;
begin
  if p_environment not in ('sandbox', 'live') then
    raise exception 'unknown bkash environment: %', p_environment using errcode = '22023';
  end if;

  select * into v_row from private.bkash_tokens where environment = p_environment;

  if not found or v_row.id_token = '' then
    -- No usable token yet. `bootstrap` distinguishes "fetch the first one" from
    -- "rotate an existing one", because refresh needs the refresh token we do not have.
    --
    -- `refreshing` is reported here too, and that is the whole reason this branch is
    -- not an early return that forgets it. Claiming the lease writes a placeholder row
    -- with an empty token, so a concurrent caller landing in this branch during the very
    -- first bootstrap would otherwise see nothing held and call Grant Token as well.
    -- Two concurrent first-time customers then spend two of the two calls allowed per
    -- hour, and the shop cannot take another payment until the window rolls over.
    return jsonb_build_object(
      'usable', false,
      'bootstrap', true,
      'refreshing', found and v_row.refresh_claimed_until > now()
    );
  end if;

  return jsonb_build_object(
    'usable', true,
    'bootstrap', false,
    'id_token', v_row.id_token,
    -- Five minutes of headroom, not zero. A token that expires while a create is in
    -- flight fails as an opaque 2001, and the customer sees a payment error rather
    -- than a retry.
    'needs_refresh', v_row.expires_at <= now() + interval '5 minutes',
    'refreshing', v_row.refresh_claimed_until > now()
  );
end
$$;

revoke all on function api.bkash_token_state(text) from public, anon, authenticated;
grant execute on function api.bkash_token_state(text) to service_role;

-- Returns true to exactly one caller per lease window. Losers get false and reuse the
-- cached token instead, which is what keeps a burst of checkouts to one API call.
create or replace function api.bkash_claim_refresh(p_environment text)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_claimed boolean;
begin
  if p_environment not in ('sandbox', 'live') then
    raise exception 'unknown bkash environment: %', p_environment using errcode = '22023';
  end if;

  -- The insert arm writes the placeholder for a first-ever call; the update arm takes
  -- the lease only if it is free. When the `where` fails no row comes back, so
  -- coalesce reports false rather than letting everyone refresh.
  --
  -- The `with` has to be the whole statement: a data-modifying CTE is not allowed to
  -- sit inside a sub-expression, so this selects into a variable rather than being
  -- wrapped in coalesce at the return.
  with claimed as (
    insert into private.bkash_tokens as t
      (environment, id_token, refresh_token, expires_at, refresh_claimed_until)
    values (p_environment, '', '', now(), now() + interval '60 seconds')
    on conflict (environment) do update
      set refresh_claimed_until = now() + interval '60 seconds'
      where t.refresh_claimed_until <= now()
    returning true
  )
  select coalesce(bool_or(true), false) into v_claimed from claimed;

  return v_claimed;
end
$$;

revoke all on function api.bkash_claim_refresh(text) from public, anon, authenticated;
grant execute on function api.bkash_claim_refresh(text) to service_role;

-- Stores a freshly minted token and releases the lease. Grant and Refresh return the
-- same shape, so one writer covers both.
create or replace function api.bkash_store_token(
  p_environment text,
  p_id_token text,
  p_refresh_token text,
  p_expires_in integer
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_environment not in ('sandbox', 'live') then
    raise exception 'unknown bkash environment: %', p_environment using errcode = '22023';
  end if;

  if btrim(coalesce(p_id_token, '')) = '' or btrim(coalesce(p_refresh_token, '')) = '' then
    raise exception 'bkash returned an empty token' using errcode = '22023';
  end if;

  -- A grant or refresh that omits expires_in still means one hour; assuming a much
  -- longer life would leave us calling a dead token until something failed visibly.
  update private.bkash_tokens
  set id_token = p_id_token,
      refresh_token = p_refresh_token,
      expires_at = now() + make_interval(secs => coalesce(p_expires_in, 3600)),
      refresh_claimed_until = now(),
      updated_at = now()
  where environment = p_environment;
end
$$;

revoke all on function api.bkash_store_token(text, text, text, integer)
  from public, anon, authenticated;
grant execute on function api.bkash_store_token(text, text, text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- Customer side: start a payment
-- ---------------------------------------------------------------------------

-- Answers "may this order pay via bKash, and with what". It returns the amount from the
-- stored order, never from the request, because this is the number that will be charged
-- and a client-supplied amount is a customer-chosen price.
create or replace function api.bkash_payment_start(p_order_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_order public.orders;
  v_gateway public.payment_gateways;
  v_currency text;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id and user_id = v_user;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  select * into v_gateway from public.payment_gateways where id = v_order.gateway_id;

  if v_gateway.provider is distinct from 'bkash_pgw' then
    raise exception 'this payment method does not accept online payment' using errcode = '22023';
  end if;

  -- A settled, expired or locked order must not start a new charge. An already
  -- completed session means the money is in and the access grant exists.
  if v_order.status in ('approved', 'locked', 'expired') then
    raise exception 'this order is no longer awaiting payment' using errcode = '22023';
  end if;

  if v_order.expires_at < now() then
    raise exception 'this order has expired' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.payment_sessions
    where order_id = v_order.id and status = 'completed'
  ) then
    raise exception 'this order has already been paid' using errcode = '22023';
  end if;

  select s.currency into v_currency from public.site_settings s where s.id = 1;

  if v_currency is distinct from 'BDT' then
    raise exception 'online payment is only available in BDT' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'ok', true,
    'order_id', v_order.id,
    'amount', v_order.amount,
    'currency', 'BDT',
    -- reference_code is already unique, already 8 URL-safe characters, and already
    -- satisfies bKash's `^[^<>&]*$` rule. It is the merchantInvoiceNumber, which is
    -- what lets a bKash statement be reconciled to an order without the IPN.
    'invoice', v_order.reference_code,
    'payer_reference', coalesce(v_order.phone_e164, v_order.reference_code)
  );
end
$$;

revoke all on function api.bkash_payment_start(uuid) from public, anon;
grant execute on function api.bkash_payment_start(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Worker side: record and settle
-- ---------------------------------------------------------------------------

-- Called after bKash creates the payment and before the customer is redirected. If the
-- redirect never happens the row is still here, which is the only way to find an
-- abandoned attempt later.
create or replace function api.bkash_record_session(
  p_order_id uuid,
  p_payment_id text,
  p_amount numeric
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_session public.payment_sessions;
begin
  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if btrim(coalesce(p_payment_id, '')) = '' then
    raise exception 'bkash returned no payment id' using errcode = '22023';
  end if;

  -- The amount is re-checked here, against the stored order, so a bug or a tampered
  -- response cannot open a charge for a different figure than the one agreed.
  if p_amount is distinct from v_order.amount then
    raise exception 'bkash amount does not match the order' using errcode = '22023';
  end if;

  insert into public.payment_sessions (
    order_id, provider, provider_payment_id, status, amount, currency
  )
  values (v_order.id, 'bkash_pgw', p_payment_id, 'initiated', v_order.amount, 'BDT')
  on conflict (provider, provider_payment_id) do update
    set order_id = excluded.order_id
  returning * into v_session;

  return v_session.id;
end
$$;

revoke all on function api.bkash_record_session(uuid, text, numeric)
  from public, anon, authenticated;
grant execute on function api.bkash_record_session(uuid, text, numeric) to service_role;

-- The money path. Called only after the server has confirmed with bKash that this
-- payment completed.
--
-- Settles by walking awaiting_proof -> under_review -> approved rather than jumping
-- straight to approved. private.guard_order_status() has no awaiting_proof -> approved
-- edge, and adding one would let any code path settle an order without review - the
-- transition table is shared with manual payments, where skipping review is exactly the
-- bug it exists to prevent. Two hops cost one extra audit row and keep the state machine
-- honest about what happened.
create or replace function api.bkash_settle_order(
  p_order_id uuid,
  p_payment_id text,
  p_trx_id text,
  p_payer_account text default null,
  p_amount numeric default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_session public.payment_sessions;
begin
  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if btrim(coalesce(p_trx_id, '')) = '' then
    raise exception 'a completed payment must carry a trx id' using errcode = '22023';
  end if;

  -- Read the session for update: two workers confirming the same payment must not both
  -- decide they are first. The partial unique indexes are the backstop, but they raise a
  -- duplicate-key error rather than returning a result, and a retryable answer beats an
  -- exception here.
  select * into v_session
  from public.payment_sessions
  where provider = 'bkash_pgw' and provider_payment_id = p_payment_id
  for update;

  if not found then
    raise exception 'no payment session for %', p_payment_id using errcode = 'P0002';
  end if;

  if v_session.order_id <> v_order.id then
    raise exception 'payment belongs to a different order' using errcode = '22023';
  end if;

  -- Confirmed amount must be the amount charged. A mismatch means the customer paid a
  -- different figure than the order is worth, and granting access would hand over the
  -- content for the wrong price.
  if p_amount is not null and p_amount is distinct from v_order.amount then
    raise exception 'confirmed amount does not match the order' using errcode = '22023';
  end if;

  -- Already settled by this payment. A customer who reloads the return page, or a
  -- callback that arrives twice, lands here and gets the same answer rather than an
  -- error.
  if v_session.status = 'completed' then
    return jsonb_build_object(
      'ok', true,
      'already', true,
      'status', v_order.status,
      'trx_id', v_session.provider_trx_id
    );
  end if;

  update public.payment_sessions
  set status = 'completed',
      provider_trx_id = p_trx_id,
      provider_account = nullif(p_payer_account, ''),
      executed_at = now()
  where id = v_session.id;

  if v_order.status = 'approved' then
    -- Settled by an earlier session; this payment is a second payment against an order
    -- that already granted access. Reported rather than raised, because the caller has
    -- done nothing wrong and the money really did arrive.
    return jsonb_build_object(
      'ok', true,
      'already', true,
      'status', v_order.status,
      'trx_id', p_trx_id,
      'note', 'order was already settled by another payment'
    );
  end if;

  if v_order.status = 'awaiting_proof' then
    update public.orders set status = 'under_review' where id = v_order.id;
  end if;

  -- reviewed_by stays null: nobody at this shop clicked approve, and claiming otherwise
  -- would put a null user in the audit trail dressed up as a decision. reviewed_at is
  -- what orders_reviewed_has_reviewer requires, and it is the truth - bKash confirmed
  -- this payment at this moment. The access_grant row comes from the existing trigger.
  update public.orders
  set status = 'approved',
      reviewed_at = now(),
      reviewed_by = null
  where id = v_order.id;

  return jsonb_build_object(
    'ok', true,
    'already', false,
    'status', 'approved',
    'trx_id', p_trx_id
  );
end
$$;

revoke all on function api.bkash_settle_order(uuid, text, text, text, numeric)
  from public, anon, authenticated;
grant execute on function api.bkash_settle_order(uuid, text, text, text, numeric)
  to service_role;

-- Records a payment bKash refused. Kept separate from settlement so a failed attempt is
-- visible to staff, and so a customer who mistyped their PIN can try again with a fresh
-- paymentId - bKash will not let the old one be executed twice.
create or replace function api.bkash_fail_session(
  p_order_id uuid,
  p_payment_id text,
  p_reason text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update public.payment_sessions
  set status = 'failed'
  where provider = 'bkash_pgw'
    and provider_payment_id = p_payment_id
    and order_id = p_order_id
    and status = 'initiated';
end
$$;

revoke all on function api.bkash_fail_session(uuid, text, text)
  from public, anon, authenticated;
grant execute on function api.bkash_fail_session(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

-- Customers read their order through api.my_order_status and nothing else, exactly as
-- with orders and order_evidence. The TrxID is settlement evidence and has no business
-- being readable by the person it is evidence about.
revoke all on public.payment_sessions from anon, authenticated;

-- RLS with no policies, for the same reason orders has none: access is decided in SQL
-- that can check ownership, not by a policy that has to guess.
alter table public.payment_sessions enable row level security;

-- ---------------------------------------------------------------------------
-- Registry: teach the admin form about `provider`
-- ---------------------------------------------------------------------------

create or replace function api.admin_upsert_gateway(p_gateway jsonb)
returns public.payment_gateways
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := nullif(p_gateway ->> 'id', '')::uuid;
  v_row public.payment_gateways;
  v_provider text := nullif(btrim(p_gateway ->> 'provider'), '');
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Restated from public.gateway_kind's definition, which lives in another migration.
  -- An unknown kind otherwise surfaces as an unhandled invalid-enum error rather than
  -- something an operator can act on.
  if v_provider is not null and v_provider <> 'bkash_pgw' then
    raise exception 'unknown payment provider: %', v_provider using errcode = '22023';
  end if;

  if v_id is null then
    insert into public.payment_gateways (
      kind, account_number, account_name, name_en, name_bn,
      instructions_md_en, instructions_md_bn,
      reference_prompt_en, reference_prompt_bn, supports_reference,
      evidence_fields, is_active, sort_order, provider
    )
    values (
      (p_gateway ->> 'kind')::public.gateway_kind,
      p_gateway ->> 'account_number',
      p_gateway ->> 'account_name',
      p_gateway ->> 'name_en',
      nullif(p_gateway ->> 'name_bn', ''),
      nullif(p_gateway ->> 'instructions_md_en', ''),
      nullif(p_gateway ->> 'instructions_md_bn', ''),
      nullif(p_gateway ->> 'reference_prompt_en', ''),
      nullif(p_gateway ->> 'reference_prompt_bn', ''),
      coalesce((p_gateway ->> 'supports_reference')::boolean, false),
      coalesce(p_gateway -> 'evidence_fields', '[]'::jsonb),
      coalesce((p_gateway ->> 'is_active')::boolean, true),
      coalesce((p_gateway ->> 'sort_order')::integer, 0),
      v_provider
    )
    returning * into v_row;
  else
    update public.payment_gateways
    set kind = (p_gateway ->> 'kind')::public.gateway_kind,
        account_number = p_gateway ->> 'account_number',
        account_name = p_gateway ->> 'account_name',
        name_en = p_gateway ->> 'name_en',
        name_bn = nullif(p_gateway ->> 'name_bn', ''),
        instructions_md_en = nullif(p_gateway ->> 'instructions_md_en', ''),
        instructions_md_bn = nullif(p_gateway ->> 'instructions_md_bn', ''),
        reference_prompt_en = nullif(p_gateway ->> 'reference_prompt_en', ''),
        reference_prompt_bn = nullif(p_gateway ->> 'reference_prompt_bn', ''),
        supports_reference = coalesce((p_gateway ->> 'supports_reference')::boolean, false),
        evidence_fields = coalesce(p_gateway -> 'evidence_fields', '[]'::jsonb),
        is_active = coalesce((p_gateway ->> 'is_active')::boolean, true),
        sort_order = coalesce((p_gateway ->> 'sort_order')::integer, 0),
        provider = v_provider
    where id = v_id
    returning * into v_row;
  end if;

  return v_row;
end
$$;

revoke all on function api.admin_upsert_gateway(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_gateway(jsonb) to authenticated;

-- The public payload carries `provider` so the customer view knows which methods can
-- take a payment without asking. Exposing which backend handles a method is not
-- sensitive - the customer is about to be redirected to it - and hiding it would mean
-- the frontend inferring an automated flow from `kind`, which is a guess.
--
-- The original body is moved aside rather than retyped. Pasting a copy with one field
-- added is precisely what the comment above api.create_order warns against: a
-- projection that drifts out of sync with the thing it describes. The projection
-- carries the hidden-minimum rule, which must never be retyped by hand. So the payload
-- is read from the existing function and only the gateway entries are augmented, by
-- joining them back to the table rather than by rebuilding the objects.
--
-- `get_public_link` calls `api.public_link_payload` by name, so it picks up the wrapper
-- and keeps adding `maintenance_mode` on top - unchanged.
alter function api.public_link_payload(text) rename to public_link_payload_v1;
revoke all on function api.public_link_payload_v1(text) from public, anon, authenticated;

create or replace function api.public_link_payload(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when base.doc is null then null
    else jsonb_set(
      base.doc,
      '{gateways}',
      (
        select coalesce(
          jsonb_agg(
            entry.doc || jsonb_build_object('provider', g.provider)
            order by entry.ordinality
          ),
          '[]'::jsonb
        )
        from jsonb_array_elements(coalesce(base.doc -> 'gateways', '[]'::jsonb))
          with ordinality as entry(doc, ordinality)
        join public.payment_gateways g on g.id = (entry.doc ->> 'id')::uuid
      )
    )
  end
  from (select api.public_link_payload_v1(p_slug) as doc) base
$$;

-- Deliberately NOT granted to anon or authenticated. `get_public_link` is security
-- definer and owned by postgres, so it can call this regardless of who is on the other
-- end - which is exactly how `get_public_link` reaches `public_link_payload_v1` today.
-- Granting it here would add a second anon-reachable entry point that returns the same
-- payload minus `maintenance_mode`, for no benefit, and `10_settings.sql` asserts the
-- surface stays at one.
revoke all on function api.public_link_payload(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Admin visibility
-- ---------------------------------------------------------------------------

-- Staff reviewing an automated payment need the TrxID: it is how they answer "did this
-- money arrive" when a customer disputes. Exposed to staff, not to the customer.
--
-- Separate from api.admin_order_detail rather than folded into it, so the settlement
-- evidence this integration records is visible without editing the projection that
-- every order screen already depends on.
create or replace function api.admin_order_payments(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Only staff; a customer asking about their own order gets the error, not an empty
  -- array, so this cannot be probed for whether a paymentId exists.
  return jsonb_build_object(
    'payments', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'provider', s.provider,
          'payment_id', s.provider_payment_id,
          'trx_id', s.provider_trx_id,
          'payer_account', s.provider_account,
          'status', s.status,
          'amount', s.amount,
          'currency', s.currency,
          'created_at', s.created_at,
          'executed_at', s.executed_at
        )
        order by s.created_at desc
      )
      from public.payment_sessions s
      where s.order_id = p_order_id
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function api.admin_order_payments(uuid) from public, anon, authenticated;
grant execute on function api.admin_order_payments(uuid) to authenticated;
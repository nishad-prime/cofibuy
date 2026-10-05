-- bKash settlement: the part that actually moves money.
--
-- Everything before this file described bKash and refused to call it. The schema knew how
-- a session, a token and a settlement row fit together; nothing ever made an HTTP request.
-- This adds the two Edge Functions that do, and the three database guarantees they rest
-- on. The guarantees are here rather than in TypeScript on purpose: they are the parts that
-- must hold even when the function is wrong, and they are the parts that can be tested
-- without a network.
--
--   1. A sandbox gateway never settles an order.
--   2. Credentials are stored trimmed, so a value pasted with a trailing space cannot
--      authenticate as itself and fail as an opaque 401 an hour later.
--   3. The token handshake is answerable: the refresh token is reachable by the caller
--      that holds the lease, and a failed refresh can release it.
--
-- ---------------------------------------------------------------------------
-- 1. Sandbox never settles
-- ---------------------------------------------------------------------------
--
-- bKash's sandbox accepts real card entries and reports `statusCode 0000` for a payment
-- that was never charged. Settling on that basis would grant access to paid-for content
-- for no money, and it would do so quietly: the order would be approved, the audit row
-- would say the customer's payment was confirmed, and the shop would have no revenue and no
-- way to tell. The only honest behaviour is to refuse, so:
--
--   * `bkash_payment_start` still runs. The customer reaches bKash, which is how the
--     integration gets exercised against a sandbox merchant, and how the credential
--     plumbing is proven end to end without real money.
--   * `bkash_settle_order` refuses. Outright, before any write.
--
-- The placement is the whole point. `payment_sessions.status` is moved to `completed` and
-- then `orders.status` to `approved`, and `private.grant_on_approval()` inserts the
-- `access_grants` row off the back of that. A guard after either write is not a guard: a
-- session marked completed cannot be executed again (bKash allows exactly one execute per
-- paymentId), so the order would be wedged - paid, unreleasable, and unfixable without
-- operator surgery. The check therefore runs before the session is locked, alongside the
-- other refusals, where raising costs the customer a retry and nothing else.
--
-- It reads the environment off the gateway that took the order rather than off a
-- deployment setting, because the two can disagree: a shop can run a bKash sandbox method
-- and a live one at the same time, and C4's weighted routing is exactly what makes several
-- accounts of one kind normal. Deciding from configuration would either expose the live shop
-- to the sandbox merchant or refuse the sandbox test.

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
  v_environment text;
begin
  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if btrim(coalesce(p_trx_id, '')) = '' then
    raise exception 'a completed payment must carry a trx id' using errcode = '22023';
  end if;

  -- Before the session is locked, before the session is marked completed, and before the
  -- order can reach `approved`. See the note at the top of this file.
  select g.environment into v_environment
  from public.payment_gateways g
  where g.id = v_order.gateway_id;

  if v_environment = 'sandbox' then
    raise exception
      'sandbox gateways cannot settle an order: bkash reported success for a payment it did not charge, so approving it would grant access for no money. Set the gateway to live to settle.'
      using errcode = '22023';
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

-- ---------------------------------------------------------------------------
-- Telling a test payment apart from a real one, before the click
-- ---------------------------------------------------------------------------
--
-- Restated rather than patched, because `create or replace` cannot change a function's
-- return shape without the whole body. One field is added, and it is the only change.
--
-- `environment` is not sensitive - it is on the gateway row an admin can already read - but
-- it is the difference between "Pay with bKash" and "This is a sandbox payment, nothing will
-- be charged". The shop owner running a sandbox method deserves to know that before a
-- customer does, and a customer who has just handed over a PIN deserves to be told plainly
-- that no money moved.
--
-- It also removes a guess. The order page previously decided an order could be paid online
-- from the method kind alone, which happens to be true today and would silently stop being
-- true the moment a second provider shares the kind.

create or replace function api.my_order_status(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_gateway public.payment_gateways;
begin
  select * into v_order from public.orders where id = p_order_id and user_id = auth.uid();
  if v_order.id is null then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if v_order.gateway_id is not null then
    select * into v_gateway from public.payment_gateways g where g.id = v_order.gateway_id;
  end if;

  return jsonb_build_object(
    'id', v_order.id,
    'status', v_order.status,
    'reference_code', v_order.reference_code,
    'amount', v_order.amount,
    'attempt_count', v_order.attempt_count,
    'reject_reason_en', v_order.reject_reason_en,
    'reject_reason_bn', v_order.reject_reason_bn,
    'expires_at', v_order.expires_at,
    'gateway', case
      when v_gateway.id is null then null
      else jsonb_build_object(
        'id', v_gateway.id,
        'kind', v_gateway.kind,
        'name_en', v_gateway.name_en,
        'name_bn', v_gateway.name_bn,
        'provider', v_gateway.provider,
        -- Not a secret, and not derivable from the kind: two gateways can share
        -- `bkash_instant` and differ only in environment. Without it the order page
        -- cannot say 'this is a test payment, nothing will be charged' before the
        -- customer spends a click finding out at the far end.
        'environment', v_gateway.environment,
        'account_fields', v_gateway.account_fields,
        'account_number', v_gateway.account_number,
        'account_name', v_gateway.account_name,
        'instructions_md_en', v_gateway.instructions_md_en,
        'instructions_md_bn', v_gateway.instructions_md_bn,
        'reference_prompt_en', v_gateway.reference_prompt_en,
        'reference_prompt_bn', v_gateway.reference_prompt_bn,
        'supports_reference', v_gateway.supports_reference,
        'evidence_fields', v_gateway.evidence_fields
      )
    end
  );
end;
$$;
revoke all on function api.my_order_status(uuid) from public;
grant execute on function api.my_order_status(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- What the create-payment function is allowed to know
-- ---------------------------------------------------------------------------
--
-- `gateway_id` and `environment` are added to the answer `bkash_payment_start` already
-- gave. Neither is a secret - both are readable from `payment_gateways_public` - but the
-- function needs them to pick the credential bundle and the base URL, and it must not go
-- and re-read the order to find them, because the second read is a second thing that can
-- disagree with the first.
--
-- `environment` especially: sending sandbox credentials to the live base URL charges a real
-- card, and sending live credentials to sandbox does nothing at all. The pair has to travel
-- together from the row that decided it.

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
    'gateway_id', v_gateway.id,
    'environment', v_gateway.environment,
    'sandbox', v_gateway.environment = 'sandbox',
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
-- Authorising the execute step
-- ---------------------------------------------------------------------------
--
-- The customer comes back from bKash holding a `paymentID` in the query string and an order
-- id we gave them. Before anything is executed with it, the function has to be able to
-- establish that this payment belongs to this customer's order - otherwise a caller could
-- pair any paymentId they had seen with any order and drive the money path.
--
-- That check is SQL, not TypeScript. It is a security boundary, it is the kind of check
-- that gets broken by a later refactor of the surrounding code, and it can be asserted here
-- without a network.
--
-- Returns what the caller needs and nothing more: the gateway to take credentials from, the
-- environment to talk to, and the amount, so the execute response can be compared against
-- the order before anything is settled.

create or replace function api.bkash_payment_claim(
  p_order_id uuid,
  p_payment_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_order public.orders;
  v_session public.payment_sessions;
  v_gateway public.payment_gateways;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id and user_id = v_user;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if btrim(coalesce(p_payment_id, '')) = '' then
    raise exception 'no payment id' using errcode = '22023';
  end if;

  -- Scoped to the order, so another customer's paymentId does not match, and to a session
  -- that was actually recorded, so a paymentId invented in a browser does not either. The
  -- provider is part of the lookup rather than a filter afterwards, because
  -- `provider_payment_id` is unique per provider and the column is shared.
  select * into v_session
  from public.payment_sessions
  where order_id = v_order.id
    and provider = 'bkash_pgw'
    and provider_payment_id = p_payment_id;

  if v_session.id is null then
    raise exception 'no payment session for %', p_payment_id using errcode = 'P0002';
  end if;

  -- Already settled. Not an error: the return page is reloaded on refresh, and the customer
  -- should land on the unlocked order rather than on a failure. The execute step reads
  -- this and returns without calling bKash, which matters because a paymentId may be
  -- executed exactly once and a second execute is worse than a wasted request.
  if v_session.status = 'completed' then
    return jsonb_build_object(
      'ok', true,
      'already_settled', true,
      'order_id', v_order.id,
      'status', v_order.status
    );
  end if;

  select * into v_gateway from public.payment_gateways where id = v_order.gateway_id;

  if v_gateway.provider is distinct from 'bkash_pgw' then
    raise exception 'this order was not paid online' using errcode = '22023';
  end if;

  if v_order.status in ('approved', 'locked', 'expired') then
    raise exception 'this order is no longer awaiting payment' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'ok', true,
    'already_settled', false,
    'order_id', v_order.id,
    'gateway_id', v_gateway.id,
    'environment', v_gateway.environment,
    'sandbox', v_gateway.environment = 'sandbox',
    'amount', v_order.amount,
    'currency', 'BDT',
    'session_status', v_session.status
  );
end
$$;

revoke all on function api.bkash_payment_claim(uuid, text) from public, anon;
grant execute on function api.bkash_payment_claim(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Finding the order again, from nothing but a payment id
-- ---------------------------------------------------------------------------
--
-- bKash sends the customer back to one configured redirect URL with `paymentID` on it, and
-- that URL is a setting in the bKash merchant dashboard - it is not per order and the
-- create request cannot influence it. So the page it lands on starts with a payment id and
-- nothing else, and has to work out which order it belongs to.
--
-- This is that lookup. It exists because the alternative is guessing on the client, and a
-- guess here is a payment applied to the wrong order.
--
-- Scoped by `auth.uid()` through the order, so a payment id belonging to somebody else is
-- indistinguishable from one that does not exist - the same answer either way, for the same
-- reason `bkash_payment_claim` gives the same answer.

create or replace function api.bkash_payment_lookup(p_payment_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_session public.payment_sessions;
  v_order public.orders;
  v_link public.paywall_links;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if btrim(coalesce(p_payment_id, '')) = '' then
    raise exception 'no payment id' using errcode = '22023';
  end if;

  select s.* into v_session
  from public.payment_sessions s
  join public.orders o on o.id = s.order_id
  where s.provider = 'bkash_pgw'
    and s.provider_payment_id = p_payment_id
    and o.user_id = v_user;

  if v_session.id is null then
    raise exception 'no payment session for %', p_payment_id using errcode = 'P0002';
  end if;

  select * into v_order from public.orders where id = v_session.order_id;
  select * into v_link from public.paywall_links where id = v_order.link_id;

  return jsonb_build_object(
    'ok', true,
    'order_id', v_order.id,
    -- The customer route is keyed by slug as well as order id, so the return page needs
    -- both to send anybody anywhere.
    'slug', v_link.slug,
    'status', v_order.status,
    -- Reported rather than assumed: the customer may have closed the tab and come back a
    -- day later, and re-running execute on a settled payment is the one mistake this
    -- flow cannot make twice.
    'already_settled', v_session.status = 'completed'
  );
end
$$;

revoke all on function api.bkash_payment_lookup(text) from public, anon;
grant execute on function api.bkash_payment_lookup(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Credentials are stored trimmed
-- ---------------------------------------------------------------------------
--
-- bKash authenticates with `app_key:app_secret` in a Basic header, so a secret pasted as
-- `"abc "` - which is what a copy out of a PDF or a chat window reliably produces - becomes
-- the literal `abc ` and fails as an HTTP 401 with a body that names neither field. The
-- bundle was already rejecting a wholly blank value, so this is the narrower case of the
-- same mistake: the value looks present, passes the blank check, and is wrong.
--
-- Trimming on the way in means the stored value is the canonical one, so the comparison
-- happens once at the edge of the system instead of on every request. `basic ` and
-- ` app_key` are the same credentials, and there is no reason for the database to be the
-- place that knows otherwise.
--
-- The blank check moves ahead of the trim for the same reason: a value of `'   '` must still
-- be refused, and it is easier to reason about "does trimming leave anything" than about
-- which of two orderings happens to catch it.

create or replace function private.store_credential_bundle(
  p_subject_id uuid,
  p_provider text,
  p_bundle jsonb
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_allowed text[] := coalesce(private.provider_field_keys(p_provider), array[]::text[]);
  v_row private.secret_bundles;
  v_existing jsonb := '{}'::jsonb;
  v_trimmed jsonb := '{}'::jsonb;
  v_source jsonb;
  v_merged jsonb := '{}'::jsonb;
  v_key text;
begin
  if v_allowed = array[]::text[] then
    raise exception 'unknown payment provider: %', p_provider using errcode = '22023';
  end if;

  -- A key the provider does not declare is either a typo or an attempt to store
  -- something the settlement code will never read. Both are refused rather than stored
  -- quietly, because a credential that looks saved but is never used is a worse state
  -- than one that is obviously missing.
  --
  -- `v_trimmed` is built as the keys are validated, so what is checked and what is stored
  -- cannot drift.
  --
  -- The blank check runs on the trimmed value. A secret of `'   '` must still be refused,
  -- and `btrim` is what makes that the same question as "is this value empty" rather than
  -- a second rule that has to be remembered alongside the first.
  --
  -- A non-string value is refused rather than coerced. `->>` would happily turn a number
  -- into text and store `'42'`, which then fails at bKash as an opaque 401 naming neither
  -- field. Refusing here names the field.
  for v_key in select jsonb_object_keys(p_bundle) loop
    if not (v_allowed @> array[v_key]) then
      raise exception 'credential % is not part of %', v_key, p_provider
        using errcode = '22023';
    end if;

    if jsonb_typeof(p_bundle -> v_key) <> 'string' then
      raise exception 'credential % must be a string', v_key using errcode = '22023';
    end if;

    if btrim(coalesce(p_bundle ->> v_key, '')) = '' then
      raise exception 'credential % cannot be blank', v_key using errcode = '22023';
    end if;

    v_trimmed := v_trimmed || jsonb_build_object(v_key, btrim(p_bundle ->> v_key));
  end loop;

  select * into v_row
  from private.secret_bundles
  where subject_kind = 'gateway' and subject_id = p_subject_id;

  if v_row.id is null then
    foreach v_key in array v_allowed loop
      if not (v_trimmed ? v_key) then
        raise exception 'credential % is required for %', v_key, p_provider
          using errcode = '22023';
      end if;
    end loop;

    v_source := v_trimmed;
  else
    select d.secret into v_existing
    from vault.decrypted_secrets d
    where d.id = v_row.vault_secret_id;

    -- A row whose vault secret is gone is treated as absent rather than trusted, so a
    -- re-save rebuilds it instead of failing inside vault.update_secret on a null id.
    if v_row.vault_secret_id is null or v_existing is null then
      foreach v_key in array v_allowed loop
        if not (v_trimmed ? v_key) then
          raise exception 'credential % is required for %', v_key, p_provider
            using errcode = '22023';
        end if;
      end loop;

      v_source := v_trimmed;
    else
      v_source := v_existing || v_trimmed;
    end if;
  end if;

  -- Every declared key is trimmed on the way out, not only the ones this call mentioned.
  -- Keys that came from `v_existing` may have been stored by a version of this function
  -- that did not trim, so a shop that saved before this migration would keep
  -- authenticating with a value that is wrong in exactly the way this migration exists to
  -- remove. Re-saving normalises them, which is repair without a migration that has to
  -- decrypt and rewrite every bundle.
  --
  -- Restricted to the provider's declared keys, so a stray key in an old secret is dropped
  -- rather than laundered through here.
  foreach v_key in array v_allowed loop
    if v_source ? v_key then
      v_merged := v_merged || jsonb_build_object(v_key, btrim(v_source ->> v_key));
    end if;
  end loop;

  if v_row.id is null then
    insert into private.secret_bundles (subject_kind, subject_id, vault_secret_id)
    values (
      'gateway',
      p_subject_id,
      vault.create_secret(
        v_merged,
        'gateway:' || p_subject_id::text,
        'Payment gateway credentials for gateway ' || p_subject_id::text
      )
    )
    returning * into v_row;
  else
    perform vault.update_secret(v_row.vault_secret_id, v_merged);

    -- Rotation is not only a vault update. The cached id_token was minted from the
    -- app_secret being replaced, so leaving it in place means the next request
    -- authenticates with a token from a retired credential and fails as an opaque
    -- provider error rather than as "you changed your key".
    --
    -- Compared against the *stored* secret rather than the incoming payload, so a save
    -- that changes nothing still purges nothing and a save that changes one key purges
    -- exactly once.
    if v_merged is distinct from v_existing then
      delete from private.bkash_tokens where credential_bundle_id = v_row.id;
    end if;
  end if;

  return v_row.id;
end
$$;

-- ---------------------------------------------------------------------------
-- The token handshake, made answerable
-- ---------------------------------------------------------------------------
--
-- `bkash_token_state` is restated for one reason: Refresh is unreachable without it.
--
-- A token is keyed on its credential bundle, because a token belongs to an app_key and two
-- gateways on different merchant accounts must never share one - that is why this function
-- takes a bundle id and not an environment. But a refresh needs the *previous refresh
-- token*, and the state function did not return it. So a caller that found a token needing
-- refresh had no legal move: grant a fresh token, which spends one of the two calls allowed
-- per hour and invalidates a token other in-flight requests are still holding; or wait for
-- a refresh that nobody was performing.
--
-- `bkash_token_state` is revoked from anon and authenticated and granted to service_role
-- only, so adding `refresh_token` to its answer opens no door. It is the same class of
-- secret as the `id_token` beside it, returned by the same caller, to the same audience.
--
-- Restated rather than patched: `create or replace` cannot change what a function returns
-- without the whole body. Only the added key differs from the version it supersedes.

create or replace function api.bkash_token_state(p_bundle_id uuid, p_environment text)
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

  select * into v_row
  from private.bkash_tokens
  where credential_bundle_id = p_bundle_id and environment = p_environment;

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
    'refresh_token', v_row.refresh_token,
    -- Five minutes of headroom, not zero. A token that expires while a create is in
    -- flight fails as an opaque 2001, and the customer sees a payment error rather
    -- than a retry.
    'needs_refresh', v_row.expires_at <= now() + interval '5 minutes',
    'refreshing', v_row.refresh_claimed_until > now()
  );
end
$$;

revoke all on function api.bkash_token_state(uuid, text) from public, anon, authenticated;
grant execute on function api.bkash_token_state(uuid, text) to service_role;

-- Releases the refresh lease without minting anything.
--
-- A caller that takes the lease and then fails - bKash 401, a network error, a malformed
-- response - has spent 60 seconds of every other checkout's window. It cannot store the
-- token it failed to get, and `bkash_store_token` refuses a blank one, which is correct: an
-- empty token must never be readable. So releasing is its own operation rather than a side
-- effect of a write.
--
-- Without this the failure is not a one-off either. The lease is 60 seconds, the token
-- lives an hour, and a merchant whose credentials are temporarily wrong therefore fails
-- every payment for a minute at a time, forever, instead of failing once and being fixed.

create or replace function api.bkash_release_refresh(p_bundle_id uuid, p_environment text)
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

  -- `expires_at` is left alone. Nothing reads it while `id_token` is empty -
  -- `bkash_token_state` reports `usable: false` first - so moving it would be a cosmetic
  -- lie that costs the next reader a reason to believe the row is healthy.
  update private.bkash_tokens
  set refresh_claimed_until = now(), updated_at = now()
  where credential_bundle_id = p_bundle_id and environment = p_environment;
end
$$;

revoke all on function api.bkash_release_refresh(uuid, text)
  from public, anon, authenticated;
grant execute on function api.bkash_release_refresh(uuid, text) to service_role;

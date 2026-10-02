-- Recovery: Telegram OTP against the payment phone number.
--
-- Flow, with an MTProto worker in a separate repository:
--
--   customer        api.request_recovery(phone)      -> a pending row
--   worker          api.claim_pending_recovery(n)     -> long-poll picks it up
--   worker          api.record_otp_sent(id, hash)     -> stores a bcrypt hash
--   customer        api.recover_access(phone, code)   -> grants, on success
--
-- Two decisions shape this file.
--
-- 1. There is no HTTP callback from the site to the worker. The site writes a
--    row and the worker's long-poll loop notices, so a static deployment needs
--    no worker URL, no shared secret, and no inbound route to secure.
--
-- 2. Recovery grants access to the *current* session rather than transferring
--    the original one. The customer wants the content, not the identity, and a
--    verified OTP on the phone number of an approved order is proof enough. That
--    removes the need for a server-side `auth.admin.generateLink` call, which
--    would otherwise be the largest privilege in the system — and it keeps this
--    app fully static with no Edge Function in the path.
--
-- The worker reaches these tables only through the narrow functions below. It
-- holds a service_role key, so revoking that key disables recovery and nothing
-- else.

-- ---------------------------------------------------------------------------
-- Customer side
-- ---------------------------------------------------------------------------

create or replace function api.request_recovery(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_phone text;
  v_request public.recovery_requests;
  v_enabled boolean;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select recovery_enabled into v_enabled from public.site_settings where id = 1;
  if not coalesce(v_enabled, false) then
    raise exception 'account recovery is not available' using errcode = '22023';
  end if;

  v_phone := private.normalize_bd_phone(p_phone);
  if v_phone is null then
    raise exception 'that is not a valid Bangladeshi mobile number' using errcode = '22023';
  end if;

  if (
    select count(*) >= 5
    from public.recovery_requests
    where phone_e164 = v_phone and created_at > now() - interval '1 hour'
  ) then
    raise exception 'too many recovery requests, please try again later' using errcode = '22023';
  end if;

  insert into public.recovery_requests (phone_e164, requester_user_id, expires_at)
  values (v_phone, v_user, now() + interval '15 minutes')
  returning * into v_request;

  -- The response is identical whether or not this phone has ever paid. Saying
  -- "no purchases found" would turn the form into a way to enumerate customers.
  return jsonb_build_object(
    'ok', true,
    'request_id', v_request.id,
    'expires_in_seconds', 900
  );
end
$$;

create or replace function api.recover_access(p_phone text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_phone text;
  v_challenge public.otp_challenges;
  v_challenge_id uuid;
  v_enabled boolean;
  v_granted jsonb;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select recovery_enabled into v_enabled from public.site_settings where id = 1;
  if not coalesce(v_enabled, false) then
    raise exception 'account recovery is not available' using errcode = '22023';
  end if;

  v_phone := private.normalize_bd_phone(p_phone);
  if v_phone is null then
    raise exception 'that is not a valid Bangladeshi mobile number' using errcode = '22023';
  end if;

  -- A wrong code returns rather than raises, and that is load-bearing.
  --
  -- Raising unwinds the function and rolls back everything it did on the way
  -- out, including the attempt it just counted. A counter that only survives
  -- when it is not updated is not a counter: the five-guess limit below would
  -- never be reached, and a code that leaked would be good for unlimited
  -- guesses against it.
  --
  -- The two failures are also the same object, so a caller cannot use the
  -- response to learn whether a code existed, was already used, or had expired.
  --
  -- This first read deliberately takes no lock. It only decides which request
  -- owns the live challenge, so the locks below can be taken in one fixed order.
  select * into v_challenge
  from public.otp_challenges
  where phone_e164 = v_phone and consumed_at is null and expires_at > now()
  order by created_at desc
  limit 1;

  if v_challenge is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_code');
  end if;

  v_challenge_id := v_challenge.id;

  -- Locks are taken request-then-challenge, the same order api.record_otp_sent
  -- uses. Both functions write to both tables, so taking the same two locks in
  -- opposite orders is a deadlock waiting for a worker to send a code at the
  -- moment a customer guesses one.
  perform 1
  from public.recovery_requests
  where id = v_challenge.recovery_request_id
  for update;

  -- Locking the challenge is what makes the five-guess limit a limit. Without
  -- it, parallel requests all read the same attempt_count, all count themselves
  -- as the first guess, and none of them trips the threshold below — so a
  -- leaked code could be tried as many times as an attacker could send in
  -- parallel. Holding the row for the rest of the transaction also makes
  -- `attempt_count + 1` below an accurate count rather than a stale one.
  --
  -- The row is re-checked after the lock because the peek above was unlocked: a
  -- concurrent resend may have consumed or replaced the challenge in between.
  -- Superseded is reported as an ordinary invalid code, like every other miss.
  select * into v_challenge
  from public.otp_challenges
  where id = v_challenge_id
    and consumed_at is null
    and expires_at > now()
  for update;

  if v_challenge is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_code');
  end if;

  if not private.otp_matches(p_code, v_challenge.otp_hash) then
    update public.otp_challenges
    set attempt_count = attempt_count + 1
    where id = v_challenge.id;

    if v_challenge.attempt_count + 1 >= v_challenge.max_attempts then
      update public.otp_challenges set consumed_at = now() where id = v_challenge.id;
      update public.recovery_requests
      set status = 'failed'
      where id = v_challenge.recovery_request_id and status = 'sent';
    end if;

    return jsonb_build_object('ok', false, 'code', 'invalid_code');
  end if;

  update public.otp_challenges set consumed_at = now() where id = v_challenge.id;
  update public.recovery_requests
  set status = 'verified', verified_at = now()
  where id = v_challenge.recovery_request_id;

  -- Everything ever paid for with this phone, granted to whoever just proved
  -- control of it. Idempotent, so re-verifying a second code is harmless.
  --
  -- Postgres has no min() for uuid, so the order credited is the earliest one
  -- for the link, picked out of an ordered array.
  insert into public.access_grants (user_id, link_id, via_order_id)
  select
    v_user,
    o.link_id,
    (array_agg(o.id order by o.created_at))[1]
  from public.orders o
  where o.phone_e164 = v_phone and o.status = 'approved'
  group by o.link_id
  on conflict (user_id, link_id) do nothing;

  insert into public.customer_contacts (user_id, phone_e164)
  values (v_user, v_phone)
  on conflict (user_id, phone_e164) do nothing;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('slug', l.slug, 'title_en', l.title_en, 'title_bn', l.title_bn)
      order by l.slug
    ),
    '[]'::jsonb
  )
  into v_granted
  from public.access_grants g
  join public.paywall_links l on l.id = g.link_id
  where g.user_id = v_user and g.revoked_at is null;

  return jsonb_build_object('ok', true, 'links', v_granted);
end
$$;

-- ---------------------------------------------------------------------------
-- Worker side
--
-- Grantable to service_role only. Each returns the same error the customer
-- would see, so the worker cannot distinguish "claimed by someone else" from
-- "already handled".
-- ---------------------------------------------------------------------------

-- At-least-once claim. `for update skip locked` lets several workers poll the
-- same table concurrently without coordinating and without ever handing the same
-- request to two of them.
--
-- The claim itself marks the request `sent`, because a row that stays `pending`
-- while it is in flight would be re-claimed on the next poll. If a worker dies
-- between claiming and storing the code, api.reap_stale_claims() returns the row
-- to `pending` — at-least-once delivery, and the duplicate-suppression risk is
-- one wasted Telegram message rather than a customer with no way in.
create or replace function api.claim_pending_recovery(p_limit integer default 10)
returns table (
  id uuid,
  phone_e164 text,
  purpose text,
  created_at timestamptz,
  expires_at timestamptz,
  previous_attempts integer
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return query
  with claimed as (
    select r.id
    from public.recovery_requests r
    where r.status = 'pending'
      and r.created_at <= now()
      and r.expires_at > now()
    order by r.created_at
    for update skip locked
    limit least(greatest(coalesce(p_limit, 10), 1), 100)
  )
  update public.recovery_requests r
  set status = 'sent',
      sent_at = now(),
      attempt_count = r.attempt_count + 1
  from claimed c
  where r.id = c.id
  returning
    r.id,
    r.phone_e164,
    r.purpose,
    r.created_at,
    r.expires_at,
    r.attempt_count - 1;
end
$$;

-- Stores a bcrypt hash. The raw code is never written to the database, only
-- transmitted to Telegram: a dump of this table yields nothing an attacker can
-- use against a live code.
create or replace function api.record_otp_sent(
  p_request_id uuid,
  p_otp_hash text,
  p_ttl_seconds integer default 300
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_request public.recovery_requests;
begin
  select * into v_request from public.recovery_requests where id = p_request_id for update;

  if not found or v_request.status <> 'sent' then
    raise exception 'request is not awaiting a code' using errcode = '22023';
  end if;

  if v_request.expires_at < now() then
    raise exception 'request has expired' using errcode = '22023';
  end if;

  -- Supersede any earlier unconsumed code for this *phone*, so a resend
  -- invalidates the previous one rather than leaving two live at once. Matching
  -- on the request id would not do it: a resend is a new request, and the old
  -- challenge belongs to the old one, so both codes would stay usable.
  update public.otp_challenges
  set consumed_at = now()
  where phone_e164 = v_request.phone_e164 and consumed_at is null;

  insert into public.otp_challenges (
    recovery_request_id, phone_e164, otp_hash, max_attempts, expires_at
  )
  values (
    p_request_id,
    v_request.phone_e164,
    p_otp_hash,
    5,
    least(
      now() + make_interval(secs => least(greatest(coalesce(p_ttl_seconds, 300), 60), 900)),
      v_request.expires_at
    )
  );

  return jsonb_build_object('ok', true, 'expires_at', now());
end
$$;

-- MTProto cannot tell us whether a Telegram account exists for a number. When
-- there is no reachable chat, the worker records that so the customer is told
-- the truth instead of waiting for a code that will never arrive.
create or replace function api.mark_undeliverable(p_request_id uuid, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update public.recovery_requests
  set status = 'undeliverable'
  where id = p_request_id and status = 'sent';

  if not found then
    raise exception 'request is not awaiting delivery' using errcode = '22023';
  end if;

  insert into public.audit_log (actor_id, action, target_table, target_id, meta)
  values (
    null,
    'recovery.undeliverable',
    'recovery_requests',
    p_request_id::text,
    jsonb_build_object('reason', left(coalesce(p_reason, ''), 200))
  );

  return jsonb_build_object('ok', true);
end
$$;

-- Returns claims that never produced a code to `pending`, so a worker crash
-- mid-claim cannot strand a customer. Intended for pg_cron; see the cron
-- migration.
create or replace function private.reap_stale_claims()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.recovery_requests r
  set status = 'pending'
  where r.status = 'sent'
    and r.sent_at < now() - interval '3 minutes'
    and not exists (
      select 1
      from public.otp_challenges c
      where c.recovery_request_id = r.id and c.consumed_at is null
    )
    and r.attempt_count < 3;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- ---------------------------------------------------------------------------

revoke all on function api.request_recovery(text) from public;
revoke all on function api.recover_access(text, text) from public;
revoke all on function api.claim_pending_recovery(integer) from public;
revoke all on function api.record_otp_sent(uuid, text, integer) from public;
revoke all on function api.mark_undeliverable(uuid, text) from public;

grant usage on schema api to service_role;

grant execute on function api.request_recovery(text) to authenticated;
grant execute on function api.recover_access(text, text) to authenticated;

-- The worker surface. Narrow by design: with a service_role key in hand, these
-- three functions are all the recovery data it can reach.
grant execute on function api.claim_pending_recovery(integer) to service_role;
grant execute on function api.record_otp_sent(uuid, text, integer) to service_role;
grant execute on function api.mark_undeliverable(uuid, text) to service_role;

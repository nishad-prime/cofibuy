-- Repeat purchases and the rejected-order lifecycle.
--
-- 1. A customer who already has access cannot order the same page again:
--    create_order refuses with a stable `already_owned` code before anything
--    else runs. Double orders by mistake become impossible at the source.
--
-- 2. A rejected order stays rejected. The housekeeping sweep no longer
--    expires it, and the open-order lookup no longer reuses it: a rejected
--    customer starts a fresh order instead of being pinned to a dead row.
--    The partial unique index never covered `rejected`, so a fresh order
--    alongside it is safe, and the 30-minute resubmission window on the old
--    order still works for a customer who fixes their proof in time.

-- ---------------------------------------------------------------------------
-- create_order: refuse what the customer already owns
-- ---------------------------------------------------------------------------

create or replace function api.create_order(p_slug text, p_kind text, p_amount numeric, p_context jsonb default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if (select s.maintenance_mode from public.site_settings s where s.id = 1) then
    raise exception 'shop temporarily closed' using errcode = 'P0001';
  end if;

  return api.create_order_resolved(p_slug, p_kind, p_amount, p_context);
end
$function$;

revoke all on function api.create_order(text, text, numeric, jsonb) from public, anon, authenticated;
grant execute on function api.create_order(text, text, numeric, jsonb) to authenticated;

create or replace function api.create_order_resolved(p_slug text, p_kind text, p_amount numeric, p_context jsonb default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_user uuid := auth.uid();
  v_link public.pages;
  v_gateway public.payment_gateways;
  v_open_kind text;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select l.id into v_link
  from public.pages l
  where l.slug = p_slug and l.is_active;

  if v_link.id is null then
    raise exception 'link not found' using errcode = 'P0002';
  end if;

  -- Before anything else, and stable-coded: a customer who already owns the
  -- page must not be able to pay for it twice, no matter how the UI is
  -- reached. The access grant is the truth of ownership; the approved order
  -- is checked alongside it so the answer does not depend on grant timing.
  if exists (
    select 1 from public.access_grants a
    where a.user_id = v_user and a.link_id = v_link.id and a.revoked_at is null
  ) or exists (
    select 1 from public.orders o
    where o.user_id = v_user and o.link_id = v_link.id and o.status = 'approved'
  ) then
    return jsonb_build_object('ok', false, 'code', 'already_owned');
  end if;

  if nullif(btrim(p_kind), '') is null then
    raise exception 'a payment method kind is required' using errcode = '22023';
  end if;

  select * into v_gateway from private.pick_gateway_for_kind(p_kind);

  if v_gateway.id is null then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  -- `rejected` is no longer in this set: a rejected customer starts fresh.
  -- The rejected row stays theirs for the resubmission window and as history.
  select g.kind into v_open_kind
  from public.orders o
  join public.payment_gateways g on g.id = o.gateway_id
  where o.user_id = v_user
    and o.link_id = v_link.id
    and o.status in ('draft', 'awaiting_proof', 'locked')
  limit 1;

  if v_open_kind is not null and v_open_kind <> v_gateway.kind then
    raise exception 'kind_mismatch: open order already uses payment kind %', v_open_kind
      using errcode = '22023';
  end if;

  return api.create_order_unchecked(p_slug, v_gateway.id, p_amount, p_context);
end
$function$;

revoke all on function api.create_order_resolved(text, text, numeric, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- create_order_unchecked: the reuse path follows the same rule
-- ---------------------------------------------------------------------------

create or replace function api.create_order_unchecked(p_slug text, p_gateway_id uuid, p_amount numeric, p_context jsonb default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_user uuid := auth.uid();
  v_link public.pages;
  v_settings public.site_settings;
  v_gateway public.payment_gateways;
  v_min numeric;
  v_hide boolean;
  v_open public.orders;
  v_country text;
  v_city text;
  v_device text;
  v_os text;
  v_browser text;
  v_referrer text;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- The visit context: the client's word, clamped to the shapes the analytics
  -- read. A wrong value degrades to null, never to an error.
  v_country := nullif(btrim(coalesce(p_context ->> 'country', '')), '');
  if v_country !~ '^[A-Z]{2}$' then
    v_country := null;
  end if;
  v_city := left(nullif(btrim(coalesce(p_context ->> 'city', '')), ''), 80);
  v_device := nullif(btrim(coalesce(p_context ->> 'device_type', '')), '');
  if v_device not in ('mobile', 'desktop', 'tablet') then
    v_device := null;
  end if;
  v_os := left(nullif(btrim(coalesce(p_context ->> 'os', '')), ''), 40);
  v_browser := left(nullif(btrim(coalesce(p_context ->> 'browser', '')), ''), 40);
  v_referrer := left(nullif(btrim(coalesce(p_context ->> 'referrer', '')), ''), 200);

  select * into v_link from public.pages where slug = p_slug and is_active;
  if not found then
    raise exception 'link not found' using errcode = 'P0002';
  end if;

  select * into v_gateway from public.payment_gateways where id = p_gateway_id and is_active;
  if not found then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  select * into v_settings from public.site_settings where id = 1;
  v_min := private.effective_min(v_link, v_settings);
  v_hide := private.effective_hide_min(v_link, v_settings);

  -- Reuse the customer's open order rather than creating a second one. This is
  -- a courtesy, not the safety net: the partial unique index is what actually
  -- prevents duplicates.
  --
  -- `locked` is included so a probe lock is found here. Excluding it would let
  -- the customer walk straight past the lock by asking again, because the
  -- follow-on code would fall through and insert a fresh draft.
  --
  -- `rejected` is excluded: a rejected customer starts fresh. The partial
  -- unique index does not cover `rejected`, so the fresh order is safe.
  select * into v_open
  from public.orders
  where user_id = v_user
    and link_id = v_link.id
    and status in ('draft', 'awaiting_proof', 'locked')
  for update;

  -- `v_open.id`, never `v_open is not null`. A row variable is null only when
  -- *every* column is null, so testing the whole row against null quietly skips
  -- the reuse path for any order that has a sparse column (which every draft
  -- does) and falls through to the insert below, tripping the open-order index.
  if v_open.id is not null then
    -- Locked means no amount is accepted and no new order starts, so the probe
    -- budget cannot be reset by asking again. A distinct code lets the client
    -- say so instead of showing the same "too low" message forever.
    if v_open.status = 'locked' then
      return jsonb_build_object(
        'ok', false,
        'code', 'locked',
        'locked_at', v_open.locked_at
      );
    end if;

    -- Reaching an existing draft means another attempt came in. Count it whether
    -- or not the amount is acceptable, so the lock cannot be side-stepped by
    -- alternating valid and invalid amounts.
    if p_amount is null or p_amount < v_min then
      update public.orders
      set probe_count = probe_count + 1,
          locked_at = case when probe_count + 1 >= 6 then now() else locked_at end,
          status = case when probe_count + 1 >= 6 then 'locked'::public.order_status else status end
      where id = v_open.id;

      return jsonb_build_object('ok', false, 'code', 'below_minimum');
    end if;

    return jsonb_build_object(
      'ok', true,
      'order_id', v_open.id,
      'reference_code', v_open.reference_code,
      'status', v_open.status,
      'expires_at', v_open.expires_at,
      'min_amount', case when v_hide then null else v_min end,
      'min_hidden', v_hide
    );
  end if;

  if p_amount is null or p_amount < v_min then
    -- A row is created even for a rejected amount because the probe counter has
    -- to live somewhere. It is a draft: it is never listed, never reviewed, and
    -- expires on its own.
    insert into public.orders (
      user_id, link_id, gateway_id, status, reference_code, amount,
      min_amount_snapshot, hide_min_snapshot, probe_count, expires_at,
      country, city, device_type, os, browser, referrer
    )
    values (
      v_user, v_link.id, v_gateway.id, 'draft', private.gen_reference_code(),
      greatest(coalesce(p_amount, 0), 0.01),
      v_min, v_hide, 1, now() + interval '30 minutes',
      v_country, v_city, v_device, v_os, v_browser, v_referrer
    )
    returning * into v_open;

    return jsonb_build_object('ok', false, 'code', 'below_minimum');
  end if;

  insert into public.orders (
    user_id, link_id, gateway_id, status, reference_code, amount,
    min_amount_snapshot, hide_min_snapshot, expires_at,
    country, city, device_type, os, browser, referrer
  )
  values (
    v_user, v_link.id, v_gateway.id, 'awaiting_proof',
    private.gen_reference_code(), p_amount,
    v_min, v_hide, now() + interval '30 minutes',
    v_country, v_city, v_device, v_os, v_browser, v_referrer
  )
  returning * into v_open;

  return jsonb_build_object(
    'ok', true,
    'order_id', v_open.id,
    'reference_code', v_open.reference_code,
    'status', v_open.status,
    'expires_at', v_open.expires_at,
    'min_amount', case when v_hide then null else v_min end,
    'min_hidden', v_hide
  );
end
$function$;

revoke all on function api.create_order_unchecked(text, uuid, numeric, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The sweep: rejected orders stay rejected
-- ---------------------------------------------------------------------------

create or replace function private.expire_stale_orders()
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_count integer;
begin
  -- An abandoned order must not sit in the queue forever. A customer whose
  -- order expired simply starts again; the terms are snapshotted on the new one.
  --
  -- `locked` expires too, deliberately. A lock that only an admin can clear is a
  -- permanent dead end for a customer who mistyped an amount, and this one is a
  -- rate limit rather than a security boundary — the hidden minimum is protected
  -- by never being disclosed, not by the lock.
  --
  -- `rejected` is NOT here: a rejection is a decision, not an abandonment, and
  -- the operator's word should not quietly turn into "expired" overnight. The
  -- customer starts fresh because the open-order lookup no longer reuses
  -- rejected rows.
  update public.orders
  set status = 'expired'
  where status in ('awaiting_proof', 'draft', 'locked')
    and expires_at < now();

  get diagnostics v_count = row_count;

  -- Expire recovery requests and their codes. This function owns the whole
  -- sweep's expiry work; dropping this block when rewriting it above is what
  -- quietly stopped recovery requests from ever expiring.
  update public.recovery_requests
  set status = 'expired'
  where status in ('pending', 'sent') and expires_at < now();

  update public.otp_challenges
  set consumed_at = now()
  where consumed_at is null and expires_at < now();

  return v_count;
end
$function$;

revoke all on function private.expire_stale_orders() from public, anon, authenticated;

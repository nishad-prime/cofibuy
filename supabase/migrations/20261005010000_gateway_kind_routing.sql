-- Routing a customer's chosen kind to a gateway, and taking the paywall's account
-- details out of it.
--
-- Two problems, one migration, because they are the same problem seen from two sides.
--
-- Before this, `api.create_order` took a `gateway_id`. The customer picked from a list and
-- the client sent back whatever id it had been given, so the server trusted the client's
-- choice of which account to pay into. There was also no way to say "these two bKash
-- accounts are both fine, split between them" other than leaving the customer to pick.
--
-- Now the customer sends the *kind* they chose - "bKash" - and the server decides which
-- account of that kind, weighted. The list a customer sees stops being the thing that
-- decides where money goes.
--
-- Which brings the leak. Because routing is by kind, a kind has to be unambiguous about how
-- the money arrives: a kind that has both a manual and an automatic gateway cannot be
-- resolved without guessing, and a customer who picked "bKash" expecting to be handed to
-- bKash would instead be shown a wallet number. Hence the uniformity guard.
--
-- The second half is what the storefront is allowed to know. `public_link_payload` published
-- every active gateway's account number, account name, instructions, reference prompt and
-- evidence fields to every anonymous visitor of every paywall link - whether or not they
-- intended to buy with that method, and for an automatic gateway, where there is nothing to
-- send at all. Those details belong to an order, so the paywall now carries only enough to
-- choose from, and `my_order_status` carries the rest.

-- ---------------------------------------------------------------------------
-- Weight
-- ---------------------------------------------------------------------------
--
-- How much of the traffic for a kind this account takes. `is_active` stays the only
-- on/off switch: a zero weight would look like a disabled gateway everywhere except in the
-- one place it matters, and an operator reading `is_active = true` should be able to believe
-- that the account is live.

alter table public.payment_gateways
  add column weight integer not null default 1;

alter table public.payment_gateways
  add constraint payment_gateways_weight_at_least_one check (weight >= 1);

comment on column public.payment_gateways.weight is
  'Relative share of orders for this gateway''s kind. Default 1: two accounts at 1 each '
  'split traffic evenly. Only meaningful when a kind has more than one account.';

-- ---------------------------------------------------------------------------
-- One kind, one way of paying
-- ---------------------------------------------------------------------------
--
-- The guard the weighted pick depends on. Without it, `create_order` receives a kind that
-- matches two gateways that behave nothing alike, and "pick one by weight" silently means
-- "sometimes hand the customer a bank transfer form, sometimes redirect them to a processor".
--
-- Scoped to active rows so that turning a gateway off is a legitimate way to resolve the
-- ambiguity without deleting an account that is still needed. The consequence is that
-- `is_active` is part of the trigger's column list: activating the second manual bKash
-- gateway while an automatic one is active is the exact write this has to catch.
--
-- SQLSTATE 23514, the same as the other table-level invariants here, so an operator sees a
-- constraint failure rather than something that looks like a server fault.

create or replace function private.guard_gateway_kind_uniformity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_other_is_manual boolean;
begin
  -- `g.id <> new.id` is load-bearing. On UPDATE the table still holds this row's *old*
  -- shape, so without it an automatic method being switched to manual finds itself: the
  -- stored row is automatic, the new one is manual, and the two "disagree" about a kind
  -- that has one member. Only a genuine second method should be refused.
  select (g.provider is null) into v_other_is_manual
  from public.payment_gateways g
  where g.kind = new.kind
    and g.id <> new.id
    and g.is_active
    and new.is_active
    and (g.provider is null) <> (new.provider is null)
  limit 1;

  -- The mode named in the message is the one that already exists, because that is the part
  -- the operator did not just type and will otherwise go looking for.
  if v_other_is_manual is not null then
    raise exception
      'kind "%" already has an active % payment method; one kind cannot be both manual and automatic',
      new.kind,
      case when v_other_is_manual then 'manual' else 'automatic' end
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger trg_gateway_kind_uniformity
  before insert or update of kind, provider, is_active on public.payment_gateways
  for each row execute function private.guard_gateway_kind_uniformity();

-- ---------------------------------------------------------------------------
-- Resolving a kind to an account
-- ---------------------------------------------------------------------------
--
-- Weighted random, as an exponential race. For each candidate the key is
-- `-ln(random()) / weight`, ascending. `random()` is uniform on [0,1), so `-ln(random())`
-- is exponential with rate 1, and dividing by the weight makes that candidate's key
-- exponential with rate `weight`. The minimum of independent exponentials belongs to the
-- candidate with probability proportional to its rate, so a gateway weighted 9 is picked
-- nine times as often as one weighted 1 - which is the whole promise of the column.
--
-- Sorting on `random() * weight` instead would be exactly backwards: the product is
-- uniform on [0,weight), so the *lightest* gateway would win most often. It reads like a
-- weighted draw and is the wrong way round, which is why the comment is this long.
--
-- `greatest(random(), 1e-9)` because `ln(0)` raises, and `random()` is documented to be
-- able to return 0.0. The floor puts a drawing that lands there at the back of the queue
-- instead of failing the customer's checkout.
--
-- `g.id` breaks ties so two accounts with equal weight cannot produce a different answer
-- for the same input shape, which keeps a test that draws many times from being flaky for
-- reasons that have nothing to do with the weighting. Real ties have probability zero;
-- the tiebreak is for the order the plan returns, not for the outcome.

create or replace function api.create_order_resolved(
  p_slug text,
  p_kind text,
  p_amount numeric
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_link public.paywall_links;
  v_gateway public.payment_gateways;
  v_open_kind text;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- Read, never written, from here down. `create_order_unchecked` re-reads the link and
  -- locks the open order itself; this pass exists only to compare kinds, and doing that
  -- read without touching probe_count is the whole point of raising before delegating.
  select l.id into v_link
  from public.paywall_links l
  where l.slug = p_slug and l.is_active;

  if v_link.id is null then
    raise exception 'link not found' using errcode = 'P0002';
  end if;

  -- After the link, not before it. A customer who sent a slug that is not for sale is told
  -- the link is gone whether or not they had chosen a method; moving this above that check
  -- would answer a different question than the one they asked.
  if nullif(btrim(p_kind), '') is null then
    raise exception 'a payment method kind is required' using errcode = '22023';
  end if;

  select * into v_gateway from private.pick_gateway_for_kind(p_kind);

  if v_gateway.id is null then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  -- The customer's open order is pinned to one gateway, and the pin has to survive them
  -- changing their mind about the kind - otherwise an order awaiting proof on a bank
  -- transfer could be confirmed against a different account than the one the screenshot
  -- shows. Refused rather than re-pointed: re-pointing would leave the customer holding a
  -- transfer receipt for an account nobody is watching.
  --
  -- Raised rather than returned as a code because the client has to change state, not show
  -- a message: it cannot make the mismatch go away by retrying, and an `ok: false` envelope
  -- carrying no order id is easy for a client to read as "try again" and loop on.
  select g.kind into v_open_kind
  from public.orders o
  join public.payment_gateways g on g.id = o.gateway_id
  where o.user_id = v_user
    and o.link_id = v_link.id
    and o.status in ('draft', 'awaiting_proof', 'rejected', 'locked')
  limit 1;

  if v_open_kind is not null and v_open_kind <> v_gateway.kind then
    -- `kind_mismatch` is the stable part. The sentence after it can be reworded or
    -- translated without breaking a client that needs to know this is not retryable.
    raise exception 'kind_mismatch: open order already uses payment kind %', v_open_kind
      using errcode = '22023';
  end if;

  return api.create_order_unchecked(p_slug, v_gateway.id, p_amount);
end;
$$;

-- The draw itself, split out so it can be tested without an order. `create_order` has a
-- one-open-order rule and a per-customer identity, so a test that wanted to watch the
-- distribution would have to mint thousands of customers to get a clean sample; asking this
-- function a few thousand times is the same evidence for none of that setup.
--
-- `volatile` because it is a random draw, and saying so stops a planner from hoisting one
-- call out of a loop and handing every iteration the same gateway.

create or replace function private.pick_gateway_for_kind(p_kind text)
returns public.payment_gateways
language sql
volatile
security definer
set search_path = ''
as $$
  select g.*
  from public.payment_gateways g
  where g.is_active and g.kind = btrim(p_kind)
  order by -ln(greatest(random(), 1.0e-9)) / g.weight, g.id
  limit 1
$$;

revoke all on function private.pick_gateway_for_kind(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The entry point, on a kind
-- ---------------------------------------------------------------------------
--
-- `drop ... if exists` first, and it has to be explicit. The old
-- `api.create_order(text, uuid, numeric)` and this `api.create_order(text, text, numeric)`
-- are different signatures, and `create or replace` only ever matches on the full argument
-- list - so without the drop both would exist, PostgREST would pick between them by an
-- argument-name heuristic it applies to untyped payloads, and the winner would be a coin
-- toss. That is the same trap `bkash_token_state` walked into in the previous commit.
drop function if exists api.create_order(text, uuid, numeric);

create or replace function api.create_order(
  p_slug text,
  p_kind text,
  p_amount numeric
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- Before anything else, so the answer does not depend on whether the slug exists or
  -- which kind was named. An operator flipping this switch wants every order attempt
  -- refused, not a mix of "not found" and "temporarily closed".
  if (select s.maintenance_mode from public.site_settings s where s.id = 1) then
    raise exception 'shop temporarily closed' using errcode = 'P0001';
  end if;

  return api.create_order_resolved(p_slug, p_kind, p_amount);
end;
$$;

revoke all on function api.create_order(text, text, numeric) from public;
grant execute on function api.create_order(text, text, numeric) to authenticated;

-- The inner worker keeps its old `(text, uuid, numeric)` signature on purpose: it is the
-- part that knows how to make an order, and how to reuse an open one, and none of that
-- changes when the gateway stops being the client's choice.
revoke all on function api.create_order_resolved(text, text, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The paywall projection
-- ---------------------------------------------------------------------------
--
-- Rebuilt to publish exactly six fields per gateway: enough to choose from, and nothing
-- that describes where the money goes. `provider` stays, because it is the only thing
-- telling the storefront this kind is taken automatically - without it the client cannot
-- tell "press Pay" from "here is a wallet number", which is the whole reason the uniformity
-- guard exists.
--
-- `create or replace` re-grants EXECUTE to PUBLIC, which is the default for a new function.
-- The revoke has to follow or this quietly becomes a second anonymous entry point into the
-- link payload - the failure `10_settings.sql` already exists to catch.

create or replace function api.public_link_payload(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when base.doc is null then null
    else jsonb_set(base.doc, '{gateways}', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', g.id,
          'kind', g.kind,
          'name_en', g.name_en,
          'name_bn', g.name_bn,
          'provider', g.provider,
          'sort_order', g.sort_order
        )
        order by g.sort_order, g.name_en
      )
      from public.payment_gateways g
      where g.is_active
    ), '[]'::jsonb))
  end
  from (select api.public_link_payload_v1(p_slug) as doc) base
$$;

revoke all on function api.public_link_payload(text) from public, anon, authenticated;

-- The intermediate wrapper this replaces existed only to add `account_fields` to the list.
-- With `account_fields` no longer published, nothing calls it, and leaving a revoked
-- function around that builds the leaky shape is a trap for whoever reads this file next.
drop function if exists api.public_link_payload_v2(text);

-- ---------------------------------------------------------------------------
-- Closing the other two doors to the same data
-- ---------------------------------------------------------------------------
--
-- Trimming `public_link_payload` is cosmetic on its own. `anon` holds column-level SELECT on
-- `payment_gateways` (core schema) and on `provider, account_fields` (the arbitrary-kind
-- migration), and `payment_gateways_public` projects the destination columns with
-- `security_invoker`. So before this, any visitor could read every gateway's account number
-- and account name straight through PostgREST - `select account_fields from
-- payment_gateways_public` - without placing an order, and the trimmed payload changed
-- nothing they could see. The order page is the only place the destination should exist.
--
-- So the grants go, and the view is rebuilt to the same six fields the payload publishes.
-- `evidence_fields` and `supports_reference` stay granted: they describe the shape of the
-- form rather than where to send money, and withholding them would break a view that exists
-- to serve the method list for no security gain.
--
-- The revoke has to name the columns. `revoke select on public.payment_gateways` would also
-- take back `id, kind, name_en, name_bn, sort_order, is_active`, which the view is built on.

revoke select (account_number, account_name, account_fields,
               instructions_md_en, instructions_md_bn,
               reference_prompt_en, reference_prompt_bn)
  on public.payment_gateways from anon, authenticated;

drop view public.payment_gateways_public;

create view public.payment_gateways_public
with (security_invoker = true)
as
select
  id,
  kind,
  provider,
  name_en,
  name_bn,
  sort_order
from public.payment_gateways
where is_active;

grant select on public.payment_gateways_public to anon, authenticated;

-- ---------------------------------------------------------------------------
-- What the order carries instead
-- ---------------------------------------------------------------------------
--
-- `provider` and `account_fields` are added here, and they are the two that were
-- missing rather than the two that were taken away. `my_order_status` already returned the
-- legacy `account_number`/`account_name` pair, but a gateway saved since `account_fields`
-- existed has an empty pair and its details in the array - so the storefront could render
-- "send your payment to:" followed by nothing. Which mode the order is in (`provider`) was
-- missing outright, so a customer redirected to bKash and coming back could not be told
-- what happened.

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
-- Setting the weight
-- ---------------------------------------------------------------------------
--
-- Restated rather than patched. `create or replace` cannot add behaviour to a function it
-- does not fully restate, so the body is repeated with `weight` threaded through. Only the
-- two column lists and the validation are new.

create or replace function api.admin_upsert_gateway(p_gateway jsonb)
returns public.payment_gateways
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid := nullif(p_gateway ->> 'id', '')::uuid;
  v_row public.payment_gateways;
  v_provider text := nullif(btrim(p_gateway ->> 'provider'), '');
  v_kind text := nullif(btrim(p_gateway ->> 'kind'), '');
  v_environment text := coalesce(nullif(btrim(p_gateway ->> 'environment'), ''), 'sandbox');
  v_account_fields jsonb := coalesce(nullif(p_gateway -> 'account_fields', 'null'::jsonb), '[]'::jsonb);
  v_evidence_fields jsonb := coalesce(nullif(p_gateway -> 'evidence_fields', 'null'::jsonb), '[]'::jsonb);
  v_credentials jsonb := coalesce(nullif(p_gateway -> 'credential_bundle', 'null'::jsonb), '{}'::jsonb);
  v_weight integer := coalesce(nullif(btrim(p_gateway ->> 'weight'), '')::integer, 1);
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_kind is null then
    raise exception 'a payment method needs a kind' using errcode = '22023';
  end if;

  if length(v_kind) > 48 then
    raise exception 'kind is longer than 48 characters' using errcode = '22023';
  end if;

  if v_environment not in ('sandbox', 'live') then
    raise exception 'unknown gateway environment: %', v_environment using errcode = '22023';
  end if;

  -- Checked here as well as by the trigger so the refusal names the field the operator was
  -- editing. The trigger still has to fire: `weight` is also writable by anything holding a
  -- direct connection, and this constraint is the boundary, not this function.
  if v_weight < 1 then
    raise exception 'weight must be at least 1; use is_active to disable a payment method'
      using errcode = '22023';
  end if;

  if v_provider is not null and not exists (
    select 1 from private.auto_providers p
    where p.slug = v_provider and p.is_active
  ) then
    raise exception 'unknown payment provider: %', v_provider using errcode = '22023';
  end if;

  if v_provider is null and v_credentials <> '{}'::jsonb then
    raise exception 'a manual payment method does not take credentials'
      using errcode = '22023';
  end if;

  perform private.validate_account_fields(v_account_fields);

  if v_id is null then
    insert into public.payment_gateways (
      kind, account_number, account_name, account_fields,
      name_en, name_bn,
      instructions_md_en, instructions_md_bn,
      reference_prompt_en, reference_prompt_bn, supports_reference,
      evidence_fields, is_active, sort_order, weight, provider, environment
    )
    values (
      v_kind,
      p_gateway ->> 'account_number',
      p_gateway ->> 'account_name',
      v_account_fields,
      p_gateway ->> 'name_en',
      nullif(p_gateway ->> 'name_bn', ''),
      nullif(p_gateway ->> 'instructions_md_en', ''),
      nullif(p_gateway ->> 'instructions_md_bn', ''),
      nullif(p_gateway ->> 'reference_prompt_en', ''),
      nullif(p_gateway ->> 'reference_prompt_bn', ''),
      coalesce((p_gateway ->> 'supports_reference')::boolean, false),
      v_evidence_fields,
      coalesce((p_gateway ->> 'is_active')::boolean, true),
      coalesce((p_gateway ->> 'sort_order')::integer, 0),
      v_weight,
      v_provider,
      v_environment
    )
    returning * into v_row;
  else
    update public.payment_gateways
    set kind = v_kind,
        account_fields = v_account_fields,
        account_number = p_gateway ->> 'account_number',
        account_name = p_gateway ->> 'account_name',
        name_en = p_gateway ->> 'name_en',
        name_bn = nullif(p_gateway ->> 'name_bn', ''),
        instructions_md_en = nullif(p_gateway ->> 'instructions_md_en', ''),
        instructions_md_bn = nullif(p_gateway ->> 'instructions_md_bn', ''),
        reference_prompt_en = nullif(p_gateway ->> 'reference_prompt_en', ''),
        reference_prompt_bn = nullif(p_gateway ->> 'reference_prompt_bn', ''),
        supports_reference = coalesce((p_gateway ->> 'supports_reference')::boolean, false),
        evidence_fields = v_evidence_fields,
        is_active = coalesce((p_gateway ->> 'is_active')::boolean, true),
        sort_order = coalesce((p_gateway ->> 'sort_order')::integer, 0),
        weight = v_weight,
        provider = v_provider,
        environment = v_environment
    where id = v_id
    returning * into v_row;
  end if;

  if not found then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  if v_provider is not null and v_credentials <> '{}'::jsonb then
    perform private.store_credential_bundle(v_row.id, v_provider, v_credentials);
  elsif v_provider is null then
    delete from private.secret_bundles
    where subject_kind = 'gateway' and subject_id = v_row.id;
  end if;

  return v_row;
end;
$$;

revoke all on function api.admin_upsert_gateway(jsonb) from public, anon, authenticated;
grant execute on function api.admin_upsert_gateway(jsonb) to authenticated;

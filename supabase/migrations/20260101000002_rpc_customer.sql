-- Customer-facing RPCs.
--
-- Every function here is `security definer` with `set search_path = ''` and
-- fully qualified names, because the caller has no grant on the underlying
-- table at all. That is the mechanism behind the security model rather than an
-- inconvenience of it: a customer cannot SELECT `orders`, so the RPC's column
-- list is the only thing they can see, and snapshots such as
-- `min_amount_snapshot` never appear in a response.
--
-- `no_data_found` (P0002) is raised for "not found" and "not allowed" alike, so
-- probing for another customer's order id reveals nothing about whether it
-- exists.

-- Effective minimum for a link: the per-link override, else the global setting.
create or replace function private.effective_min(
  p_link public.paywall_links,
  p_settings public.site_settings
)
returns numeric
language sql
stable
as $$
  select coalesce(p_link.min_amount_override, p_settings.min_amount)
$$;

create or replace function private.effective_hide_min(
  p_link public.paywall_links,
  p_settings public.site_settings
)
returns boolean
language sql
stable
as $$
  select coalesce(p_link.hide_min_override, p_settings.hide_min_amount)
$$;

-- ---------------------------------------------------------------------------
-- Public reads
-- ---------------------------------------------------------------------------

create or replace function api.list_public_links()
returns setof public.paywall_links_public
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.paywall_links_public order by sort_order, slug
$$;

create or replace function api.get_public_link(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with link as (
    select
      l.*,
      s.min_amount as global_min,
      s.hide_min_amount as global_hide
    from public.paywall_links l
    cross join public.site_settings s
    where l.slug = p_slug and l.is_active and s.id = 1
  ),
  resolved as (
    select
      link.*,
      coalesce(link.min_amount_override, link.global_min) as min_amount,
      coalesce(link.hide_min_override, link.global_hide) as hide_min
    from link
  )
  select jsonb_build_object(
    'id', r.id,
    'slug', r.slug,
    'title_en', r.title_en,
    'title_bn', r.title_bn,
    'teaser_md_en', r.teaser_md_en,
    'teaser_md_bn', r.teaser_md_bn,
    'unlock_cta_label_en', r.unlock_cta_label_en,
    'unlock_cta_label_bn', r.unlock_cta_label_bn,
    'unlock_cta_url', r.unlock_cta_url,
    -- The single most important expression in this file. When the minimum is
    -- hidden there is no path by which a client learns it: not here, not
    -- through the public view, not through a column grant on the base table.
    'min_amount', case when r.hide_min then null else r.min_amount end,
    'min_hidden', r.hide_min,
    'gateways', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', g.id,
            'kind', g.kind,
            'account_number', g.account_number,
            'account_name', g.account_name,
            'name_en', g.name_en,
            'name_bn', g.name_bn,
            'instructions_md_en', g.instructions_md_en,
            'instructions_md_bn', g.instructions_md_bn,
            'reference_prompt_en', g.reference_prompt_en,
            'reference_prompt_bn', g.reference_prompt_bn,
            'supports_reference', g.supports_reference,
            'evidence_fields', g.evidence_fields
          )
          order by g.sort_order, g.name_en
        )
        from public.payment_gateways g
        where g.is_active
      ),
      '[]'::jsonb
    )
  )
  from resolved r
$$;

-- The paid body, only for a customer with a live grant.
--
-- Returns scalar `jsonb`, so an ungranted caller gets JSON `null` with a 200
-- rather than a 404. That is deliberate: the caller is a signed-in customer
-- asking whether they have access, and "no" is an answer. The client must test
-- the value instead of reading a key out of it, or it will render an empty body
-- and look like a paywall bug.
--
-- Nothing about the row leaks — no title, no teaser, nothing that would let a
-- crawler walking the slugs confirm the content exists.
create or replace function api.get_unlocked_link(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'slug', l.slug,
    'title_en', l.title_en,
    'title_bn', l.title_bn,
    'unlock_body_md_en', l.unlock_body_md_en,
    'unlock_body_md_bn', l.unlock_body_md_bn,
    'unlock_cta_label_en', l.unlock_cta_label_en,
    'unlock_cta_label_bn', l.unlock_cta_label_bn,
    'unlock_cta_url', l.unlock_cta_url
  )
  from public.paywall_links l
  where l.slug = p_slug
    and exists (
      select 1
      from public.access_grants g
      where g.user_id = auth.uid() and g.link_id = l.id and g.revoked_at is null
    )
$$;

-- ---------------------------------------------------------------------------
-- Order creation
-- ---------------------------------------------------------------------------

create or replace function api.create_order(
  p_slug text,
  p_gateway_id uuid,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_link public.paywall_links;
  v_settings public.site_settings;
  v_gateway public.payment_gateways;
  v_min numeric;
  v_hide boolean;
  v_open public.orders;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_link from public.paywall_links where slug = p_slug and is_active;
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
  select * into v_open
  from public.orders
  where user_id = v_user
    and link_id = v_link.id
    and status in ('draft', 'awaiting_proof', 'rejected', 'locked')
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
      min_amount_snapshot, hide_min_snapshot, probe_count, expires_at
    )
    values (
      v_user, v_link.id, v_gateway.id, 'draft', private.gen_reference_code(),
      greatest(coalesce(p_amount, 0), 0.01),
      v_min, v_hide, 1, now() + interval '30 minutes'
    )
    returning * into v_open;

    return jsonb_build_object('ok', false, 'code', 'below_minimum');
  end if;

  insert into public.orders (
    user_id, link_id, gateway_id, status, reference_code, amount,
    min_amount_snapshot, hide_min_snapshot, expires_at
  )
  values (
    v_user, v_link.id, v_gateway.id, 'awaiting_proof',
    private.gen_reference_code(), p_amount,
    v_min, v_hide, now() + interval '30 minutes'
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
exception
  when unique_violation then
    -- Two different things collide here, and they need different answers.
    --
    -- The one-open-order index fires when the customer double-taps, or opens the
    -- link in a second tab. That is not an error at all: the order the caller
    -- wanted already exists, so hand it back. Only a genuine reference-code
    -- collision — roughly once in 29^8 orders — is worth asking for a retry, and
    -- a retry is the wrong advice for the first case because it will fail
    -- identically every time.
    select o.* into v_open
    from public.orders o
    where o.user_id = v_user
      and o.link_id = v_link.id
      and o.status in ('draft', 'awaiting_proof', 'under_review', 'rejected', 'locked')
    order by o.created_at desc
    limit 1;

    if v_open.id is null then
      raise exception 'could not allocate a reference code, please retry' using errcode = '40001';
    end if;

    if v_open.status = 'locked' then
      return jsonb_build_object('ok', false, 'code', 'locked', 'locked_at', v_open.locked_at);
    end if;

    if v_open.status = 'draft' then
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
end
$$;

-- ---------------------------------------------------------------------------
-- Evidence submission
-- ---------------------------------------------------------------------------

-- Validates one submitted value against its field definition.
create or replace function private.validate_evidence_value(
  p_field jsonb,
  p_value text,
  p_file_path text
)
returns void
language plpgsql
immutable
as $$
declare
  v_key text := p_field ->> 'key';
  v_type text := p_field ->> 'type';
  v_validate text := nullif(btrim(coalesce(p_field ->> 'validate', '')), '');
  v_required boolean := coalesce((p_field ->> 'required')::boolean, false);
  v_max_len integer := nullif(p_field ->> 'max_len', '')::integer;
  v_max_mb integer := nullif(p_field ->> 'max_mb', '')::integer;
  v_normalized text;
begin
  if v_type = 'image' then
    if p_file_path is null then
      if v_required then
        raise exception 'a file is required for %', v_key using errcode = '22023';
      end if;
      return;
    end if;
    if p_value is not null then
      raise exception '% takes a file, not text', v_key using errcode = '22023';
    end if;
    return;
  end if;

  if btrim(coalesce(p_value, '')) = '' then
    if v_required then
      raise exception '% is required', v_key using errcode = '22023';
    end if;
    return;
  end if;

  if p_file_path is not null then
    raise exception '% takes text, not a file', v_key using errcode = '22023';
  end if;

  if v_type in ('text', 'textarea') and length(p_value) > v_max_len then
    raise exception '% accepts at most % characters', v_key, v_max_len using errcode = '22023';
  end if;

  if v_type = 'number' and p_value !~ '^[0-9]{1,18}(\.[0-9]{1,2})?$' then
    raise exception '% must be a number', v_key using errcode = '22023';
  end if;

  if v_validate = 'bd_phone' and private.normalize_bd_phone(p_value) is null then
    raise exception '% is not a valid Bangladeshi mobile number', v_key using errcode = '22023';
  end if;

  if v_validate = 'trxid' and private.normalize_reference(p_value) !~ '^[A-Z0-9]{4,24}$' then
    raise exception '% must be 4 to 24 letters or digits', v_key using errcode = '22023';
  end if;

  if v_validate = 'numeric' and p_value !~ '^[0-9]{1,18}(\.[0-9]{1,2})?$' then
    raise exception '% must be numeric', v_key using errcode = '22023';
  end if;
end
$$;

create or replace function api.submit_evidence(
  p_order_id uuid,
  p_fields jsonb,
  p_files jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_order public.orders;
  v_gateway public.payment_gateways;
  v_defs jsonb;
  v_field jsonb;
  v_submitted jsonb;
  v_key text;
  v_value text;
  v_file text;
  v_files jsonb := coalesce(p_files, '{}'::jsonb);
  v_attempt integer;
  v_required_keys text[];
  v_provided_keys text[];
  v_phone text;
  v_raw_phone text;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id and user_id = v_user;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  -- A rejected order returns to review when the customer resubmits, so
  -- corrections are always a new attempt rather than an edit of the old one.
  if v_order.status not in ('awaiting_proof', 'rejected') then
    raise exception 'this order is not accepting evidence' using errcode = '22023';
  end if;

  if v_order.expires_at < now() then
    raise exception 'this order has expired' using errcode = '22023';
  end if;

  select * into v_gateway from public.payment_gateways where id = v_order.gateway_id;
  v_defs := v_gateway.evidence_fields;

  if jsonb_typeof(p_fields) is distinct from 'object' then
    raise exception 'fields must be a JSON object' using errcode = '22023';
  end if;

  -- Every key the customer sent must be a field this gateway actually asks for,
  -- otherwise extra values could be smuggled into the evidence trail.
  select array_agg(key) into v_provided_keys
  from jsonb_object_keys(p_fields) as key
  where not exists (
    select 1 from jsonb_array_elements(v_defs) d where d ->> 'key' = key
  );

  if v_provided_keys is not null then
    raise exception 'unknown evidence field(s): %', array_to_string(v_provided_keys, ', ')
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_object_keys(v_files) as key
    where not exists (
      select 1 from jsonb_array_elements(v_defs) d where d ->> 'key' = key
    )
  ) then
    raise exception 'unknown evidence file field(s)' using errcode = '22023';
  end if;

  select array_agg(d ->> 'key')
  into v_required_keys
  from jsonb_array_elements(v_defs) d
  where coalesce((d ->> 'required')::boolean, false);

  v_submitted := p_fields || v_files;
  select array_agg(k) into v_provided_keys
  from jsonb_object_keys(v_submitted) as k;

  if v_required_keys is not null
    and exists (select 1 from unnest(v_required_keys) r where not (r = any (v_provided_keys)))
  then
    raise exception 'every required field must be filled in' using errcode = '22023';
  end if;

  v_attempt := v_order.attempt_count + 1;

  for v_field in select * from jsonb_array_elements(v_defs) loop
    v_key := v_field ->> 'key';
    v_value := nullif(p_fields ->> v_key, '');
    v_file := nullif(v_files ->> v_key, '');

    perform private.validate_evidence_value(v_field, v_value, v_file);

    if v_value is null and v_file is null then
      continue;
    end if;

    -- An uploaded file must exist in the proofs bucket, in a folder belonging
    -- to this customer and this order. Checking the path shape alone would let
    -- a customer point at a path that does not exist.
    if v_file is not null then
      if v_file !~ ('^' || v_user::text || '/' || v_order.id::text || '/') then
        raise exception 'invalid file path for %', v_key using errcode = '22023';
      end if;

      if not exists (
        select 1 from storage.objects o
        where o.bucket_id = 'proofs'
          and o.name = v_file
          and o.owner_id = v_user
      ) then
        raise exception 'uploaded file for % was not found', v_key using errcode = '22023';
      end if;
    end if;

    if (v_field ->> 'validate') = 'bd_phone' then
      v_phone := private.normalize_bd_phone(v_value);
      v_raw_phone := v_value;
    end if;

    insert into public.order_evidence (
      order_id, field_key, value_text_raw, value_text_norm, file_path, attempt
    )
    values (
      v_order.id,
      v_key,
      v_value,
      case
        when v_value is null then null
        when (v_field ->> 'validate') is not null
          or v_field ->> 'type' = 'text'
          or v_field ->> 'type' = 'textarea'
        then private.normalize_reference(v_value)
        else btrim(v_value)
      end,
      v_file,
      v_attempt
    );
  end loop;

  -- The sender number is also the recovery identity, so record it on the order
  -- and link it to this account. One field doing three jobs: evidence, the
  -- admin's fraud check against the statement, and the OTP lookup.
  if v_phone is not null then
    update public.orders
    set phone_e164 = v_phone, phone_raw = v_raw_phone
    where id = v_order.id;

    insert into public.customer_contacts (user_id, phone_e164)
    values (v_user, v_phone)
    on conflict (user_id, phone_e164) do nothing;
  end if;

  update public.orders
  set status = 'under_review',
      attempt_count = v_attempt,
      submitted_at = now(),
      reject_reason_en = null,
      reject_reason_bn = null,
      reject_code = null
  where id = v_order.id;

  return jsonb_build_object(
    'ok', true,
    'order_id', v_order.id,
    'attempt', v_attempt,
    'status', 'under_review'
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Customer status reads
--
-- Explicit column lists. `min_amount_snapshot`, `hide_min_snapshot`,
-- `probe_count` and `phone_raw` are deliberately absent: a hidden minimum must
-- not be inferable from the order a customer can see.
-- ---------------------------------------------------------------------------

create or replace function api.my_orders()
returns table (
  id uuid,
  slug text,
  title_en text,
  title_bn text,
  gateway_kind public.gateway_kind,
  status public.order_status,
  reference_code text,
  amount numeric,
  min_amount numeric,
  min_hidden boolean,
  created_at timestamptz,
  expires_at timestamptz,
  submitted_at timestamptz,
  attempt_count integer,
  reject_reason_en text,
  reject_reason_bn text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    o.id,
    l.slug,
    l.title_en,
    l.title_bn,
    g.kind,
    o.status,
    o.reference_code,
    o.amount,
    case when o.hide_min_snapshot then null else o.min_amount_snapshot end,
    o.hide_min_snapshot,
    o.created_at,
    o.expires_at,
    o.submitted_at,
    o.attempt_count,
    o.reject_reason_en,
    o.reject_reason_bn
  from public.orders o
  join public.paywall_links l on l.id = o.link_id
  join public.payment_gateways g on g.id = o.gateway_id
  where o.user_id = auth.uid()
  order by o.created_at desc
$$;

create or replace function api.my_order_status(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id and user_id = auth.uid();
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'id', v_order.id,
    'status', v_order.status,
    'reference_code', v_order.reference_code,
    'amount', v_order.amount,
    'attempt_count', v_order.attempt_count,
    'reject_reason_en', v_order.reject_reason_en,
    'reject_reason_bn', v_order.reject_reason_bn,
    'expires_at', v_order.expires_at
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------

create or replace function api.my_grants()
returns table (slug text, title_en text, title_bn text, granted_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select l.slug, l.title_en, l.title_bn, g.granted_at
  from public.access_grants g
  join public.paywall_links l on l.id = g.link_id
  where g.user_id = auth.uid() and g.revoked_at is null
  order by g.granted_at desc
$$;

-- ---------------------------------------------------------------------------

revoke all on function api.list_public_links() from public;
revoke all on function api.get_public_link(text) from public;
revoke all on function api.get_unlocked_link(text) from public;
revoke all on function api.create_order(text, uuid, numeric) from public;
revoke all on function api.submit_evidence(uuid, jsonb, jsonb) from public;
revoke all on function api.my_orders() from public;
revoke all on function api.my_order_status(uuid) from public;
revoke all on function api.my_grants() from public;

grant execute on function api.list_public_links() to anon, authenticated;
grant execute on function api.get_public_link(text) to anon, authenticated;
grant execute on function api.get_unlocked_link(text) to authenticated;
grant execute on function api.create_order(text, uuid, numeric) to authenticated;
grant execute on function api.submit_evidence(uuid, jsonb, jsonb) to authenticated;
grant execute on function api.my_orders() to authenticated;
grant execute on function api.my_order_status(uuid) to authenticated;
grant execute on function api.my_grants() to authenticated;

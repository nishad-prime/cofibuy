-- Supabase changed storage.objects.owner_id from uuid to text, so comparing
-- it to the uuid parameter raised `operator does not exist: text = uuid` the
-- first time a customer submitted image proof - PL/pgSQL plans statements
-- lazily, so only the file branch ever hit it, and text-only evidence kept
-- working. Both sides go through text: correct against either shape of the
-- column, and the same thing the storage RLS policies already do.

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
          and (o.owner_id)::text = v_user::text
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

revoke all on function api.submit_evidence(uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function api.submit_evidence(uuid, jsonb, jsonb) to authenticated;

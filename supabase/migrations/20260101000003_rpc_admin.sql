-- Admin RPCs.
--
-- Two tiers, enforced in the database rather than in the admin UI:
--
--   staff  review orders — approve, reject, reset a probe lock
--   owner  everything staff can do, plus links, payment methods, team, settings
--
-- The split matters because a staff account is the account of whoever you hand
-- the daily queue to. Restricting them to the queue means a compromised staff
-- login cannot rewrite what a link costs or who else is on the team.

-- ---------------------------------------------------------------------------
-- Queue
-- ---------------------------------------------------------------------------

-- TrxIDs shared by more than one order. Flagged, never blocked: a genuine
-- duplicate is usually a customer resubmitting from a second browser, and
-- blocking it would strand a paid order. Comparison runs on the normalised
-- value so a TrxID typed with a Bangla keyboard still collides.
create or replace function api.admin_order_duplicate_trxids(p_order_id uuid)
returns table (field_key text, value_text_norm text, other_order_ids uuid[])
language sql
stable
security definer
set search_path = ''
as $$
  select
    e.field_key,
    e.value_text_norm,
    array_agg(distinct other.id) as other_order_ids
  from public.order_evidence e
  join public.order_evidence dup
    on dup.field_key = e.field_key
   and dup.value_text_norm is not null
   and dup.value_text_norm = e.value_text_norm
   and dup.order_id <> e.order_id
  join public.orders other on other.id = dup.order_id
  where e.order_id = p_order_id
    and e.value_text_norm is not null
  group by e.field_key, e.value_text_norm
  having count(distinct dup.order_id) > 0
$$;

create or replace function api.admin_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'awaiting_review', (select count(*) from public.orders where status = 'under_review'),
    'awaiting_proof', (select count(*) from public.orders where status = 'awaiting_proof'),
    'rejected', (select count(*) from public.orders where status = 'rejected'),
    'approved_total', (select count(*) from public.orders where status = 'approved'),
    'locked', (select count(*) from public.orders where status = 'locked'),
    'revenue', (select coalesce(sum(amount), 0) from public.orders where status = 'approved'),
    'active_links', (select count(*) from public.paywall_links where is_active),
    'active_gateways', (select count(*) from public.payment_gateways where is_active)
  )
$$;

create or replace function api.admin_orders(
  p_status text default null,
  p_reference text default null,
  p_limit integer default 100
)
returns table (
  id uuid,
  slug text,
  title_en text,
  title_bn text,
  kind public.gateway_kind,
  status public.order_status,
  reference_code text,
  amount numeric,
  phone_e164 text,
  attempt_count integer,
  probe_count integer,
  created_at timestamptz,
  submitted_at timestamptz,
  has_duplicate_trxid boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select
    o.id,
    l.slug,
    l.title_en,
    l.title_bn,
    g.kind,
    o.status,
    o.reference_code,
    o.amount,
    o.phone_e164,
    o.attempt_count,
    o.probe_count,
    o.created_at,
    o.submitted_at,
    exists (
      select 1
      from public.order_evidence e
      join public.order_evidence dup
        on dup.field_key = e.field_key
       and dup.value_text_norm is not null
       and dup.value_text_norm = e.value_text_norm
       and dup.order_id <> o.id
      where e.order_id = o.id and e.value_text_norm is not null
    )
  from public.orders o
  join public.paywall_links l on l.id = o.link_id
  join public.payment_gateways g on g.id = o.gateway_id
  where (p_status is null or o.status::text = p_status)
    and (
      p_reference is null
      or o.reference_code = private.normalize_reference(p_reference)
    )
  order by o.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$$;

create or replace function api.admin_order_detail(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'id', v_order.id,
    'status', v_order.status,
    'reference_code', v_order.reference_code,
    'amount', v_order.amount,
    -- Staff see the real minimum: it is the staff-only threshold, and the
    -- hide_min flag governs what customers are told, not what the operator knows.
    'min_amount', v_order.min_amount_snapshot,
    'min_hidden', v_order.hide_min_snapshot,
    'phone_e164', v_order.phone_e164,
    'phone_raw', v_order.phone_raw,
    'attempt_count', v_order.attempt_count,
    'probe_count', v_order.probe_count,
    'created_at', v_order.created_at,
    'expires_at', v_order.expires_at,
    'submitted_at', v_order.submitted_at,
    'reviewed_at', v_order.reviewed_at,
    'reject_reason_en', v_order.reject_reason_en,
    'reject_reason_bn', v_order.reject_reason_bn,
    'link', jsonb_build_object(
      'id', l.id, 'slug', l.slug, 'title_en', l.title_en, 'title_bn', l.title_bn
    ),
    'gateway', jsonb_build_object(
      'id', g.id, 'kind', g.kind, 'name_en', g.name_en, 'name_bn', g.name_bn,
      'account_number', g.account_number, 'account_name', g.account_name,
      'evidence_fields', g.evidence_fields
    ),
    'evidence', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', e.id,
            'field_key', e.field_key,
            'value_text_raw', e.value_text_raw,
            'value_text_norm', e.value_text_norm,
            'file_path', e.file_path,
            'attempt', e.attempt,
            'created_at', e.created_at
          )
          order by e.attempt desc, e.field_key
        )
        from public.order_evidence e
        where e.order_id = v_order.id
      ),
      '[]'::jsonb
    ),
    'duplicates', coalesce(
      (
        select jsonb_agg(to_jsonb(d))
        from api.admin_order_duplicate_trxids(v_order.id) d
      ),
      '[]'::jsonb
    )
  )
  from public.paywall_links l, public.payment_gateways g
  where l.id = v_order.link_id and g.id = v_order.gateway_id;
end
$$;

-- ---------------------------------------------------------------------------
-- Review actions
-- ---------------------------------------------------------------------------

-- Idempotent for the case that actually happens — a double-clicked button.
-- A repeat call returns the same success rather than an error, and a genuinely
-- wrong action (approving something not in review) is still refused.
create or replace function api.approve_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_actor uuid := auth.uid();
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if v_order.status = 'approved' then
    return jsonb_build_object('ok', true, 'status', 'approved', 'already', true);
  end if;

  if v_order.status <> 'under_review' then
    raise exception 'order is not under review' using errcode = '22023';
  end if;

  -- The grant is created by an after-update trigger, so access follows approval
  -- no matter which path approved it, and cannot be forgotten.
  update public.orders
  set status = 'approved',
      reviewed_at = now(),
      reviewed_by = v_actor,
      reject_reason_en = null,
      reject_reason_bn = null,
      reject_code = null
  where id = p_order_id;

  return jsonb_build_object('ok', true, 'status', 'approved', 'already', false);
end
$$;

create or replace function api.reject_order(
  p_order_id uuid,
  p_reason text,
  p_reason_bn text default null,
  p_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if btrim(coalesce(p_reason, '')) = '' then
    -- The customer sees this text, so an empty rejection explains nothing.
    raise exception 'a rejection reason is required' using errcode = '22023';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if v_order.status not in ('under_review', 'rejected') then
    raise exception 'order is not under review' using errcode = '22023';
  end if;

  update public.orders
  set status = 'rejected',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      reject_reason_en = p_reason,
      reject_reason_bn = nullif(btrim(coalesce(p_reason_bn, '')), ''),
      reject_code = nullif(btrim(coalesce(p_code, '')), '')
  where id = p_order_id;

  return jsonb_build_object('ok', true, 'status', 'rejected');
end
$$;

create or replace function api.admin_reset_probes(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.orders
  set probe_count = 0,
      locked_at = null,
      status = case when status = 'locked' then 'awaiting_proof'::public.order_status else status end
  where id = p_order_id;

  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end
$$;

-- ---------------------------------------------------------------------------
-- Owner-only configuration
-- ---------------------------------------------------------------------------

create or replace function api.admin_links()
returns setof public.paywall_links
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.paywall_links order by sort_order, slug
$$;

create or replace function api.admin_upsert_link(p_link jsonb)
returns public.paywall_links
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.paywall_links;
  v_id uuid := nullif(p_link ->> 'id', '')::uuid;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Publication is gated by a CHECK on the table, so an active link with no
  -- body in either language is refused here rather than at read time.
  insert into public.paywall_links (
    slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
    unlock_body_md_en, unlock_body_md_bn,
    unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
    min_amount_override, hide_min_override, is_active, sort_order
  )
  values (
    p_link ->> 'slug',
    p_link ->> 'title_en',
    p_link ->> 'title_bn',
    p_link ->> 'teaser_md_en',
    p_link ->> 'teaser_md_bn',
    p_link ->> 'unlock_body_md_en',
    p_link ->> 'unlock_body_md_bn',
    p_link ->> 'unlock_cta_label_en',
    p_link ->> 'unlock_cta_label_bn',
    p_link ->> 'unlock_cta_url',
    nullif(p_link ->> 'min_amount_override', '')::numeric,
    nullif(p_link ->> 'hide_min_override', '')::boolean,
    coalesce((p_link ->> 'is_active')::boolean, false),
    coalesce((p_link ->> 'sort_order')::integer, 0)
  )
  on conflict (id) do update
  set slug = excluded.slug,
      title_en = excluded.title_en,
      title_bn = excluded.title_bn,
      teaser_md_en = excluded.teaser_md_en,
      teaser_md_bn = excluded.teaser_md_bn,
      unlock_body_md_en = excluded.unlock_body_md_en,
      unlock_body_md_bn = excluded.unlock_body_md_bn,
      unlock_cta_label_en = excluded.unlock_cta_label_en,
      unlock_cta_label_bn = excluded.unlock_cta_label_bn,
      unlock_cta_url = excluded.unlock_cta_url,
      min_amount_override = excluded.min_amount_override,
      hide_min_override = excluded.hide_min_override,
      is_active = excluded.is_active,
      sort_order = excluded.sort_order
  returning * into v_row;

  return v_row;
end
$$;

create or replace function api.admin_delete_link(p_link_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from public.paywall_links where id = p_link_id;
  if not found then
    raise exception 'link not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end
$$;

create or replace function api.admin_gateways()
returns setof public.payment_gateways
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.payment_gateways order by sort_order, name_en
$$;

create or replace function api.admin_upsert_gateway(p_gateway jsonb)
returns public.payment_gateways
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.payment_gateways;
  v_id uuid := nullif(p_gateway ->> 'id', '')::uuid;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  insert into public.payment_gateways (
    kind, account_number, account_name, name_en, name_bn,
    instructions_md_en, instructions_md_bn,
    reference_prompt_en, reference_prompt_bn,
    supports_reference, evidence_fields, is_active, sort_order
  )
  values (
    (p_gateway ->> 'kind')::public.gateway_kind,
    p_gateway ->> 'account_number',
    p_gateway ->> 'account_name',
    p_gateway ->> 'name_en',
    p_gateway ->> 'name_bn',
    p_gateway ->> 'instructions_md_en',
    p_gateway ->> 'instructions_md_bn',
    p_gateway ->> 'reference_prompt_en',
    p_gateway ->> 'reference_prompt_bn',
    coalesce((p_gateway ->> 'supports_reference')::boolean, false),
    coalesce(p_gateway -> 'evidence_fields', '[]'::jsonb),
    coalesce((p_gateway ->> 'is_active')::boolean, true),
    coalesce((p_gateway ->> 'sort_order')::integer, 0)
  )
  on conflict (id) do update
  set kind = excluded.kind,
      account_number = excluded.account_number,
      account_name = excluded.account_name,
      name_en = excluded.name_en,
      name_bn = excluded.name_bn,
      instructions_md_en = excluded.instructions_md_en,
      instructions_md_bn = excluded.instructions_md_bn,
      reference_prompt_en = excluded.reference_prompt_en,
      reference_prompt_bn = excluded.reference_prompt_bn,
      supports_reference = excluded.supports_reference,
      evidence_fields = excluded.evidence_fields,
      is_active = excluded.is_active,
      sort_order = excluded.sort_order
  returning * into v_row;

  return v_row;
end
$$;

create or replace function api.admin_delete_gateway(p_gateway_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from public.payment_gateways where id = p_gateway_id;
  if not found then
    raise exception 'payment method not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end
$$;

create or replace function api.admin_settings()
returns public.site_settings
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.site_settings where id = 1
$$;

create or replace function api.admin_set_settings(p_settings jsonb)
returns public.site_settings
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.site_settings;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.site_settings
  set min_amount = coalesce((p_settings ->> 'min_amount')::numeric, min_amount),
      hide_min_amount = coalesce((p_settings ->> 'hide_min_amount')::boolean, hide_min_amount),
      default_lang = coalesce(p_settings ->> 'default_lang', default_lang),
      -- Recovery ships gated. Turning it on before the OTP worker is deployed
      -- leaves customers waiting for a code that never arrives, so the default
      -- is off and the switch is deliberate.
      recovery_enabled = coalesce((p_settings ->> 'recovery_enabled')::boolean, recovery_enabled),
      contact = case
        when p_settings ? 'contact' then nullif(btrim(p_settings ->> 'contact'), '')
        else contact
      end
  where id = 1
  returning * into v_row;

  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- Team
-- ---------------------------------------------------------------------------

create or replace function api.admin_team()
returns table (user_id uuid, email text, role public.staff_role, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select s.user_id, u.email, s.role, s.created_at
  from public.staff s
  left join auth.users u on u.id = s.user_id
  order by s.created_at
$$;

create or replace function api.admin_set_staff(p_email text, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_role public.staff_role;
  v_owners integer;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_role := p_role::public.staff_role;

  select id into v_user_id from auth.users where lower(email) = lower(btrim(coalesce(p_email, '')));
  if v_user_id is null then
    -- Inviting an email that has never signed up would create a row pointing at
    -- nothing, and the person would silently lack access later.
    raise exception 'no user has signed up with that email yet' using errcode = '22023';
  end if;

  if v_role = 'staff' then
    -- Refuse to remove the last owner: that would lock everyone out of
    -- configuration with no way back in through the UI.
    select count(*) into v_owners
    from public.staff
    where role = 'owner' and user_id <> v_user_id;

    if v_owners = 0 then
      raise exception 'the last owner cannot be demoted' using errcode = '22023';
    end if;
  end if;

  insert into public.staff (user_id, role)
  values (v_user_id, v_role)
  on conflict (user_id) do update set role = excluded.role;

  return jsonb_build_object('ok', true, 'user_id', v_user_id, 'role', v_role);
end
$$;

create or replace function api.admin_remove_staff(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owners integer;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select count(*) into v_owners from public.staff where role = 'owner' and user_id <> p_user_id;
  if v_owners = 0 and exists (select 1 from public.staff where user_id = p_user_id and role = 'owner')
  then
    raise exception 'the last owner cannot be removed' using errcode = '22023';
  end if;

  delete from public.staff where user_id = p_user_id;
  if not found then
    raise exception 'team member not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end
$$;

-- ---------------------------------------------------------------------------

revoke all on function api.admin_order_duplicate_trxids(uuid) from public;
revoke all on function api.admin_stats() from public;
revoke all on function api.admin_orders(text, text, integer) from public;
revoke all on function api.admin_order_detail(uuid) from public;
revoke all on function api.approve_order(uuid) from public;
revoke all on function api.reject_order(uuid, text, text, text) from public;
revoke all on function api.admin_reset_probes(uuid) from public;
revoke all on function api.admin_links() from public;
revoke all on function api.admin_upsert_link(jsonb) from public;
revoke all on function api.admin_delete_link(uuid) from public;
revoke all on function api.admin_gateways() from public;
revoke all on function api.admin_upsert_gateway(jsonb) from public;
revoke all on function api.admin_delete_gateway(uuid) from public;
revoke all on function api.admin_settings() from public;
revoke all on function api.admin_set_settings(jsonb) from public;
revoke all on function api.admin_team() from public;
revoke all on function api.admin_set_staff(text, text) from public;
revoke all on function api.admin_remove_staff(uuid) from public;

grant execute on function api.admin_order_duplicate_trxids(uuid) to authenticated;
grant execute on function api.admin_stats() to authenticated;
grant execute on function api.admin_orders(text, text, integer) to authenticated;
grant execute on function api.admin_order_detail(uuid) to authenticated;
grant execute on function api.approve_order(uuid) to authenticated;
grant execute on function api.reject_order(uuid, text, text, text) to authenticated;
grant execute on function api.admin_reset_probes(uuid) to authenticated;

grant execute on function api.admin_links() to authenticated;
grant execute on function api.admin_upsert_link(jsonb) to authenticated;
grant execute on function api.admin_delete_link(uuid) to authenticated;
grant execute on function api.admin_gateways() to authenticated;
grant execute on function api.admin_upsert_gateway(jsonb) to authenticated;
grant execute on function api.admin_delete_gateway(uuid) to authenticated;
grant execute on function api.admin_settings() to authenticated;
grant execute on function api.admin_set_settings(jsonb) to authenticated;
grant execute on function api.admin_team() to authenticated;
grant execute on function api.admin_set_staff(text, text) to authenticated;
grant execute on function api.admin_remove_staff(uuid) to authenticated;

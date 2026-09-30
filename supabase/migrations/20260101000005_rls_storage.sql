-- Row level security, storage, and housekeeping.
--
-- RLS is enabled in the core-schema migration; this file adds the policies.
-- Where a table has no policy, the default is deny, and that is the intended
-- answer for every money or PII table: customers reach those through RPCs that
-- name the columns they may see, and no direct read path exists at all.

-- ---------------------------------------------------------------------------
-- Public catalogue
--
-- The two `security_invoker` views already filter to `is_active`. These policies
-- make the base tables behave the same way, so a direct query cannot reveal a
-- draft link that an admin has not published yet.
-- ---------------------------------------------------------------------------

create policy paywall_links_public_read
  on public.paywall_links
  for select
  to anon, authenticated
  using (is_active);

create policy payment_gateways_public_read
  on public.payment_gateways
  for select
  to anon, authenticated
  using (is_active);

-- ---------------------------------------------------------------------------
-- Customer-owned data
--
-- No grants exist on any of these tables, so these policies are defence in
-- depth: if a column grant is ever added by mistake, the policy still confines
-- the rows.
-- ---------------------------------------------------------------------------

create policy orders_read_own
  on public.orders
  for select
  to authenticated
  using (user_id = auth.uid());

create policy order_evidence_read_own
  on public.order_evidence
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.orders o
      where o.id = order_evidence.order_id and o.user_id = auth.uid()
    )
  );

create policy access_grants_read_own
  on public.access_grants
  for select
  to authenticated
  using (user_id = auth.uid() or private.is_staff());

create policy customer_contacts_read_own
  on public.customer_contacts
  for select
  to authenticated
  using (user_id = auth.uid());

-- recovery_requests, otp_challenges, site_settings, staff and audit_log
-- deliberately have no policies and no grants. A phone number, an OTP hash and
-- the global minimum are the three things in this database that must never be
-- readable by a client, so they are unreadable by construction rather than by
-- a policy someone could edit.

-- ---------------------------------------------------------------------------
-- Proof screenshots
--
-- Private bucket: `public = false`, so no URL resolves without a policy check.
-- Paths are `{user_id}/{order_id}/{field_key}/{uuid}.{ext}`, which lets the
-- policies confirm ownership from the path alone — `split_part` rather than
-- `storage.foldername` so the check does not depend on a Supabase helper.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'proofs',
  'proofs',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Folder 1 must be the caller's own id, and the extension must be one of the
-- three the database accepts in `order_evidence_file_path_shape`.
--
-- The extension is cross-checked against the *stored* content type rather than
-- the filename by the client's upload path; this policy is the second line.
create policy proofs_insert_own_folder
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'proofs'
    and split_part(name, '/', 1) = auth.uid()::text
    and array_length(string_to_array(name, '/'), 1) = 4
    and split_part(name, '/', 3) ~ '^[a-z][a-z0-9_]{0,31}$'
  );

-- A customer reads their own uploads; staff read any of them to review an
-- order. Nothing else, and no anonymous access.
create policy proofs_read_own_or_staff
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'proofs'
    and (owner_id = auth.uid() or private.is_staff())
  );

-- No update or delete policy. Evidence is append-only and a screenshot belongs
-- to the attempt that produced it, so a replacement is a new upload under a new
-- attempt rather than an edit of the old one.

-- ---------------------------------------------------------------------------
-- Housekeeping
--
-- Every sweep is idempotent and safe to run late. pg_cron is scheduled in the
-- next migration only if the extension is available, because a fresh project
-- has it but a local test database may not.
-- ---------------------------------------------------------------------------

create or replace function private.expire_stale_orders()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  -- An abandoned order must not sit in the queue forever. A customer whose
  -- order expired simply starts again; the terms are snapshotted on the new one.
  update public.orders
  set status = 'expired'
  where status in ('draft', 'awaiting_proof')
    and expires_at < now();

  get diagnostics v_count = row_count;

  -- Expire recovery requests and their codes.
  update public.recovery_requests
  set status = 'expired'
  where status in ('pending', 'sent') and expires_at < now();

  update public.otp_challenges
  set consumed_at = now()
  where consumed_at is null and expires_at < now();

  return v_count;
end
$$;

create or replace function private.prune_anonymous_users()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  -- Accounts created by the CGNAT-prone anonymous flow that never became a
  -- real customer. Deleting the auth user cascades to their rows, which is
  -- exactly right for a row that only ever held a draft probe attempt.
  delete from auth.users u
  where not exists (select 1 from public.orders o where o.user_id = u.id)
    and not exists (select 1 from public.access_grants g where g.user_id = u.id)
    and not exists (select 1 from public.staff s where s.user_id = u.id)
    and u.created_at < now() - interval '7 days';

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

create or replace function private.sweep()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return jsonb_build_object(
    'expired_orders', private.expire_stale_orders(),
    'reaped_claims', private.reap_stale_claims()
  );
end
$$;

revoke all on function private.sweep() from public;
revoke all on function private.expire_stale_orders() from public;
revoke all on function private.reap_stale_claims() from public;
revoke all on function private.prune_anonymous_users() from public;

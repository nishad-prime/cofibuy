-- ---------------------------------------------------------------------------
-- Whether an automatic gateway has credentials stored
-- ---------------------------------------------------------------------------
--
-- `api.gateway_credential_bundle` answers the same question and returns the id, but it is
-- service_role only: a bundle id is a pointer to the plaintext store, and the admin UI has no
-- business holding one. That leaves the form unable to distinguish "this gateway has no
-- credentials yet" from "this gateway has credentials and the box you are looking at is
-- showing a placeholder" - so an operator opening an automatic gateway for the first time
-- sees four password fields that read as though they were already filled in, and has no way
-- to tell that a payment would fail for want of a bundle.
--
-- A boolean is not a pointer, so this is safe to expose where the id is not. It reports
-- existence only: no key names, no values, no partial state. Owner-only, matching
-- `admin_upsert_gateway`, because whether a merchant credential exists is itself owner-only
-- configuration and staff must not be able to enumerate it.
--
-- Returns false rather than raising when the gateway does not exist, so the caller can treat
-- "absent" and "no credentials" identically. A stale id in a form is not worth an error.
create or replace function api.admin_gateway_has_credentials(p_gateway_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select case
    when not private.is_owner() then false
    else exists (
      select 1
      from public.payment_gateways g
      join private.secret_bundles b
        on b.subject_kind = 'gateway' and b.subject_id = g.id
      where g.id = p_gateway_id
    )
  end
$$;

revoke all on function api.admin_gateway_has_credentials(uuid) from public, anon;
grant execute on function api.admin_gateway_has_credentials(uuid) to authenticated;

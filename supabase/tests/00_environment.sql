-- Test environment shim.
--
-- Emulates the parts of a Supabase project that our migrations and tests
-- depend on but do not own: the `auth` schema with its request-scoped identity
-- helpers, the `storage` tables, and the four PostgREST roles.
--
-- This is applied by the local test runner only. Real Supabase projects already
-- provide all of it, which is why none of this appears in a migration.
--
-- The auth helpers read the same GUCs PostgREST sets, so a test can impersonate
-- a user with:
--
--   select set_config('request.jwt.claim.sub', '<uuid>', true);
--   select set_config('request.jwt.claim.role', 'authenticated', true);
--
-- `is_local = true` marks those claims, so a test can never accidentally
-- impersonate through some other path.

create schema if not exists auth;
create schema if not exists storage;

-- Roles PostgREST connects as. The local runner creates real ones; this block
-- is a no-op where they already exist.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

-- Minimal stand-in for Supabase's auth.users. Only the columns our foreign keys
-- and the staff invite flow touch.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  created_at timestamptz not null default now()
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon')
$$;

create or replace function auth.email()
returns text
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.email', true), '')
$$;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid, auth.role, auth.email, auth.jwt to anon, authenticated, service_role;

-- Storage tables. `storage.objects` is the real shape that storage RLS
-- policies are written against: `owner_id` holds the folder-1 uuid.
create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz not null default now()
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null references storage.buckets(id),
  name text not null,
  owner_id uuid,
  metadata jsonb,
  created_at timestamptz not null default now(),
  unique (bucket_id, name)
);

grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.buckets, storage.objects to authenticated, service_role;
grant select on storage.buckets, storage.objects to anon;

-- Supabase Vault, for the same reason as auth and storage: the migrations call it and a
-- local Postgres has no such extension.
--
-- The function signatures deliberately mirror supabase/postgres's vault API, because the
-- migrations are written against that API and would otherwise acquire a second, local-only
-- calling convention. The drift risk is real and worth stating plainly: if a signature here
-- stops matching the managed one, a migration can pass locally and fail on a real project.
-- Anything that writes a secret must be signed against a live project before it is trusted.
create schema if not exists vault;

-- `secret` is text, and that is load-bearing. Supabase Vault treats the value as an opaque
-- blob and never parses it, so a harness that declares it jsonb lets jsonb-shaped code pass
-- locally and then fail on the real project with "return type mismatch ... Actual return type
-- is text". The first version of this file did exactly that, and the cost was a migration
-- that read, wrote and returned jsonb against a column that only ever holds text.
create table if not exists vault.secrets (
  id uuid primary key default gen_random_uuid(),
  name text,
  description text default '',
  secret text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Supabase exposes the decrypted value through a view rather than the base table. Mirroring
-- that means a migration cannot accidentally read `secret` from the wrong object and pass
-- locally where the permission would differ in production.
create or replace view vault.decrypted_secrets as
  select id, name, description, secret, created_at, updated_at
  from vault.secrets;

create or replace function vault.create_secret(
  new_secret text,
  new_name text default null,
  new_description text default ''
)
returns uuid
language sql
volatile
as $$
  insert into vault.secrets (name, description, secret)
  values (new_name, new_description, new_secret)
  returning id
$$;

create or replace function vault.update_secret(
  secret_id uuid,
  new_secret text default null,
  new_name text default null,
  new_description text default ''
)
returns void
language sql
volatile
as $$
  update vault.secrets
  set secret = coalesce(new_secret, secret),
      name = coalesce(new_name, name),
      description = coalesce(new_description, description),
      updated_at = now()
  where id = secret_id
$$;

create or replace function vault.delete_secret(secret_id uuid)
returns void
language sql
volatile
as $$
  delete from vault.secrets where id = secret_id
$$;

grant usage on schema vault to anon, authenticated, service_role;
grant execute on function vault.create_secret, vault.update_secret, vault.delete_secret
  to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Bootstrap data for a fresh deployment.
--
-- This seed creates exactly one thing: the first owner. Everything else a
-- shop needs - payment methods, pages, the words on them - is configured by
-- that owner through the admin panel, so a new deployment starts empty and
-- production state never has to match it.
--
-- Runs automatically on `supabase db reset` (local stack). For a hosted
-- project it is not run by `supabase db push`, so paste it into the
-- dashboard's SQL editor once, after changing the owner email below.
--
-- Idempotent: safe to run again.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The first owner
--
-- `api.admin_set_staff` refuses anyone who is not already an owner, so the very
-- first one cannot be created through the API and has to be inserted here. Put
-- the email you will actually sign in with. The user row is created if it does
-- not exist, so you can run this before signing up; the password still has to
-- be set through the app or the dashboard.
-- ---------------------------------------------------------------------------

do $$
declare
  v_owner_email constant text := 'endstudeo@gmail.com';
  v_user_id uuid;
begin
  select id into v_user_id from auth.users where lower(email) = lower(v_owner_email);

  if v_user_id is null then
    insert into auth.users (email) values (v_owner_email) returning id into v_user_id;
    raise notice 'created auth user % for the first owner', v_user_id;
  end if;

  insert into public.staff (user_id, role) values (v_user_id, 'owner')
  on conflict (user_id) do update set role = 'owner';
end
$$;

-- Fix type mismatch for admin_team email return type
create or replace function api.admin_team()
returns table (user_id uuid, email text, role public.staff_role, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select s.user_id, u.email::text, s.role, s.created_at
  from public.staff s
  left join auth.users u on u.id = s.user_id
  order by s.created_at;
end
$$;

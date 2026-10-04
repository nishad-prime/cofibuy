-- `api.admin_settings` returned a multi-column subquery straight from a
-- plpgsql function whose result type is the composite `public.site_settings`,
-- so every call failed with `subquery must return only one column` and the
-- settings page could never load. Selecting into a variable of the composite
-- type gives Postgres the single row value it expects.
create or replace function api.admin_settings()
returns public.site_settings
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.site_settings;
begin
  if not private.is_owner() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select s.* into v_row from public.site_settings s where s.id = 1;

  return v_row;
end
$$;
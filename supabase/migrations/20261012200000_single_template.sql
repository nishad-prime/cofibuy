-- The legacy layouts (standard, landing, minimal-product) are removed as
-- superseded; the sales page is the only shipped template for now. The
-- allowlist stays a list so adding a template back is a one-line change here
-- plus its registry entry. Both live rows already use sales-landing.

create or replace function private.guard_page_template()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.template not in ('sales-landing') then
    raise exception 'unknown template %', new.template using errcode = '22023';
  end if;

  -- The config is handed to whatever form and renderer the template declares.
  -- Anything but an object has no meaning on either side of that contract.
  if jsonb_typeof(new.template_config) <> 'object' then
    raise exception 'template_config must be a JSON object' using errcode = '22023';
  end if;

  return new;
end
$$;

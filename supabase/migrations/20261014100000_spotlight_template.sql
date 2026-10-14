-- The spotlight template joins the allowlist: a three-section cinematic page
-- (hero, video, ending) with a lighter config than the sales page.

create or replace function private.guard_page_template()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.template not in ('sales-landing', 'spotlight') then
    raise exception 'unknown template %', new.template using errcode = '22023';
  end if;

  -- The config is handed to whatever form and renderer the template declares.
  -- Anything but an object has no meaning on either side of that contract.
  if jsonb_typeof(new.template_config) <> 'object' then
    raise exception 'template_config must be a JSON object' using errcode = '22023';
  end if;

  -- Presets: a JSON array of positive numbers, eight at most. Every other
  -- shape is refused at the write, not at the customer's first render.
  if jsonb_typeof(new.amount_presets) <> 'array' then
    raise exception 'amount_presets must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(new.amount_presets) > 8 then
    raise exception 'at most 8 amount presets' using errcode = '22023';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(new.amount_presets) v
    where jsonb_typeof(v) <> 'number' or (v)::numeric < 1
  ) then
    raise exception 'amount presets must be positive numbers' using errcode = '22023';
  end if;

  return new;
end
$$;

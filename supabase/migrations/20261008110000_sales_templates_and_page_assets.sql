-- ---------------------------------------------------------------------------
-- Templates become complete page designs, and pages get their own images.
--
-- Two changes with one consequence each:
--
--   1. The template allowlist grows: `sales-landing` is a section-by-section
--      selling page, and `minimal-product` is its compact counterpart. The
--      trigger's list is the only place the database names templates, so it
--      moves with the registry in `src/pages/templates/registry.ts`.
--   2. Page content includes pictures, and pictures need somewhere to live.
--      The `proofs` bucket is private, per-order and per-customer - evidence
--      is not page art. A public `page-assets` bucket, written only by
--      staff, gives every template a place for its hero and section images
--      that the customer's browser can actually load.
-- ---------------------------------------------------------------------------

-- The trigger reads the allowlist on every page write; the new ids are the
-- registry's contract, and anything the app does not declare stays refused.
create or replace function private.guard_page_template() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.template not in ('standard', 'landing', 'sales-landing', 'minimal-product') then
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

-- Page art is public by design - the customer's browser loads it directly -
-- but only the panel may fill the bucket. `private.is_staff()` is the same
-- gate every admin read uses, evaluated per request against the caller's JWT.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'page-assets',
  'page-assets',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy page_assets_public_read
  on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'page-assets');

create policy page_assets_staff_write
  on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'page-assets' and private.is_staff());

create policy page_assets_staff_update
  on storage.objects
  for update
  to authenticated
  using (bucket_id = 'page-assets' and private.is_staff());

create policy page_assets_staff_delete
  on storage.objects
  for delete
  to authenticated
  using (bucket_id = 'page-assets' and private.is_staff());

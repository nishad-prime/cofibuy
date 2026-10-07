-- ---------------------------------------------------------------------------
-- The gateway projection also carries `account_fields`.
--
-- Missed in the previous migration: since gateways became arbitrary, the
-- destination lives in `account_fields` - ordered, labelled rows - and the
-- legacy `account_number`/`account_name` columns are empty for any gateway
-- created since. Without this key the manual form rendered an empty account
-- card for exactly the gateways the feature was built for.
-- ---------------------------------------------------------------------------

create or replace function api.public_page_payload(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when base.doc is null then null
    else jsonb_set(base.doc, '{gateways}', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', g.id,
          'kind', g.kind,
          'name_en', g.name_en,
          'name_bn', g.name_bn,
          'provider', g.provider,
          'sort_order', g.sort_order,
          -- Where the money goes, and what proof this method wants: the page
          -- renders both the moment the method is selected, not after an order.
          'account_number', g.account_number,
          'account_name', g.account_name,
          'account_fields', g.account_fields,
          'instructions_md_en', g.instructions_md_en,
          'instructions_md_bn', g.instructions_md_bn,
          'reference_prompt_en', g.reference_prompt_en,
          'reference_prompt_bn', g.reference_prompt_bn,
          'supports_reference', g.supports_reference,
          'evidence_fields', g.evidence_fields
        )
        order by g.sort_order, g.name_en
      )
      from public.payment_gateways g
      where g.is_active
    ), '[]'::jsonb)) || jsonb_build_object(
      'is_listed', (
        select p.is_listed from public.pages p where p.slug = p_slug and p.is_active
      )
    )
  end
  from (select api.public_page_payload_v1(p_slug) as doc) base
$$;

-- The wrapper stays the only public surface. `public_page_payload` itself was
-- never granted to anon or authenticated, and the tests pin that (10_settings,
-- 11_bkash): it is an internal step `get_public_page` calls as its owner.
revoke all on function api.public_page_payload(text) from public, anon, authenticated;

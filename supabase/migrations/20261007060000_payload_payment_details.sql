-- ---------------------------------------------------------------------------
-- The paywall payload carries what paying needs.
--
-- Two gaps, both felt on the same screen. The customer picks a payment method
-- and must immediately see where to send the money - the account, the
-- instructions, and the proof fields this method asks for - but the public
-- projection published only id, kind, name and provider, so the page could not
-- show any of it until an order existed. And a hidden page could not know it
-- was hidden, so it could not behave as the standalone page it is.
--
-- The payment details were never secret: they describe where money goes, they
-- are shown on the order page to anyone who has one, and the column grants on
-- `payment_gateways_public` already treat them as public. Publishing them one
-- step earlier changes who sees them, from "anyone with an order" to "anyone
-- on the page", which is the same public.
--
-- `is_listed` is likewise not an access control (the slug works either way);
-- it is a display fact the page itself needs.
--
-- This deliberately retires the rule the suite used to pin - "the account is
-- revealed by the order, once, to the person who placed it". The checkout now
-- shows the destination on the page, before any order exists, because making
-- the customer open an order first was a screen the flow no longer has.
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

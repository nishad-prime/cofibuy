-- Public reads.
--
-- Two questions here. What can a visitor see before signing in, and — the one
-- that actually matters — can they find the minimum a link is hiding?

select plan(20);

select test_data.reset();

select test_data.as_anon();

-- A draft link the catalogue must not show, and a published one it must.
insert into public.paywall_links (slug, title_en, is_active)
values ('draft-one', 'Not Ready', false);

select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.gateway('nagad');

select test_data.link('hidden-price', 750, true);
select test_data.gateway('bank');

-- ---------------------------------------------------------------------------
-- The catalogue
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from api.list_public_links()),
  2,
  'the catalogue lists only published links'
);

select is(
  (select slug from api.list_public_links() where slug = 'draft-one'),
  null,
  'a draft link never reaches the catalogue'
);

-- A visitor is anonymous and must still see something, or the first screen of
-- the site is an error page.
select is((api.get_public_link('draft-one') ->> 'id'), null, 'an unpublished link is not readable by slug');
select is((api.get_public_link('guide') ->> 'slug'), 'guide', 'a published link is readable by slug');

select is(
  jsonb_typeof(api.get_public_link('guide') -> 'gateways'),
  'array',
  'gateways arrive as an array'
);

select is(
  (select count(*)::int from jsonb_array_elements(api.get_public_link('guide') -> 'gateways')),
  3,
  'every active gateway is offered'
);

-- Ordered by `sort_order`, so the choice among equal-priority gateways is
-- deterministic. The explicit values matter: falling back to `name_en` would
-- make this assertion depend on the database collation, which differs between
-- the embedded cluster and a real project.
update public.payment_gateways set sort_order = 2 where name_en = 'bKash';
update public.payment_gateways set sort_order = 1 where name_en = 'Nagad';
update public.payment_gateways set sort_order = 3 where name_en = 'Bank';

select is(
  (
    select string_agg(g ->> 'kind', ',' order by g ->> 'sort_order')
    from jsonb_array_elements(api.get_public_link('guide') -> 'gateways') g
  ),
  'nagad,bkash,bank',
  'gateways come back in sort_order'
);

select is(
  (api.get_public_link('guide') -> 'gateways' -> 0 ->> 'name_en'),
  'Nagad',
  'the lowest sort_order comes first'
);

-- ---------------------------------------------------------------------------
-- The minimum
--
-- `min_amount` is null exactly when the link hides it, and the point of the
-- exercise is that there is no other route to the number.
-- ---------------------------------------------------------------------------

select is((api.get_public_link('guide') ->> 'min_amount')::numeric, 500, 'a visible minimum is returned');
select is((api.get_public_link('guide') ->> 'min_hidden')::boolean, false, 'a visible minimum is flagged as visible');
select is((api.get_public_link('hidden-price') ->> 'min_amount'), null, 'a hidden minimum is null');
select is((api.get_public_link('hidden-price') ->> 'min_hidden')::boolean, true, 'a hidden minimum is flagged as hidden');

-- The whole text of the response, not just the one key. If the number survived
-- anywhere in the payload, this is where it would show.
select is(
  api.get_public_link('hidden-price')::text like '%750%',
  false,
  'the hidden amount appears nowhere in the response'
);

select is(
  (select count(*)::int from public.paywall_links_public),
  2,
  'the public view exposes only published links'
);

select is(
  exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'paywall_links_public'
      and column_name in ('min_amount_override', 'hide_min_override', 'unlock_body_md_en', 'unlock_body_md_bn')
  ),
  false,
  'the public view has no column carrying a minimum or the paid body'
);

-- ---------------------------------------------------------------------------
-- The paid body
--
-- The function returns a scalar `jsonb`, not a set. So an ungranted caller gets
-- JSON `null` with a 200 rather than a 404, and the client has to test the
-- value. Asserted here because it is the one place a `null` can be mistaken for
-- "the body happens to be empty" and the paywall silently renders nothing.
-- ---------------------------------------------------------------------------

select is(
  api.get_unlocked_link('guide'),
  null,
  'an anonymous visitor gets null'
);

select test_data.as_user(test_data.new_user());

select is(
  api.get_unlocked_link('guide'),
  null,
  'a signed-in customer without a grant gets null'
);

insert into public.access_grants (user_id, link_id)
values (auth.uid(), (select id from public.paywall_links where slug = 'guide'));

select is(
  (api.get_unlocked_link('guide') ->> 'unlock_body_md_en'),
  'The full guide.',
  'a granted customer reads the paid body'
);

select is(
  (api.get_unlocked_link('hidden-price') ->> 'unlock_body_md_en'),
  null,
  'a grant on one link does not unlock another'
);

-- A revoked grant is not a grant.
update public.access_grants set revoked_at = now() where link_id = (select id from public.paywall_links where slug = 'guide');

select is(
  api.get_unlocked_link('guide'),
  null,
  'a revoked grant stops working'
);

select test_data.as_anon();

select * from finish();

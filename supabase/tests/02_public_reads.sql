-- Public reads.
--
-- Two questions here. What can a visitor see before signing in, and — the one
-- that actually matters — can they find the minimum a link is hiding?

select plan(31);

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
--
-- UUIDs are masked out first. The payload carries `id` values for the link and
-- every gateway, and a hex uuid contains the digit run "750" roughly once in four
-- hundred, so matching the raw text failed about one run in fifty for reasons that
-- had nothing to do with the amount. A privacy assertion that fails at random
-- trains everyone to ignore it.
select is(
  regexp_replace(
    api.get_public_link('hidden-price')::text,
    '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
    'uuid',
    'g'
  ) like '%750%',
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

-- ---------------------------------------------------------------------------
-- Index visibility
--
-- `is_listed` is separate from `is_active`: a link can be published and still be
-- kept off the index, so a report can be sold by direct link without appearing in
-- the catalogue. Unlisted is not private - the slug still works.
--
-- The interesting case is the enumeration hole. Column-level grants let anon read
-- `public.paywall_links` directly, so if only the RPC filtered, this whole feature
-- would be bypassable with one REST call.
-- ---------------------------------------------------------------------------

-- `unlock_body_md_en` is required, not decorative: `paywall_links_publishable`
-- refuses to let a link go live without a body in at least one language.
insert into public.paywall_links (slug, title_en, unlock_body_md_en, is_active, is_listed)
values ('unlisted-report', 'Secret Report', 'The full report.', true, false);

select is(
  (select slug from api.list_public_links() where slug = 'unlisted-report'),
  null,
  'an unlisted link is absent from the catalogue'
);

select is(
  (api.get_public_link('unlisted-report') ->> 'slug'),
  'unlisted-report',
  'but it is still readable by its slug, because unlisted is not private'
);

select test_data.as_anon();

-- `slug` is a granted column, so this is not a permission error: the read is
-- allowed and RLS returns nothing. That is the enumeration hole - the row is
-- reachable, just filtered, and it would not be if only the RPC filtered.
select is(
  (test_data.as_role(
    'anon',
    'select count(*)::int as n from public.paywall_links where slug = ''unlisted-report'''
  ) #> '{rows,0,n}'),
  '0',
  'and a direct base-table read cannot see it either'
);

select is(
  (test_data.as_role(
    'anon',
    'select count(*)::int as n from public.paywall_links_public where slug = ''unlisted-report'''
  ) #> '{rows,0,n}'),
  '0',
  'nor through the public view'
);

select is(
  (test_data.as_role(
    'anon',
    'select count(*)::int as n from public.paywall_links where slug = ''guide'''
  ) #> '{rows,0,n}'),
  '1',
  'while a listed link is still directly readable'
);

select is(
  test_data.as_role('anon', 'select is_listed from public.paywall_links limit 1') ->> 'state',
  '42501',
  'the flag itself is not a readable column, so it cannot be used to probe'
);

select is(
  (select count(*)::int from api.list_public_links() where slug = 'guide'),
  1,
  'a listed link is in the catalogue'
);

-- An unlisted link is still buyable. That is the whole point of separating the
-- two flags, and it is what would break if someone later "tidied up" by adding
-- `is_listed` to the public view or to `create_order`.
select is(
  test_data.new_customer_orders('unlisted-report', 'bKash', 800) ->> 'ok',
  'true',
  'an unlisted link still takes orders'
);

-- Editing a link must not silently reset the flag. This is the `on conflict` half
-- of the upsert: an `is_listed` present in the insert list but missing from the
-- conflict set would revert on every subsequent edit.
select test_data.as_user(test_data.new_staff('owner'));

-- `admin_upsert_link` returns the composite `public.paywall_links`, so the flag
-- is read off the row rather than through `->>`.
select is(
  (api.admin_upsert_link(jsonb_build_object(
    'id', (select id from public.paywall_links where slug = 'unlisted-report'),
    'slug', 'unlisted-report',
    'title_en', 'Secret Report, Revised',
    'unlock_body_md_en', 'The full report.',
    'is_active', true,
    'is_listed', false,
    'sort_order', 5
  ))).is_listed::text,
  'false',
  'an edit that keeps the link unlisted leaves it unlisted'
);

select is(
  (api.admin_upsert_link(jsonb_build_object(
    'id', (select id from public.paywall_links where slug = 'unlisted-report'),
    'slug', 'unlisted-report',
    'title_en', 'Secret Report, Revised',
    'unlock_body_md_en', 'The full report.',
    'is_active', true,
    'is_listed', true,
    'sort_order', 5
  ))).is_listed::text,
  'true',
  'and re-listing it through the same call works'
);

select is(
  (select count(*)::int from api.list_public_links() where slug = 'unlisted-report'),
  1,
  'a re-listed link comes back to the catalogue'
);

select test_data.as_anon();

select * from finish();

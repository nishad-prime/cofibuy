-- Editable copy.
--
-- Covers the store itself, the three functions, and the owner/role gates. The
-- interesting assertions are the negative ones: an unknown key is refused, a
-- cleared language reverts rather than blanking, and a customer cannot read the
-- table even though they hold the anon key.

select plan(29);

select test_data.reset();

select test_data.as_anon();

-- ---------------------------------------------------------------------------
-- Reachability
--
-- Overrides are customer-visible, so the read is public - but through a function.
-- Granting SELECT on the table would make the table itself public, and that is a
-- different thing to hand out than one curated read.
-- ---------------------------------------------------------------------------

select is(
  test_data.as_role('anon', 'select * from public.copy_strings') ->> 'state',
  '42501',
  'a customer cannot read the copy table directly'
);

select is(
  test_data.as_role('authenticated', 'select * from public.copy_strings') ->> 'state',
  '42501',
  'nor can a signed-in customer'
);

select lives_ok(
  $$select * from api.get_public_copy()$$,
  'but everyone can read the curated public copy'
);

-- ---------------------------------------------------------------------------
-- The empty store is a valid state, not an error
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from api.get_public_copy()),
  0,
  'an unset site serves no overrides'
);

-- ---------------------------------------------------------------------------
-- Gates, before any write
--
-- Checked in the order the roles actually appear, so a failure names the role
-- that failed. Copy is owner-only because it changes what the shopfront says
-- about taking payment, which is above what a reviewer needs to see.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.admin_set_copy('[{"key":"home.heading","value_en":"Hi"}]'::jsonb)$$,
  '42501',
  'forbidden',
  'an anonymous visitor cannot write copy'
);

select test_data.as_user(test_data.new_user());
select throws_ok(
  $$select api.admin_set_copy('[{"key":"home.heading","value_en":"Hi"}]'::jsonb)$$,
  '42501',
  'forbidden',
  'a signed-in customer cannot write copy'
);

select throws_ok(
  $$select * from api.admin_copy()$$,
  '42501',
  'forbidden',
  'nor read the copy store'
);

select test_data.as_user(test_data.new_staff('staff'));
select throws_ok(
  $$select api.admin_set_copy('[{"key":"home.heading","value_en":"Hi"}]'::jsonb)$$,
  '42501',
  'forbidden',
  'staff cannot write copy'
);

select throws_ok(
  $$select * from api.admin_copy()$$,
  '42501',
  'forbidden',
  'nor read it'
);

select test_data.as_user(test_data.new_staff('owner'));

-- ---------------------------------------------------------------------------
-- Input validation
--
-- An unknown key would sit in the editor looking live while no component ever
-- read it, so it is refused rather than stored. The shape checks are deliberately
-- ahead of the registry lookup: a malformed key should not reach the table
-- constraint and surface as an opaque 23514.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.admin_set_copy('[{"key":"home.not_a_key","value_en":"Hi"}]'::jsonb)$$,
  '22023',
  'unknown copy key: home.not_a_key',
  'an unknown key is refused'
);

select throws_ok(
  $$select api.admin_set_copy('[{"key":"nope","value_en":"Hi"}]'::jsonb)$$,
  '22023',
  'unknown copy key: nope',
  'a key with no namespace is refused'
);

select throws_ok(
  $$select api.admin_set_copy('[{"key":"Home.Heading","value_en":"Hi"}]'::jsonb)$$,
  '22023',
  'unknown copy key: Home.Heading',
  'key matching is exact, including case'
);

select throws_ok(
  $$select api.admin_set_copy('{"key":"home.heading"}'::jsonb)$$,
  '22023',
  'expected a json array of { key, value_bn, value_en, is_markdown }',
  'an object rather than an array is refused'
);

select throws_ok(
  $$select api.admin_set_copy('[{"value_en":"Hi"}]'::jsonb)$$,
  '22023',
  'every item needs a key',
  'an item with no key is refused'
);

-- ---------------------------------------------------------------------------
-- Markdown on a label
--
-- `is_markdown` is the operator's to set, so the label rule has to hold in the
-- database rather than only in the editor: a label rendered as markdown is a
-- markup injection surface, and the editor's guard is one client away from being
-- bypassed by a direct call. Prose keys must still be allowed, otherwise the
-- check would be satisfied by refusing everything.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select api.admin_set_copy('[{"key":"home.heading","value_en":"# Hi","is_markdown":true}]'::jsonb)$$,
  '22023',
  'copy key home.heading is a label and cannot be markdown',
  'markdown is refused for a label key'
);

select lives_ok(
  $$select api.admin_set_copy('[{"key":"recovery.body","value_en":"Read this","is_markdown":true}]'::jsonb)$$,
  'markdown is allowed for a prose key'
);

select throws_ok(
  $$select api.admin_set_copy('[{"key":"home.heading","value_en":"# Hi","is_markdown":"yes"}]'::jsonb)$$,
  '22023',
  'copy key home.heading is a label and cannot be markdown',
  'a non-boolean truthy flag does not slip past the label rule'
);

delete from public.copy_strings where key = 'recovery.body';

-- ---------------------------------------------------------------------------
-- A real write
--
-- Bangla is written literally rather than as a \u escape: PostgreSQL does not
-- decode JSON string escapes inside a `jsonb` cast the way `json` would treat
-- them, so an escaped value would be stored as six literal characters.
-- ---------------------------------------------------------------------------

select is(
  api.admin_set_copy(
    '[{"key":"home.heading","value_bn":"কী পড়বে","value_en":"What to read"},
       {"key":"home.browse","value_en":"See reports","is_markdown":false}]'::jsonb
  ),
  2,
  'a batch write reports how many keys it touched'
);

select is(
  (select value_en from api.get_public_copy() where key = 'home.heading'),
  'What to read',
  'the override is served'
);

select is(
  (select value_bn from api.get_public_copy() where key = 'home.heading'),
  'কী পড়বে',
  'the Bangla override is served'
);

select is(
  (select value_bn from api.get_public_copy() where key = 'home.browse'),
  null,
  'a key set in one language only serves that language'
);

-- The public read hides unset languages rather than returning a blank, so the
-- app merge can test `is not null` and fall back.
select is(
  (select count(*)::int from api.get_public_copy() where value_en is not null),
  2,
  'only the languages actually set come back'
);

select is(
  (select is_markdown from api.admin_copy() where key = 'home.heading'),
  false,
  'markdown defaults off when not asked for'
);

-- ---------------------------------------------------------------------------
-- Bilingual fallback
--
-- The database refuses to publish a pair with both languages blank, and the merge
-- reads NULL as "no override". Clearing one language therefore falls back to the
-- bundle for that language only - the case an operator is most likely to hit by
-- editing one language and not the other.
-- ---------------------------------------------------------------------------

select api.admin_set_copy(
  '[{"key":"home.subheading","value_bn":"গারণা পওনারই","value_en":""}]'::jsonb
);

select is(
  (select value_en from api.get_public_copy() where key = 'home.subheading'),
  null,
  'clearing one language with nullif unsets it'
);

select is(
  (select value_bn from api.get_public_copy() where key = 'home.subheading'),
  'গারণা পওনারই',
  'and leaves the other language alone'
);

-- Both blank means "revert to the shipped wording". The row is deleted rather
-- than left as an all-null stub, so the editor and the public read agree about
-- whether the key is set.
select api.admin_set_copy('[{"key":"home.browse","value_bn":"","value_en":""}]'::jsonb);

select is(
  (select count(*)::int from public.copy_strings where key = 'home.browse'),
  0,
  'clearing both languages deletes the row'
);

select is(
  (select count(*)::int from api.get_public_copy() where key = 'home.browse'),
  0,
  'so it is no longer served as an override'
);

-- Whitespace only means unset, because private.tidy_blank_to_null runs on write.
-- Without that the merge would find a non-null value and render spaces instead of
-- the bundled text. Only spaces are exercised: btrim's default character set is
-- the space, so a tab would legitimately survive and asserting otherwise would
-- be testing the wrong thing.
select api.admin_set_copy('[{"key":"home.empty","value_bn":"   ","value_en":"  "}]'::jsonb);

select is(
  (select count(*)::int from public.copy_strings where key = 'home.empty'),
  0,
  'whitespace-only is normalised to unset'
);

select test_data.as_anon();
select lives_ok(
  $$select * from api.get_public_copy()$$,
  'the public read stays available to customers'
);

select * from finish();
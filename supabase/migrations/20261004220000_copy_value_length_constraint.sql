-- A ceiling on the copy store, at the layer every writer has to pass through.
--
-- `api.admin_set_copy` already refuses a value over 400 characters, and that is where
-- the operator-facing error comes from: it names the key, the language, the count and
-- the limit. This constraint exists because that check is reachable only through the
-- function, and the table is also writable by the service-role key and by migrations.
--
-- The reason it matters is `api.get_public_copy`, which is granted to `anon` and
-- returns every override to every visitor on every page load. A single unbounded value
-- is a bandwidth and rendering cost paid by the whole storefront, and unlike the
-- invisible-character rule this one degrades gracefully without the function: a
-- constraint violation names itself, and 400 is documented.
--
-- Deliberately *not* a constraint: the "renders as nothing" rule. That failure is one
-- unlabelled button, it is rare, and the operator cannot act on "copy_strings_value_
-- visible" nearly as well as on "copy key home.heading (en): contains no visible
-- characters". Message quality is most of that rule's value, so it stays in the
-- function where it can be specific.
--
-- NULL passes, which is what we want: NULL is "no override, use the bundle".
--
-- The 400 is repeated from `c_max` in 20261004200000_copy_value_limits.sql because a
-- CHECK cannot read a plpgsql variable. `src/config/copyKeys.test.ts` reads both and
-- fails if they ever disagree, so the repetition cannot become a second source of
-- truth.

alter table public.copy_strings
  add constraint copy_strings_value_length
  check (char_length(value_bn) <= 400 and char_length(value_en) <= 400);

comment on constraint copy_strings_value_length on public.copy_strings is
  'Ceiling on a stored copy value, matching c_max in api.admin_set_copy. The function gives the operator a specific error; this is the backstop for any writer that bypasses it.';
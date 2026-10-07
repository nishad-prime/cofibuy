-- ---------------------------------------------------------------------------
-- The copy override store is removed.
--
-- Pages now carry their own words (page fields and template config), the index
-- carries its own (settings), and what is left is chrome - "Loading", "Try
-- again", a status label - that ships in both locales and has no business in a
-- database. The store built to let an operator reword those strings is one more
-- table, three RPCs and a sync gate that every string change had to be explained
-- to, buying an override nobody had a reason left to write.
--
-- The bundled `customer.json` becomes the whole of what customers read: fixed
-- strings, reviewed like code, translated like code. Templates and the admin
-- chrome never had overrides.
--
-- No data survives because there is no data: the store was empty in every
-- environment this schema has been pushed to.
-- ---------------------------------------------------------------------------

drop function if exists api.get_public_copy();
drop function if exists api.admin_copy();
drop function if exists api.admin_set_copy(jsonb);

drop table if exists public.copy_strings;
drop table if exists private.copy_registry;

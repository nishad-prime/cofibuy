-- The copy keys for the two recovery field labels.
--
-- `private.copy_registry` is generated into `20261004130000_copy_registry.sql`, which
-- is applied to the hosted project, so the regenerated block above does not reach a
-- live database and these keys would be unknown to `api.admin_set_copy` there. Same
-- reason, and same remedy, as 20261004170000: repeat just the additions so an operator
-- can edit them. `on conflict do nothing` keeps it correct on a fresh database, which
-- has already inserted them from the regenerated block.
--
-- They exist because the storefront shipped two hardcoded English labels - "Phone
-- number" and "Verification code" - in the middle of a Bangla-first interface.
insert into private.copy_registry (key, markdown_allowed) values
  ('recovery.phone', false),
  ('recovery.code', false)
on conflict (key) do nothing;
-- The copy keys added with the maintenance notice and the recovery gate.
--
-- `private.copy_registry` is generated into `20261004130000_copy_registry.sql`, and
-- that migration had already been applied to the hosted project before these keys
-- existed. Editing an applied migration is a no-op, so the registry would never gain
-- them there and an operator could not override the maintenance wording.
--
-- This repeats just the four additions. `on conflict do nothing` keeps it correct on
-- a fresh database, which has already inserted them from the regenerated block above.
insert into private.copy_registry (key, markdown_allowed) values
  ('paywall.closedTitle', false),
  ('paywall.closedBody', false),
  ('paywall.closedContact', false),
  ('recovery.disabled', false)
on conflict (key) do nothing;

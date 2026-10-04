-- Remove editable-copy keys that no view ever rendered.
--
-- The registry's contract is "does the running app ever ask for this key". These
-- four never did, so the editor offered an operator a setting that changed nothing:
--
--   footer.builtWith, setup.title, setup.body, setup.see
--
-- `app.tagline` was in the same group but is now rendered in the customer footer,
-- so it stays. The keys are dropped from `src/config/copyKeys.ts` and the bundled
-- locale files in the same change; `npm run copy:keys:sync` regenerates the block in
-- 20261004130000 for a fresh local reset, and this migration removes the rows on a
-- database that already applied the old block (the same catch-up shape as
-- 20261004170000).

delete from private.copy_registry
where key in ('footer.builtWith', 'setup.title', 'setup.body', 'setup.see');

-- Any stored override goes with the key: keeping the row would leave a copy_strings
-- entry that can never be read, and it would resurface if the key were ever
-- re-registered.
delete from public.copy_strings
where key in ('footer.builtWith', 'setup.title', 'setup.body', 'setup.see');

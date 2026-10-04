-- Drop the old `private.copy_keys` and `private.copy_markdown_forbidden` functions that were replaced by the `private.copy_registry` table.

-- The functions are no longer needed: the registry table holds the same information as the two
-- generated arrays, and a table is the single source of truth rather than two lists that
-- could drift. The drop is part of the migration that adds the registry to prevent the old
-- functions from being used accidentally by any new code that reads `private`. --
drop function if exists private.copy_keys();
drop function if exists private.copy_markdown_forbidden();
-- Scheduled housekeeping.
--
-- pg_cron is present on Supabase but absent from a bare PostgreSQL, so nothing
-- here assumes it. If the extension is unavailable — a local test database, or
-- a host that does not permit it — the functions still exist and the notice
-- explains how to run them from an external scheduler. The local test suite
-- calls `private.sweep()` directly instead.
--
-- Every job calls an idempotent function, so a missed or duplicated run is
-- harmless. The schedule is discovered from `pg_extension` rather than assumed
-- to be `cron`, because the schema depends on how the extension was installed.

do $$
declare
  v_schema text;
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice
      'pg_cron is unavailable. The housekeeping functions are installed but unscheduled; run private.sweep() from your own scheduler.';
    return;
  end if;

  begin
    execute 'create extension if not exists pg_cron';
  exception
    when insufficient_privilege then
      raise notice
        'pg_cron is available but cannot be created by this role. Schedule private.sweep() from the Supabase dashboard.';
      return;
  end;

  select n.nspname
  into v_schema
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pg_cron';

  if v_schema is null then
    raise notice 'pg_cron is not installed; skipping schedules.';
    return;
  end if;

  -- Five minutes: frequent enough that a worker which died mid-claim is noticed
  -- quickly, cheap enough to run constantly.
  execute format(
    'select %I.schedule(%L, %L, %L)',
    v_schema,
    'cofibuy-sweep',
    '*/5 * * * *',
    'select private.sweep()'
  );

  -- Anonymous accounts are created freely and mostly abandoned. A week is long
  -- enough that a real customer is never swept mid-purchase.
  execute format(
    'select %I.schedule(%L, %L, %L)',
    v_schema,
    'cofibuy-prune-anonymous',
    '17 4 * * *',
    'select private.prune_anonymous_users()'
  );

  raise notice 'pg_cron schedules installed.';
end
$$;

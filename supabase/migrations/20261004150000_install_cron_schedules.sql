-- Install the housekeeping schedules on databases that applied a version of
-- `20260101000006_cron.sql` with the two `cron.schedule` calls stubbed out.
--
-- That edit was an accident and it was worse than inert: the surrounding block
-- still reached `raise notice 'pg_cron schedules installed.'`, so on any host
-- where pg_cron *is* available -- which is every Supabase project -- the notice
-- claimed success while nothing had been scheduled. `private.sweep()` and
-- `private.prune_anonymous_users()` therefore never ran, so a worker that died
-- mid-claim was never noticed and abandoned anonymous accounts accumulated.
--
-- `cron.schedule(name, ...)` updates an existing job of the same name, so this
-- is safe to replay and safe on a fresh database that already got the schedules
-- from the original migration.

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

  raise notice 'cofibuy housekeeping schedules installed.';
end
$$;
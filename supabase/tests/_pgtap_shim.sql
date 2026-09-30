-- pgTAP-compatible shim.
--
-- `supabase test db` needs the real pgtap extension, which needs a full
-- PostgreSQL install with contrib. Where that is not available — a CI runner
-- without the Supabase CLI's container, or a developer machine without Docker —
-- this shim provides the same assertion surface so the *same* test files run.
--
-- Applied only when pgtap is not installed. When it is, the real functions are
-- used and this file is skipped.
--
-- Semantics deliberately match pgTAP rather than aborting early: failures are
-- recorded, and `finish()` raises with the full list. A test file that fails
-- one assertion still reports the rest, so a single run tells you everything
-- that is broken.

create table if not exists _shim_results (
  seq serial primary key,
  ok boolean not null,
  kind text not null,
  name text,
  detail text
);

create or replace function _shim_record(p_ok boolean, p_kind text, p_name text, p_detail text)
returns text
language plpgsql
as $$
begin
  insert into _shim_results (ok, kind, name, detail)
  values (p_ok, p_kind, p_name, p_detail);

  if p_ok then
    return 'ok';
  end if;
  return p_kind || ' - ' || coalesce(p_detail, '') || coalesce(' (' || p_name || ')', '');
end
$$;

create or replace function _shim_run(p_sql text)
returns text
language plpgsql
as $$
declare
  v_state text;
begin
  begin
    execute p_sql;
    v_state := null;
  exception
    when others then
      v_state := sqlstate;
  end;
  return v_state;
end
$$;

create or replace function _shim_run_rows(p_sql text)
returns bigint
language plpgsql
as $$
declare
  v_count bigint;
begin
  execute 'select count(*) from (' || p_sql || ') _shim_sub' into v_count;
  return v_count;
exception
  when others then
    return -1;
end
$$;

create or replace function plan(p_tests integer)
returns text
language plpgsql
as $$
begin
  perform _shim_record(true, 'plan', 'plan ' || p_tests, null);
  return 'plan ' || p_tests;
end
$$;

create or replace function no_plan()
returns text
language sql
as $$
  select 'no_plan'
$$;

create or replace function ok(p_condition boolean, p_name text default null)
returns text
language sql
as $$
  select _shim_record(coalesce(p_condition, false), 'ok', p_name, 'expected true, got false')
$$;

create or replace function is(p_got anyelement, p_want anyelement, p_name text default null)
returns text
language sql
as $$
  select _shim_record(
    p_got is not distinct from p_want,
    'is',
    p_name,
    'got ' || coalesce(p_got::text, 'NULL') || ', want ' || coalesce(p_want::text, 'NULL')
  )
$$;

create or replace function isnt(p_got anyelement, p_want anyelement, p_name text default null)
returns text
language sql
as $$
  select _shim_record(
    p_got is distinct from p_want,
    'isnt',
    p_name,
    'both were ' || coalesce(p_got::text, 'NULL')
  )
$$;

create or replace function is_empty(p_sql text, p_name text default null)
returns text
language plpgsql
as $$
declare
  v_count bigint := _shim_run_rows(p_sql);
begin
  if v_count < 0 then
    return _shim_record(false, 'is_empty', p_name, 'query errored: ' || p_sql);
  end if;
  return _shim_record(v_count = 0, 'is_empty', p_name, 'expected 0 rows, got ' || v_count);
end
$$;

create or replace function throws_ok(
  p_sql text,
  p_errcode text default null,
  p_name text default null
)
returns text
language plpgsql
as $$
declare
  v_state text := _shim_run(p_sql);
begin
  if p_errcode is null then
    return _shim_record(
      v_state is null,
      'throws_ok',
      p_name,
      'expected an exception, got SQLSTATE ' || coalesce(v_state, '(none)')
    );
  end if;

  return _shim_record(
    v_state = p_errcode,
    'throws_ok',
    p_name,
    'expected SQLSTATE ' || p_errcode || ', got ' || coalesce(v_state, '(none)')
  );
end
$$;

create or replace function lives_ok(p_sql text, p_name text default null)
returns text
language plpgsql
as $$
declare
  v_state text := _shim_run(p_sql);
begin
  return _shim_record(
    v_state is null,
    'lives_ok',
    p_name,
    'expected success, got SQLSTATE ' || coalesce(v_state, '(none)')
  );
end
$$;

create or replace function diag(p_message text)
returns text
language sql
as $$
  select _shim_record(true, 'diag', p_message, null)
$$;

create or replace function note(p_message text)
returns text
language sql
as $$
  select _shim_record(true, 'note', p_message, null)
$$;

create or replace function finish()
returns text
language plpgsql
as $$
declare
  v_total integer;
  v_failed integer;
  v_report text;
begin
  select count(*) into v_total from _shim_results;
  select count(*) into v_failed from _shim_results where not ok;

  if v_failed > 0 then
    select string_agg(format('  %s: %s', r.kind, coalesce(r.detail, r.name)), E'\n' order by r.seq)
    into v_report
    from _shim_results r
    where not r.ok;

    raise exception 'shim: % of % assertions failed:%E%s', v_failed, v_total, E'\n', v_report
      using errcode = 'P0001';
  end if;

  return format('shim: % assertions passed', v_total);
end
$$;

-- Reset between test files. Called by the runner, not by test files.
create or replace function _shim_reset()
returns void
language sql
as $$
  delete from _shim_results
$$;

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

-- Both halves of what a call raised. pgTAP's throws_ok matches on the message as
-- well as the SQLSTATE, and a test that only pins the state would pass here and
-- fail under the real thing on a message it never checked.
create or replace function _shim_catch(p_sql text)
returns jsonb
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  begin
    execute p_sql;
  exception
    when others then
      v_state := sqlstate;
      v_message := sqlerrm;
  end;
  return jsonb_build_object('state', v_state, 'message', v_message);
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

-- The declared plan is held separately from the results, so `finish()` can
-- enforce the count the way pgTAP does. Without that, a file with one assertion
-- removed would still pass here and fail in CI.
create table if not exists _shim_plan (
  id boolean primary key default true,
  declared integer,
  check (id)
);

create or replace function plan(p_tests integer)
returns text
language plpgsql
as $$
begin
  insert into _shim_plan (declared) values (p_tests)
  on conflict (id) do update set declared = excluded.declared;
  return 'plan ' || p_tests;
end
$$;

create or replace function no_plan()
returns text
language plpgsql
as $$
begin
  insert into _shim_plan (declared) values (null)
  on conflict (id) do update set declared = null;
  return 'no_plan';
end
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

-- Concrete overloads for the types the suite compares, mirroring pgTAP.
--
-- Without these, `is(count(*), 1)` fails to resolve: `anyelement` forces both
-- arguments to one type, so a bigint can never be compared to an int literal.
-- The generic form stays as the fallback for everything else.
create or replace function is(p_got bigint, p_want bigint, p_name text default null)
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

create or replace function is(p_got integer, p_want integer, p_name text default null)
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

create or replace function is(p_got numeric, p_want numeric, p_name text default null)
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

create or replace function is(p_got text, p_want text, p_name text default null)
returns text
language sql
as $$
  select _shim_record(
    p_got is not distinct from p_want,
    'is',
    p_name,
    'got ' || coalesce(p_got, 'NULL') || ', want ' || coalesce(p_want, 'NULL')
  )
$$;

create or replace function is(p_got boolean, p_want boolean, p_name text default null)
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

create or replace function is(p_got uuid, p_want uuid, p_name text default null)
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

create or replace function isnt(p_got bigint, p_want bigint, p_name text default null)
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

create or replace function isnt(p_got integer, p_want integer, p_name text default null)
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

-- pgTAP's signatures: the message is checked, and the description is the last
-- argument. Getting this wrong is worse than not having it, because a test that
-- passes against the shim and fails under real pgTAP teaches you to distrust
-- the suite.
create or replace function throws_ok(
  p_sql text,
  p_errcode text,
  p_errmsg text,
  p_name text default null
)
returns text
language plpgsql
as $$
declare
  v_caught jsonb := _shim_catch(p_sql);
  v_state text := v_caught ->> 'state';
  v_message text := v_caught ->> 'message';
begin
  if v_state is distinct from p_errcode then
    return _shim_record(
      false,
      'throws_ok',
      p_name,
      format(
        'expected SQLSTATE %s, got %s',
        p_errcode,
        case
          when v_state is null then '(no exception)'
          else v_state || ' with message: ' || coalesce(v_message, '')
        end
      )
    );
  end if;

  if v_message is distinct from p_errmsg then
    return _shim_record(
      false,
      'throws_ok',
      p_name,
      format('expected message %L, got %L', p_errmsg, coalesce(v_message, '(none)'))
    );
  end if;

  return _shim_record(true, 'throws_ok', p_name, null);
end
$$;

create or replace function throws_ok(p_sql text, p_name text default null)
returns text
language plpgsql
as $$
declare
  v_state text := _shim_catch(p_sql) ->> 'state';
begin
  return _shim_record(
    v_state is not null,
    'throws_ok',
    p_name,
    'expected an exception, got SQLSTATE ' || coalesce(v_state, '(none)')
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

-- `diag` and `note` also raise a notice.
--
-- The shim records results in a table, and a table cannot be read once the
-- transaction has been aborted by a failing assertion — which is precisely when
-- the commentary is wanted. Notices are emitted as they happen, so the runner
-- keeps them whether the file passed or not.
create or replace function diag(p_message text)
returns text
language plpgsql
as $$
begin
  perform _shim_record(true, 'diag', p_message, null);
  raise notice '%', p_message;
  return 'diag';
end
$$;

create or replace function note(p_message text)
returns text
language plpgsql
as $$
begin
  perform _shim_record(true, 'note', p_message, null);
  raise notice '%', p_message;
  return 'note';
end
$$;

create or replace function finish()
returns text
language plpgsql
as $$
declare
  v_total integer;
  v_failed integer;
  v_declared integer;
  v_report text;
begin
  select count(*) into v_total from _shim_results;
  select count(*) into v_failed from _shim_results where not ok;
  select declared into v_declared from _shim_plan;

  if v_declared is not null and v_declared <> v_total then
    raise exception using
      errcode = 'P0001',
      message = format(
        'shim: plan declared %s assertions but %s ran; update the plan() call',
        v_declared,
        v_total
      );
  end if;

  if v_failed > 0 then
    -- The description, not just the mismatch. "expected SQLSTATE 22023, got
    -- 22P02" tells you something is wrong; which assertion was it tells you where
    -- to look, and a file with thirty of them needs the line.
    select E'\n' || string_agg(
      format(
        '  %s: %s%s',
        r.kind,
        coalesce(r.detail, r.name),
        case when r.name is null then '' else E'\n    ' || r.name end
      ),
      E'\n' order by r.seq
    )
    into v_report
    from _shim_results r
    where not r.ok;

    raise exception using
      errcode = 'P0001',
      message = format('shim: %s of %s assertions failed', v_failed, v_total),
      detail = v_report;
  end if;

  return format('shim: %s assertions passed', v_total);
end
$$;

-- Reset between test files. Called by the runner, not by test files.
create or replace function _shim_reset()
returns void
language sql
as $$
  delete from _shim_results;
  delete from _shim_plan
$$;

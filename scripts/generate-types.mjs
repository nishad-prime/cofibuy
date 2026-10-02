/**
 * Generates `src/lib/database.types.ts` from the migrations.
 *
 * `supabase gen types --local` is the canonical way to do this, and the app is
 * written against its output. It needs the Supabase CLI and a running project,
 * neither of which is available everywhere this repository is worked on, and a
 * hand-maintained copy of the schema is exactly the thing that drifts from the
 * migrations without anybody noticing.
 *
 * So this reads the catalog of a database built from the same migrations and
 * writes the same shape `supabase gen types` produces. Run it after a migration
 * and commit the result: CI checks that the two agree, so a forgotten
 * regeneration fails the build instead of shipping a type that no longer exists.
 *
 *   node scripts/generate-types.mjs          write the file
 *   node scripts/generate-types.mjs --check  fail if the file is out of date
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import * as prettier from 'prettier'
import { applyFile, listMigrations, root, startDatabase, stopDatabase } from './lib/local-db.mjs'

const TARGET = join(root, 'src', 'lib', 'database.types.ts')
const CHECK_ONLY = process.argv.includes('--check')

const HEADER = `/**
 * Generated database types.
 *
 * Regenerate with \`npm run db:types\` against a linked project, or
 * \`node scripts/generate-types.mjs\` against the local test database.
 * The hand-maintained shape below is only the container; the contents are
 * produced by the generator so the app and the migrations cannot drift.
 */
`

/**
 * Postgres type to TypeScript.
 *
 * Only the types this schema actually uses. An unknown type falls through to
 * `Json` rather than being silently typed as `any`, so a new column type shows
 * up as a type error the author has to look at instead of a value that is
 * quietly unchecked at runtime.
 */
function tsType(column) {
  switch (column.data_type) {
    case 'boolean':
      return 'boolean'
    case 'smallint':
    case 'integer':
    case 'bigint':
      return 'number'
    case 'numeric':
    case 'real':
    case 'double precision':
    case 'money':
      return 'number'
    case 'uuid':
    case 'text':
    case 'character varying':
    case 'character':
    case 'citext':
    case 'date':
    case 'time without time zone':
    case 'time with time zone':
    case 'timestamp without time zone':
    case 'timestamp with time zone':
    case 'interval':
    case 'inet':
    case 'cidr':
    case 'macaddr':
    case 'jsonpath':
      return 'string'
    case 'json':
    case 'jsonb':
      return 'Json'
    case 'ARRAY':
      // Routed through udtToTs, not a separate element-type helper: `udt_name`
      // for an array column is the underscore-prefixed element name (`_uuid`),
      // which udtToTs already unwraps recursively. information_schema exposes no
      // `element_type` column, so a helper reading one silently fell through to
      // 'number' for every array.
      return udtToTs(column.udt_name)
    case 'USER-DEFINED':
      return column.enumValues ? enumUnion(column.enumValues) : 'Json'
    default:
      return 'Json'
  }
}

/** The element type of an array column, which the catalog reports separately. */

function enumUnion(values) {
  return values.map((value) => JSON.stringify(value)).join(' | ')
}

async function readTables(client) {
  const { rows: columns } = await client.query(`
    select
      c.table_schema as schema,
      c.table_name as table,
      c.column_name as name,
      c.ordinal_position as position,
      c.is_nullable = 'YES' as nullable,
      c.column_default is not null as has_default,
      c.is_generated <> 'NEVER' as generated,
      c.data_type,
      c.udt_name,
      c.character_maximum_length,
      c.numeric_precision,
      c.numeric_scale,
      (select t.typtype from pg_type t where t.typname = c.udt_name) as type_kind,
      e.enumlabel,
      (select array_agg(l2.enumlabel::text order by l2.enumsortorder)
         from pg_type t2
         join pg_enum l2 on l2.enumtypid = t2.oid
        where t2.typname = c.udt_name)::text[] as enum_values
    from information_schema.columns c
    left join pg_type pt on pt.typname = c.udt_name
    left join pg_class pc on pc.relname = c.table_name
    left join pg_namespace pn on pn.oid = pc.relnamespace and pn.nspname = c.table_schema
    left join pg_enum e on e.enumtypid = pt.oid and e.enumsortorder = c.ordinal_position
    where c.table_schema in ('public', 'api')
      and c.table_name not in ('_shim_results', '_shim_plan')
      and (select relkind from pg_class where oid = pc.oid) = 'r'
    order by c.table_schema, c.table_name, c.ordinal_position
  `)

  // `left join pg_enum` multiplies rows when the column is an enum; keep the
  // first of each and drop the column-name joins that were only there to reach
  // the enum labels.
  const byTable = new Map()
  for (const column of columns) {
    const key = `${column.schema}.${column.table}`
    if (!byTable.has(key)) byTable.set(key, [])
    const list = byTable.get(key)
    if (list.some((existing) => existing.name === column.name)) continue
    list.push({ ...column, enumValues: dedupe(column.enum_values) })
  }

  // Returned as arrays and unfolded in JS: the catalog keys are int2vectors, and
  // unnesting them in SQL to decide `isOneToOne` needs more machinery than the
  // answer is worth.
  const { rows: constraints } = await client.query(`
    select
      ns.nspname as schema,
      cls.relname as table,
      con.conname as name,
      con.conkey,
      con.confkey,
      fref_ns.nspname as referenced_schema,
      fref_cls.relname as referenced_table,
      (select array_agg(att.attname::text order by x.ord)
         from unnest(con.conkey) with ordinality as x(attnum, ord)
         join pg_attribute att on att.attrelid = con.conrelid and att.attnum = x.attnum)::text[] as columns,
      (select array_agg(att.attname::text order by x.ord)
         from unnest(con.confkey) with ordinality as x(attnum, ord)
         join pg_attribute att on att.attrelid = con.confrelid and att.attnum = x.attnum)::text[] as referenced_columns
    from pg_constraint con
    join pg_class cls on cls.oid = con.conrelid
    join pg_namespace ns on ns.oid = cls.relnamespace
    join pg_class fref_cls on fref_cls.oid = con.confrelid
    join pg_namespace fref_ns on fref_ns.oid = fref_cls.relnamespace
    where con.contype = 'f'
      and ns.nspname in ('public', 'api')
    order by ns.nspname, cls.relname, con.conname
  `)

  const uniqueColumns = await readUniqueColumns(client)

  const relationships = []
  for (const constraint of constraints) {
    constraint.columns.forEach((column, i) => {
      relationships.push({
        table: constraint.table,
        name: constraint.name,
        column,
        referencedTable: constraint.referenced_table,
        referencedColumn: constraint.referenced_columns[i],
        isOneToOne: isOneToOne(constraint, uniqueColumns),
      })
    })
  }

  return { columns: byTable, relationships }
}

/**
 * A single-column foreign key is one-to-one only when the columns it points at
 * are themselves unique. `supabase gen types` reports it, so the relationship
 * reads the same as it would from the CLI.
 */
function isOneToOne(constraint, uniqueColumns) {
  if (constraint.columns.length !== 1) return false
  return uniqueColumns.has(
    `${constraint.referenced_table}:${constraint.referenced_columns.join(',')}`,
  )
}

/** Column sets that some unique constraint, index, or primary key covers. */
async function readUniqueColumns(client) {
  const { rows } = await client.query(`
    select
      ns.nspname as schema,
      cls.relname as table,
      (
        select array_agg(att.attname::text order by x.ord)
          from unnest(idx.indkey) with ordinality as x(attnum, ord)
          join pg_attribute att on att.attrelid = cls.oid and att.attnum = x.attnum
        where x.attnum > 0
      )::text[] as columns
    from pg_index idx
    join pg_class cls on cls.oid = idx.indrelid
    join pg_namespace ns on ns.oid = cls.relnamespace
    where idx.indisunique
      and ns.nspname in ('public', 'api')
    order by ns.nspname, cls.relname
  `)

  const unique = new Set()
  for (const row of rows) {
    if (row.columns) unique.add(`${row.table}:${row.columns.join(',')}`)
  }
  return unique
}

function dedupe(values) {
  if (!values) return null
  return [...new Set(values)]
}

async function readViews(client) {
  const { rows } = await client.query(`
    select
      c.table_schema as schema,
      c.table_name as table,
      c.column_name as name,
      c.ordinal_position as position,
      c.is_nullable = 'YES' as nullable,
      c.column_default is not null as has_default,
      c.is_generated <> 'NEVER' as generated,
      c.data_type,
      c.udt_name
    from information_schema.columns c
    join pg_class cls on cls.relname = c.table_name
    join pg_namespace ns on ns.oid = cls.relnamespace and ns.nspname = c.table_schema
    where c.table_schema = 'public'
      and cls.relkind = 'v'
    order by c.table_schema, c.table_name, c.ordinal_position
  `)

  const byView = new Map()
  for (const column of rows) {
    const key = `${column.schema}.${column.table}`
    if (!byView.has(key)) byView.set(key, [])
    byView.get(key).push(column)
  }
  return byView
}

async function readFunctions(client) {
  // Straight from pg_proc. `information_schema.parameters` looks tidier, but it
  // appends the function OID to `specific_name` and offers no way to join back,
  // so every argument would need the same suffix to line up.
  //
  // Arguments are unrolled in a subquery and folded into one JSON array, because
  // the catalog spreads them across `proargnames`, `proargtypes` (or
  // `proallargtypes` when a mode is given) and `proargmodes`, and unrolling
  // outside would need the same unnest repeated. `proargtypes` is an oidvector and
  // `proallargtypes` a true array, so a single unnest cannot take whichever is
  // set. The `pronargs = 0` branch is not just an optimisation: the empty
  // oidvector every zero-argument function carries is not a valid array literal,
  // so casting it would raise before the subquery is ever reached.
  const { rows } = await client.query(`
    select
      ns.nspname as schema,
      p.proname as name,
      p.proretset as returns_set,
      p.pronargs,
      p.pronargdefaults,
      case when p.pronargs = 0 then '[]'::json else (
        select json_agg(
                 json_build_object('mode', u.mode, 'name', u.nm, 'type', t.typname)
                 order by u.ord
               )
          from unnest(
                 coalesce(p.proallargtypes, p.proargtypes::oid[]),
                 p.proargnames,
                 array_fill('i'::"char", array[p.pronargs])
               ) with ordinality as u(oid, nm, mode, ord)
          join pg_type t on t.oid = u.oid
      ) end as args,
      rt.typname as return_udt,
      rt.typtype as return_kind,
      (rt.typcategory = 'A') as return_is_array,
      (select array_agg(l2.enumlabel::text order by l2.enumsortorder)
         from pg_enum l2 where l2.enumtypid = rt.oid)::text[] as return_enum
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    join pg_type rt on rt.oid = p.prorettype
    where ns.nspname in ('api', 'private', 'public')
      and p.prokind = 'f'
    order by ns.nspname, p.proname
  `)

  const byFunction = new Map()
  for (const row of rows) {
    const args = []
    // Defaults are a suffix of the argument list, so an argument has one exactly
    // when its position is past `pronargs - pronargdefaults`.
    for (const [i, arg] of (row.args ?? []).entries()) {
      // OUT, INOUT-via-table and TABLE parameters are results, not inputs the
      // caller supplies, so they are not part of the argument object.
      if (arg.mode === 'o' || arg.mode === 'b' || arg.mode === 't') continue
      args.push({
        // proargnames is null when no argument is named; PostgREST still needs a
        // positional name, so fall back to the p_ convention the SQL uses.
        name: arg.name ?? `p_arg${i + 1}`,
        type: udtToTs(arg.type),
        hasDefault: i + 1 > row.pronargs - row.pronargdefaults,
      })
    }

    byFunction.set(`${row.schema}.${row.name}`, {
      schema: row.schema,
      name: row.name,
      args,
      returnsSet: row.returns_set,
      returnUdt: row.return_udt,
      returnKind: row.return_kind,
      returnIsArray: row.return_is_array,
      returnEnum: dedupe(row.return_enum),
    })
  }

  return byFunction
}

async function readEnums(client) {
  const { rows } = await client.query(`
    select
      t.typname as name,
      array_agg(e.enumlabel::text order by e.enumsortorder)::text[] as values
    from pg_type t
    join pg_enum e on e.enumtypid = t.oid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname in ('public', 'api')
    group by t.typname
    order by t.typname
  `)
  return rows
}

/**
 * Maps a catalog type name to TypeScript.
 *
 * An unknown type becomes `Json` rather than `any`, so a column the generator
 * does not recognise surfaces as a type error the author has to look at, instead
 * of a value that is quietly unchecked at runtime.
 */
function udtToTs(udtName, oid) {
  // `_int4` and friends: the leading underscore marks an array in the catalog.
  if (udtName?.startsWith('_')) return `${udtToTs(udtName.slice(1), undefined)}[]`
  if (oid === 3802) return 'Json' // jsonb

  switch (udtName) {
    case 'bool':
      return 'boolean'
    case 'int2':
    case 'int4':
    case 'int8':
    case 'float4':
    case 'float8':
    case 'numeric':
      return 'number'
    case 'text':
    case 'varchar':
    case 'bpchar':
    case 'uuid':
    case 'timestamptz':
    case 'timestamp':
    case 'date':
    case 'time':
    case 'timetz':
    case 'interval':
    case 'inet':
    case 'cidr':
      return 'string'
    case 'json':
    case 'jsonb':
      return 'Json'
    default:
      return 'Json'
  }
}

function renderTable(name, columns, relationships) {
  const key = name.split('.')[1]
  const related = relationships.filter((r) => r.table === key)

  // A row read back from the database can always be null in a nullable column,
  // so `Row` is where the `| null` belongs. Insert and Update only mark the
  // column optional, because omitting it is how you avoid the null.
  const row = renderMembers(
    columns,
    (c) => c.name,
    (c) => rowType(c),
  )
  // Required means the column must be supplied: not nullable, no default to fall
  // back on, not generated. Everything else is optional on insert.
  const required = columns.filter((c) => !c.nullable && !c.has_default && !c.generated)
  const optional = columns.filter((c) => c.nullable || c.has_default || c.generated)
  const insert = [
    ...required.map((c) => `  ${c.name}: ${rowType(c)}`),
    ...optional.map((c) => `  ${c.name}?: ${rowType(c)}`),
  ]
  const update = columns.map((c) => `  ${c.name}?: ${rowType(c)}`)

  return `  ${key}: {
    Row: {
${row}
    }
    Insert: {
${insert.join('\n')}
    }
    Update: {
${update.join('\n')}
    }
    Relationships: ${renderRelationships(related)}
  }`
}

function rowType(column) {
  const type = tsType(column)
  return column.nullable ? `${type} | null` : type
}

function renderMembers(columns, keyOf, valueOf) {
  return columns.map((c) => `  ${keyOf(c)}: ${valueOf(c)}`).join('\n')
}

function renderRelationships(related) {
  if (related.length === 0) return '[]'
  const entries = related.map(
    (r) =>
      `    { foreignKeyName: ${JSON.stringify(r.name)}, columns: [${JSON.stringify(
        r.column,
      )}], isOneToOne: ${r.isOneToOne}, referencedRelation: ${JSON.stringify(
        r.referencedTable,
      )}, referencedColumns: [${JSON.stringify(r.referencedColumn)}] },`,
  )
  return `[\n${entries.join('\n')}\n  ]`
}

function renderView(name, columns) {
  const key = name.split('.')[1]
  return `  ${key}: {
    Row: {
${renderMembers(
  columns,
  (c) => c.name,
  (c) => rowType(c),
)}
    }
    Relationships: []
  }`
}

function renderFunction(fn) {
  const returns = functionReturn(fn)

  if (fn.args.length === 0) {
    return `  ${fn.name}: { Args: Record<PropertyKey, never>, Returns: ${returns} }`
  }

  const args = fn.args.map((a) => `    ${a.name}${a.hasDefault ? '?' : ''}: ${a.type}`).join('\n')
  return `  ${fn.name}: {
    Args: {
${args}
    }
    Returns: ${returns}
  }`
}

function functionReturn(fn) {
  const scalar =
    fn.returnKind === 'e' && fn.returnEnum ? enumUnion(fn.returnEnum) : udtToTs(fn.returnUdt)
  const wrapped = fn.returnIsArray ? `${scalar}[]` : scalar
  return fn.returnsSet ? `${wrapped}[]` : wrapped
}

function renderSection(label, entries) {
  if (entries.length === 0) return `  ${label}: Record<never, never>`
  return `  ${label}: {\n${entries.join('\n')}\n  }`
}

async function generate() {
  const { pg, client } = await startDatabase()
  try {
    for (const file of listMigrations()) await applyFile(client, file)

    const { columns, relationships } = await readTables(client)
    const views = await readViews(client)
    const functions = await readFunctions(client)
    const enums = await readEnums(client)

    const schemas = new Set([
      ...[...columns.keys()].map((k) => k.split('.')[0]),
      ...[...views.keys()].map((k) => k.split('.')[0]),
      ...[...functions.keys()].map((k) => k.split('.')[0]),
    ])
    schemas.add('public')

    const sections = []
    for (const schema of [...schemas].sort()) {
      const tableNames = [...columns.keys()].filter((k) => k.split('.')[0] === schema).sort()
      const viewNames = [...views.keys()].filter((k) => k.split('.')[0] === schema).sort()
      const functionNames = [...functions.keys()].filter((k) => k.split('.')[0] === schema).sort()

      const tableEntries = tableNames.map((name) =>
        renderTable(name, columns.get(name), relationships),
      )
      const viewEntries = viewNames.map((name) => renderView(name, views.get(name)))
      const functionEntries = functionNames.map((name) => renderFunction(functions.get(name)))
      const enumEntries = enums
        .filter(() => schema === 'public')
        .map((e) => `  ${e.name}: ${enumUnion(e.values)}`)

      sections.push(
        `  ${schema}: {\n${[
          renderSection('Tables', tableEntries),
          renderSection('Views', viewEntries),
          renderSection('Functions', functionEntries),
          enumEntries.length > 0
            ? `  Enums: {\n${enumEntries.join('\n')}\n  }`
            : '  Enums: Record<never, never>',
        ].join('\n')}\n  }`,
      )
    }

    return `${HEADER}
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
${sections.join('\n')}
}

type DefaultSchema = Database[Extract<keyof Database, 'public'>]

export type Tables<
  PublicTableNameOrOptions extends
    | keyof (Database['public']['Tables'] & Database['public']['Views'])
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof (Database[PublicTableNameOrOptions['schema']]['Tables'] &
        Database[PublicTableNameOrOptions['schema']]['Views'])
    : never = never,
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? (Database[PublicTableNameOrOptions['schema']]['Tables'] &
      Database[PublicTableNameOrOptions['schema']]['Views'])[TableName] & {
      Row: Record<string, unknown>
      Insert: Record<string, unknown>
      Update: Record<string, unknown>
    }
  : (PublicTableNameOrOptions extends keyof (DefaultSchema['Tables'] & DefaultSchema['Views'])
      ? (DefaultSchema['Tables'] & DefaultSchema['Views'])[PublicTableNameOrOptions] & {
          Row: Record<string, unknown>
          Insert: Record<string, unknown>
          Update: Record<string, unknown>
        }
      : never)

export type TablesInsert<
  PublicTableName extends keyof DefaultSchema['Tables'],
> = (DefaultSchema['Tables'][PublicTableName] & { Insert: unknown })['Insert']

export type TablesUpdate<
  PublicTableName extends keyof DefaultSchema['Tables'],
> = (DefaultSchema['Tables'][PublicTableName] & { Update: unknown })['Update']

export type Enums<PublicEnumName extends keyof DefaultSchema['Enums']> =
  DefaultSchema['Enums'][PublicEnumName]
`
  } finally {
    await stopDatabase({ pg, client })
  }
}

// Run through the repository's own Prettier config, so the committed file and a
// fresh `--check` agree: the comparison below is byte-for-byte, and an
// unformatted write would otherwise fail its own check every time.
const generated = await prettier.format(await generate(), {
  ...(await prettier.resolveConfig(TARGET)),
  parser: 'typescript',
})

if (CHECK_ONLY) {
  const current = readFileSync(TARGET, 'utf8')
  if (current !== generated) {
    console.error('database.types.ts is out of date. Run: node scripts/generate-types.mjs')
    process.exit(1)
  }
  console.log('database.types.ts is up to date')
} else {
  writeFileSync(TARGET, generated)
  console.log(`wrote ${TARGET.replace(`${root}/`, '')}`)
}

import { startDatabase, stopDatabase, listMigrations, applyFile } from './lib/local-db.mjs'

const { client, pg } = await startDatabase()
const applied = []
for (const file of listMigrations()) {
  const n = await applyFile(client, file)
  applied.push({ file: file.split('/').pop(), statements: n })
}
console.table(applied)

const { rows } = await client.query(`
  select ns.nspname, p.proname
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'private' and p.proname like 'copy%'
  order by p.proname
`)
console.log('private copy* functions:', rows)

const { rows: tbl } = await client.query(`
  select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'private' and c.relkind = 'r'
`)
console.log(
  'private tables:',
  tbl.map((r) => r.relname),
)

await stopDatabase({ pg, client })

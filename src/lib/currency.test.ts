import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { CURRENCIES } from './currency'

/**
 * The list exists twice: as `CURRENCIES` here and as a check constraint in the
 * currency migration. The migration is authoritative for writes and this file is
 * authoritative for the select, so a code added to one and not the other would be
 * either unofferable or rejected. Read the SQL and compare, the same way
 */
const here = dirname(fileURLToPath(import.meta.url))
const migration = join(
  here,
  '..',
  '..',
  'supabase',
  'migrations',
  '20261004180000_currency_branding.sql',
)

describe('currency allowlist', () => {
  it('matches the migration check constraint, in order', () => {
    const sql = readFileSync(migration, 'utf8')
    const begin = sql.indexOf('-- currency-allowlist:begin')
    const end = sql.indexOf('-- currency-allowlist:end')

    expect(begin).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(begin)

    const codes = [...sql.slice(begin, end).matchAll(/'([A-Z]{3})'/g)].map((m) => m[1])
    expect(codes).toEqual([...CURRENCIES])
  })
})

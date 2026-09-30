/**
 * Generated database types.
 *
 * Regenerate with `npm run db:types` against a linked project, or
 * `node scripts/generate-types.mjs` against the local test database.
 * The hand-maintained shape below is only the container; the contents are
 * produced by the generator so the app and the migrations cannot drift.
 */

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

type GenericSchema = {
  Tables: Record<string, never>
  Views: Record<string, never>
  Functions: Record<string, never>
  Enums: Record<string, never>
  CompositeTypes: Record<string, never>
}

export type Database = {
  public: GenericSchema
  api: GenericSchema
  private: GenericSchema
}

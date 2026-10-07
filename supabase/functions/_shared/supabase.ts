/**
 * The two Supabase clients every function needs, in one place.
 *
 * This file exists because of a bug it makes unrepeatable. `createClient` defaults to the
 * `public` schema, and every RPC in this project lives in `api`. A client built without
 * `db.schema` therefore resolves `admin_links` as `public.admin_links`, which does not exist,
 * and PostgREST answers `PGRST202: Could not find the function public.admin_links` - an error
 * that reads like a missing migration and is not one.
 *
 * Nothing local catches it. `npm run test:db` exercises the functions as SQL, `functions:test`
 * injects a client, and `typecheck` never builds a Deno bundle, so all three stay green while
 * every RPC in the deployed function is wrong. It surfaced only on a deployed function, as a
 * 403 whose detail named the wrong schema.
 *
 * The frontend already carries the same trap, in `src/lib/supabase.ts`, where the setting sits
 * behind a comment explaining why it is there. Two copies of one required option is one too
 * many, so this is the second and last.
 */

import { createClient, type SupabaseClientOptions } from '@supabase/supabase-js'

/**
 * The client's `db.schema` is 'api' for the same reason `Accept-Profile: api` is sent by hand
 * when probing PostgREST with curl: the schema is a property of this project, and a default that
 * silently points somewhere else turns every RPC into a 404-shaped error.
 */
const CLIENT_OPTIONS: SupabaseClientOptions<'api'> = {
  auth: { persistSession: false },
  db: { schema: 'api' },
}

/**
 * Builds a client for one key. Deliberately unannotated: this is where `createClient` infers the
 * `api` schema from CLIENT_OPTIONS, and `ApiClient` below is read back off it. Annotating this
 * function is what would force a hand-written `any` back into the file.
 */
function buildClient(key: string, accessToken?: string) {
  return createClient(Deno.env.get('SUPABASE_URL') ?? '', key, {
    ...CLIENT_OPTIONS,
    ...(accessToken ? { global: { headers: { Authorization: `Bearer ${accessToken}` } } } : {}),
  })
}

/**
 * A client pinned to `api`.
 *
 * Derived from the factory rather than written out, because writing it means either an explicit
 * `any` for the untyped `Database` generic - which this repo's lint forbids - or a bare
 * `SupabaseClient`, which defaults to `public` and so reintroduces by type annotation the exact
 * mistake the schema option exists to prevent. A signature saying `ApiClient` cannot mean public.
 */
export type ApiClient = ReturnType<typeof buildClient>

/**
 * A client acting as the caller, carrying their JWT.
 *
 * The caller's token goes in the `Authorization` header, where PostgREST reads the
 * role from; the client's own key is the project's anon key, because the platform
 * refuses a user JWT in the `apikey` slot with `Invalid API key`. Passing the token
 * as the key used to work when every key was a long-lived JWT, and the failure it
 * causes now is total: every owner check and every customer RPC in a deployed
 * function is refused before the database is reached.
 *
 * Used only for authorization calls that must run as that user - `admin_pages` for
 * the fill's owner check, `pay_online_start` for the customer's own order - so a
 * staff member gets `42501` from the database rather than a decision this code
 * makes about them. Never used to read a secret.
 */
export function userClientFor(accessToken: string): ApiClient {
  return buildClient(Deno.env.get('SUPABASE_ANON_KEY') ?? '', accessToken)
}

/**
 * A client acting as the service role, from the environment and never from a header.
 *
 * This is the only client that may reach `secret_bundle_open`. If the service-role key were
 * accepted from the caller, the function would be a way to read a shop's merchant password with
 * a key the caller supplied, so the key comes from the platform and the caller's token never
 * reaches this object.
 */
export function serviceClient(): ApiClient {
  return buildClient(Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '')
}

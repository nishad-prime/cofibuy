/**
 * GET /functions/v1/geo-country
 *
 * The customer's country, as the edge knows it. Cloudflare serves the Supabase
 * edge, so `request.cf.country` is the two-letter code of the caller's IP -
 * no third-party geo service, no stored state, nothing to configure.
 *
 * Returns `{ country: "BD" }` or `{ country: null }` when the header is
 * absent (local dev, unknown ranges). The payment modal treats null as "no
 * match", which routes the customer through the International catch-all.
 *
 * Nothing here is personalized or secret, so verification is off and CORS
 * allows the storefront origins the modal runs on.
 */

import { corsHeaders, jsonResponse } from '../_shared/http.ts'

Deno.serve((request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders() })
  }

  // `cf` is a Cloudflare extension on the request object; Deno's types do not
  // know it, and the header is the same value spelled differently.
  const cf = (request as unknown as { cf?: { country?: string } }).cf
  const headerCountry = request.headers.get('cf-ipcountry')
  const rawCountry = cf?.country ?? headerCountry
  const country =
    typeof rawCountry === 'string' && /^[A-Z]{2}$/.test(rawCountry) ? rawCountry : null

  return jsonResponse({ country })
})

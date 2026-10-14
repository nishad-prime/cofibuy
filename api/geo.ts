/**
 * The geo endpoint on Vercel: the visitor's country as the edge knows it,
 * answered from the request itself.
 *
 * The payment flow's fallback chain is URL param → `window.__COFIBUY_GEO__`
 * (stamped by the hosting edge) → this endpoint → Supabase. Vercel's edge
 * middleware cannot rewrite HTML bodies the way the Cloudflare Worker did,
 * so on this host the chain relies on this endpoint instead of the injected
 * global — same result, one small fetch on first visit.
 *
 * Edge runtime: `request.geo` only exists there, and it is what Supabase
 * edge functions cannot see.
 */
export const config = { runtime: 'edge' }

export default function handler(request: Request): Response {
  const geo = (request as Request & { geo?: { country?: string } }).geo
  const country = typeof geo?.country === 'string' && geo.country ? geo.country : null
  return new Response(JSON.stringify({ country }), {
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
    },
  })
}

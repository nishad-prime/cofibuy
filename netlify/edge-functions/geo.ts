/**
 * The storefront's geo edge function — the Netlify translation of the
 * Cloudflare Worker this site used before.
 *
 * Two jobs:
 *
 *   1. `/api/geo` answers from the request itself: the visitor's country as
 *      Netlify's edge knows it (`context.geo.country.code`, ISO-3166 alpha-2,
 *      or null). The SPA reads this to decide which gateway banner is primary;
 *      Supabase edge functions cannot see this value, so it must come from the
 *      hosting edge.
 *
 *   2. Every HTML response gets one line stamped into its head:
 *      `window.__COFIBUY_GEO__`. The client chain is URL param → injected
 *      global → `/api/geo` → Supabase fallback, so a cached document or a
 *      missed fetch degrades gracefully.
 *
 * Non-HTML responses (JS, CSS, images) pass through untouched.
 */

interface NetlifyGeo {
  country?: { code?: string }
}

interface EdgeContext {
  next: (input?: Request | string, init?: RequestInit) => Promise<Response>
  geo: NetlifyGeo
}

const readCountry = (context: EdgeContext): string | null => {
  const code = context.geo?.country?.code
  return typeof code === 'string' && code.length > 0 ? code : null
}

export default async (request: Request, context: EdgeContext): Promise<Response> => {
  const url = new URL(request.url)

  if (url.pathname === '/api/geo') {
    return new Response(JSON.stringify({ country: readCountry(context) }), {
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    })
  }

  const response = await context.next()

  const contentType = response.headers.get('content-type') ?? ''
  if (!contentType.includes('text/html')) {
    return response
  }

  const html = await response.text()
  const stamp = `<script>window.__COFIBUY_GEO__=${JSON.stringify(readCountry(context))};</script>`

  // The app shell always has a head; a miss means the body is not the shell
  // (a proxied asset responding as HTML, say), so pass it through unmodified.
  if (!html.includes('</head>')) {
    return response
  }

  return new Response(html.replace('</head>', `${stamp}</head>`), {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  })
}

/// <reference types="@cloudflare/workers-types" />

/**
 * The storefront Worker. Serves the built SPA and injects one line into every
 * HTML response: the visitor's country, as Cloudflare's edge knows it
 * (`request.cf.country`, ISO-3166 alpha-2, or null).
 *
 * The payment flow reads `window.__COFIBUY_GEO__` to decide which gateway
 * banner is primary for the visitor. Supabase edge functions cannot see this
 * value — their runtime is not behind the Cloudflare geo context — so the
 * country must be stamped at this layer, the only place that has it.
 *
 * Injection is via HTMLRewriter on `text/html` responses only; assets
 * (JS/CSS/images) pass through untouched.
 */

export interface Env {
  ASSETS: Fetcher
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url)

    // Same-origin geo endpoint. The SPA reads this instead of trusting the
    // injected HTML value alone: it survives a cached document, works on any
    // route, and cannot be stale - it answers from the request itself.
    if (url.pathname === '/api/geo') {
      const cf = (request as unknown as { cf?: { country?: string } }).cf
      const country = typeof cf?.country === 'string' ? cf.country : null
      return new Response(JSON.stringify({ country }), {
        headers: {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
      })
    }

    const response = await env.ASSETS.fetch(request)

    const contentType = response.headers.get('content-type') ?? ''
    if (!contentType.includes('text/html')) {
      return response
    }

    const cf = (request as unknown as { cf?: { country?: string } }).cf
    const country = typeof cf?.country === 'string' ? cf.country : null

    return new HTMLRewriter()
      .on('head', {
        element(element) {
          element.append(`<script>window.__COFIBUY_GEO__=${JSON.stringify(country)};</script>`, {
            html: true,
          })
        },
      })
      .transform(response)
  },
} satisfies ExportedHandler<Env>

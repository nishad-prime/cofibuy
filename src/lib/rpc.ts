/**
 * The typed way to call an `api` RPC.
 *
 * The api schema's functions return `jsonb`, which the generator types as
 * `Json` — technically correct and practically useless, since every call site
 * ended up casting through `as any` and the compiler stopped being able to
 * check anything at all. This module is where the payload shapes live instead:
 * each interface describes what one RPC actually returns, and the `rpc` helper
 * hands that shape back, so a misspelled field is a compile error rather than a
 * blank screen.
 *
 * The shapes are hand-written on purpose. They describe the *live* definition of
 * each function — the one the latest migration left in place — and the database
 * suite pins that definition, so drift fails `npm run test:db` loudly.
 */
import { getSupabase } from '@/lib/supabase'

/** What a call returns: the payload, or the error PostgREST reported. */
export interface RpcResult<T> {
  data: T | null
  error: { message: string; transport?: true } | null
}

/**
 * Network-level failures (the request never completed) come back through the
 * same shape with `transport: true`, so callers can show a friendly "check
 * your connection" message instead of the browser's "Failed to fetch".
 */
export const isTransportFailure = (err: unknown): boolean =>
  err instanceof TypeError ||
  (err instanceof Error && /failed to fetch|networkerror|load failed/i.test(err.message))

/** Calls an `api` RPC and types the payload. */
export async function rpc<T>(name: string, args?: Record<string, unknown>): Promise<RpcResult<T>> {
  try {
    // `as never` buys the generic name; the generated signature would otherwise
    // demand its own literal union here and defeat the point of this module.
    return (await getSupabase().rpc(name as never, args as never)) as RpcResult<T>
  } catch (err) {
    if (isTransportFailure(err)) {
      console.warn(`[rpc] transport failure calling ${name}:`, err)
      return { data: null, error: { message: String(err), transport: true } }
    }
    throw err
  }
}

/** Calls an `api` RPC that returns a set, typed as the row shape. */
export async function rpcList<T>(
  name: string,
  args?: Record<string, unknown>,
): Promise<RpcResult<T[]>> {
  return rpc<T[]>(name, args)
}

// ---------------------------------------------------------------------------
// Payload shapes
// ---------------------------------------------------------------------------

/**
 * One gateway as the public payload publishes it: everything a customer needs
 * to pay, because the page renders the destination and the proof form the
 * moment the method is selected.
 */
export interface PublicGateway {
  id: string
  kind: string
  name_bn: string | null
  name_en: string | null
  provider: string | null
  sort_order: number
  account_number: string | null
  account_name: string | null
  instructions_md_en: string | null
  instructions_md_bn: string | null
  evidence_fields: unknown[]
  /** NULL = International catch-all; otherwise an ISO-3166 alpha-2 code. */
  country: string | null
  is_primary_for_country: boolean
  /** Big banner (3:1) and normal banner (1.5:1); either may be unassigned. */
  banner_url: string | null
  banner_small_url: string | null
}

/** One page as the index lists it. */
export interface PublicPage {
  id: string
  slug: string
  title_bn: string | null
  title_en: string | null
  teaser_md_bn: string | null
  teaser_md_en: string | null
  unlock_cta_label_bn: string | null
  unlock_cta_label_en: string | null
  template: string
  template_config: Record<string, unknown>
  sort_order: number
}

/**
 * Whether the page appears in the public index. A hidden page is still sold by
 * its URL - this is a display fact the page needs so it can drop the way back.
 */
export interface PageVisibility {
  is_listed: boolean
}

/** One page with its payment methods, as the paywall reads it. */
export interface PublicPageDetail extends PublicPage, PageVisibility {
  min_amount: number | null
  min_hidden: boolean
  gateways: PublicGateway[]
}

/** One row of the customer's own order list. */
export interface MyOrder {
  id: string
  slug: string
  title_en: string | null
  title_bn: string | null
  gateway_kind: string
  status: string
  reference_code: string
  amount: number | null
  min_amount: number | null
  min_hidden: boolean
  created_at: string
  expires_at: string
  submitted_at: string | null
  attempt_count: number
  reject_reason_en: string | null
  reject_reason_bn: string | null
}

/**
 * One row of `my_order_status`: the order, its gateway's public face and the
 * evidence schema, in whatever combination the status allows.
 */
export interface MyOrderStatus {
  id: string
  slug: string
  status: string
  amount: number | null
  min_amount: number | null
  min_hidden: boolean
  reference_code: string
  gateway_kind: string
  gateway_provider: string | null
  gateway_name_en: string | null
  gateway_name_bn: string | null
  instructions_md_en: string | null
  instructions_md_bn: string | null
  evidence_fields: unknown[]
  reject_reason_en: string | null
  reject_reason_bn: string | null
  expires_at: string
  [key: string]: unknown
}

/** The answer envelope the order-creating RPCs share. */
export interface OrderResult {
  ok: boolean
  code?: string
  order_id?: string
  reference_code?: string
  locked_at?: string
  /** `pay_online_start` reports the payment session's sandbox flag. */
  sandbox?: boolean
  environment?: string
  gateway_id?: string
  amount?: number | null
  currency?: string
}

import { computed, ref, watch, type Ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import { formatMoney } from '@/lib/money'
import { useContent } from '@/composables/useContent'
import type { LocalizedPair } from '@/lib/content'
import { describeEdgeFailure, invokeWithRetry } from '@/lib/edgeError'
import { isTransportFailure, rpc, rpcList } from '@/lib/rpc'
import type { MyOrder, MyOrderStatus, OrderResult } from '@/lib/rpc'
import { useFileUpload } from '@/composables/useFileUpload'
import { buildVisitContext, resolveCity } from '@/composables/visitContext'
import { buildEvidencePayload } from '@/lib/evidencePayload'
import { useOrderPolling } from '@/composables/useOrderPolling'
import { useSiteSettings } from '@/composables/useSiteSettings'
import type { AccountField } from '@/components/customer/GatewayAccountDetails.vue'
import type { EvidenceField } from '@/components/customer/EvidenceForm.vue'

/**
 * The gateway as the public payload publishes it, plus the payment details a
 * customer needs before any order exists.
 */
export interface CheckoutGateway {
  id: string
  kind: string
  name_bn: string | null
  name_en: string | null
  provider: string | null
  sort_order: number | null
  account_number: string | null
  account_name: string | null
  account_fields: AccountField[] | null
  instructions_md_en: string | null
  instructions_md_bn: string | null
  evidence_fields: EvidenceField[]
  /** NULL = International catch-all; otherwise an ISO-3166 alpha-2 code. */
  country: string | null
  is_primary_for_country: boolean
  banner_url: string | null
  banner_small_url: string | null
}

/** The slice of the page the checkout reads. */
export interface CheckoutPage {
  slug: string
  title_bn: string | null
  title_en: string | null
  unlock_cta_label_bn: string | null
  unlock_cta_label_en: string | null
  unlock_cta_url: string | null
  min_amount: number | null
  min_hidden: boolean
  amount_presets: number[] | null
  /** When set, the customer cannot choose: this exact figure is charged. */
  fixed_amount: number | null
  gateways: CheckoutGateway[]
}

/**
 * One banner card on the gateway step: a kind, its best placement, its art.
 * Module scope because the modal renders it and the composable builds it.
 */
export interface GatewayBanner {
  kind: string
  name: string
  provider: string | null
  /** Null when no banner image was uploaded: the card renders as text. */
  bannerUrl: string | null
  size: 'big' | 'normal' | 'foreign'
}

/**
 * The whole checkout, in one composable.
 *
 * Every state an order can be in is actionable on the page itself: pay it,
 * attach proof to it, read what it bought. The template renderer places the
 * checkout section; this composable owns everything inside it - gateway
 * selection, amount, order creation, bKash hand-off, evidence submission,
 * status adoption and polling, unlocked content, and the persistence that
 * keeps all of it across refreshes.
 */
export function usePageCheckout(
  page: Ref<CheckoutPage | null>,
  slug: Ref<string>,
): ReturnType<typeof buildCheckout> {
  return buildCheckout(page, slug)
}

function buildCheckout(page: Ref<CheckoutPage | null>, slug: Ref<string>) {
  const route = useRoute()
  const supabase = getSupabase()
  const { pick } = useContent()
  const { t } = useI18n()

  /**
   * A caught error becomes the panel's message. Network failures - a dropped
   * packet between the customer and Supabase - get a friendly line in both
   * languages instead of the browser's raw "Failed to fetch".
   */
  const describeCaught = (err: unknown, fallback: string): string => {
    if (isTransportFailure(err) || (err instanceof Error && err.name === 'UploadTransportError')) {
      console.warn('[checkout] transport failure:', err)
      return t('customer.errors.network')
    }
    return err instanceof Error ? err.message : fallback
  }
  const { settings } = useSiteSettings()

  // Decides what is rendered. `create_order()` refuses independently, so if
  // this is stale or the settings fetch failed, the worst case is a form that
  // fails on submit rather than an order that slips through.
  const maintenance = computed(() => settings.value.maintenance_mode)
  const supportContact = computed(() => settings.value.contact)

  const gateways = computed<CheckoutGateway[]>(() => page.value?.gateways ?? [])
  const selectedKind = ref<string | null>(null)
  const amount = ref<number>(0)
  const creating = ref(false)
  const error = ref<string | null>(null)

  const existingOrder = ref<MyOrder | null>(null)
  const orderDetails = ref<MyOrderStatus | null>(null)
  const unlockedBody = ref<string | null>(null)
  const telegramInvite = ref<{ url: string; chatType: string; revoked: boolean } | null>(null)
  const paying = ref(false)
  const submittingEvidence = ref(false)
  const fileUpload = useFileUpload()

  let polling: ReturnType<typeof useOrderPolling> | null = null

  /** The open order's gateway, matched against this page's published methods. */
  const orderGateway = computed(() =>
    existingOrder.value
      ? gateways.value.find((g) => g.kind === existingOrder.value!.gateway_kind)
      : undefined,
  )

  /** An order pays online when its kind has an automatic account behind it. */
  const orderPaysOnline = computed(() => orderGateway.value?.provider != null)

  /**
   * The gateway behind the method the customer just picked. A kind can have
   * several accounts behind it; the shop picks one at order time, but the
   * account details are per-kind display copy, so showing the first active
   * account of the kind is what the customer needs before the order exists.
   */
  const selectedGateway = computed(() => gateways.value.find((g) => g.kind === selectedKind.value))
  const pickedGatewayName = computed(() =>
    selectedGateway.value
      ? pick({ bn: selectedGateway.value.name_bn, en: selectedGateway.value.name_en })
      : '',
  )
  const selectedAccountFields = computed(
    () => (selectedGateway.value?.account_fields ?? []) as unknown as AccountField[],
  )
  const selectedInstructions = computed(() =>
    selectedGateway.value
      ? pick({
          bn: selectedGateway.value.instructions_md_bn,
          en: selectedGateway.value.instructions_md_en,
        })
      : null,
  )

  /**
   * `my_order_status` nests the gateway - and with it everything about where
   * the money goes - one level down, under `gateway`. Reading those fields off
   * the top level is the bug that rendered an empty account card on the panel.
   */
  const statusGateway = computed(
    () => (orderDetails.value as { gateway?: Record<string, unknown> } | null)?.gateway ?? null,
  )

  const orderAccountLegacy = computed(() => {
    const g = statusGateway.value
    return {
      number: typeof g?.account_number === 'string' ? g.account_number : null,
      name: typeof g?.account_name === 'string' ? g.account_name : null,
    }
  })

  const orderAccountFields = computed(
    () => (statusGateway.value?.account_fields ?? []) as unknown as AccountField[],
  )

  const orderEvidenceFields = computed(
    () => (statusGateway.value?.evidence_fields ?? []) as unknown as EvidenceField[],
  )

  const pageTitle = computed(() =>
    page.value ? pick({ bn: page.value.title_bn, en: page.value.title_en }) : '',
  )
  const pageCta = computed(() =>
    page.value
      ? pick({ bn: page.value.unlock_cta_label_bn, en: page.value.unlock_cta_label_en })
      : '',
  )

  const ctaUrl = computed(() => page.value?.unlock_cta_url || '')

  const effectiveMin = computed(() => page.value?.min_amount ?? 0)

  const hideMin = computed(() => page.value?.min_hidden === true)

  /**
   * The operator's price chips, ready to tap: whole numbers only, deduped and
   * sorted, and anything below the page's effective minimum is dropped - a
   * chip the customer cannot legally tap is worse than no chip. No presets,
   * or all of them filtered, and the plain input is all there is.
   */
  const amountPresets = computed(() => {
    const raw = (page.value?.amount_presets ?? []) as unknown as number[]
    const floor = hideMin.value ? 0 : effectiveMin.value
    return [...new Set(raw.map(Number).filter((n) => Number.isFinite(n) && n >= floor))].sort(
      (a, b) => a - b,
    )
  })

  /**
   * A fixed-amount page names the price: no chips, no typing, and the send
   * step hides the selector entirely.
   */
  const fixedAmount = computed<number | null>(() => {
    const value = (page.value as { fixed_amount?: number | null } | null)?.fixed_amount
    return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null
  })

  const selectPreset = (preset: number): void => {
    amount.value = preset
  }

  /**
   * The send step must never open on an empty amount: a fixed price, else
   * the first preset, else the effective minimum, is what the customer
   * starts from. A figure they already chose survives, because overwriting
   * it would silently change what they read in the summary.
   */
  const applyDefaultAmount = (): void => {
    if (fixedAmount.value !== null) {
      amount.value = fixedAmount.value
      return
    }
    if (amount.value > 0) return
    const first = amountPresets.value[0]
    if (first !== undefined) {
      amount.value = first
      return
    }
    if (effectiveMin.value > 0) {
      amount.value = effectiveMin.value
    }
  }

  const isAmountValid = computed(() => {
    if (fixedAmount.value !== null) return amount.value === fixedAmount.value
    if (effectiveMin.value > 0) return amount.value >= effectiveMin.value
    return amount.value >= 0
  })

  const amountHint = computed(() => {
    if (hideMin.value || effectiveMin.value <= 0) return t('customer.paywall.amountAny')
    return t('customer.paywall.amountMin', { amount: money(effectiveMin.value) })
  })

  const amountError = computed(() => {
    if (isAmountValid.value || amount.value === 0) return ''
    return t('customer.paywall.amountError', { amount: money(effectiveMin.value) })
  })

  /**
   * The customer types this figure into bKash, so it stays Latin in both
   * locales — the R1 exception documented in `src/lib/money.ts`.
   *
   * One rendering for the whole page: the number the customer reads, the
   * number in the hint and the number in the error have to agree with the
   * number they transcribe, or the order is refused.
   */
  const money = (amt: number): string => formatMoney(amt, 'en', settings.value.currency)

  /** The order's deadline, in the customer's own clock format. */
  const formatExpiry = (iso: string): string =>
    new Date(iso).toLocaleString(undefined, {
      dateStyle: 'medium',
      timeStyle: 'short',
    })

  /**
   * `create_order` refuses in the payload rather than as an error, so the
   * reason has to be surfaced instead of navigating to a nonexistent order.
   */
  const describeRefusal = (code?: string): string => {
    switch (code) {
      case 'below_minimum':
        return effectiveMin.value > 0
          ? t('customer.paywall.amountError', { amount: money(effectiveMin.value) })
          : t('customer.paywall.refused')
      case 'locked':
        return t('customer.paywall.refusedLocked')
      default:
        return t('customer.paywall.refused')
    }
  }

  const fetchUnlocked = async (): Promise<void> => {
    const { data } = await rpc<Record<string, unknown>>('get_unlocked_page', {
      p_slug: slug.value,
    })
    if (data) {
      unlockedBody.value = pick({
        bn: data.unlock_body_md_bn,
        en: data.unlock_body_md_en,
      } as unknown as LocalizedPair)
    }
    await fetchTelegramInvite()
  }

  // -- Telegram invite delivery ---------------------------------------------
  //
  // When the page targets a Telegram chat, the approved order's invite link
  // replaces the static CTA in the modal's status phase. The invite is
  // created by the bot (bkash-execute fires it instantly; the cron catches
  // manual approvals within a minute), so the client polls briefly.

  let invitePolling: ReturnType<typeof setInterval> | null = null
  let inviteAttempts = 0

  const stopInvitePolling = (): void => {
    if (invitePolling) {
      clearInterval(invitePolling)
      invitePolling = null
    }
  }

  const fetchTelegramInvite = async (): Promise<void> => {
    const order = existingOrder.value
    if (!order || order.status !== 'approved' || telegramInvite.value) return

    const { data } = await rpc<{ url: string; chat_type: string; revoked: boolean } | null>(
      'get_telegram_invite',
      { p_order_id: order.id },
    )
    if (data?.url) {
      telegramInvite.value = { url: data.url, chatType: data.chat_type, revoked: data.revoked }
      stopInvitePolling()
    }
  }

  const startInvitePolling = (): void => {
    if (invitePolling) return
    inviteAttempts = 0
    void fetchTelegramInvite()
    invitePolling = setInterval(async () => {
      inviteAttempts += 1
      await fetchTelegramInvite()
      if (telegramInvite.value || inviteAttempts >= 24) stopInvitePolling()
    }, 5000)
  }

  /**
   * Pays the existing order in place: the one-step RPC reuses it (the kind
   * matches by construction - this order belongs to this page) and the
   * customer leaves for bKash from here.
   */
  const payExisting = async (): Promise<void> => {
    const order = existingOrder.value
    if (!order || paying.value) return

    paying.value = true
    error.value = null
    try {
      const { data, error: fnError } = await invokeWithRetry(() =>
        supabase.functions.invoke('bkash-create-payment', {
          body: {
            slug: slug.value,
            kind: order.gateway_kind,
            amount: Number(order.amount),
            origin: window.location.origin,
          },
        }),
      )

      if (fnError) {
        const failure = await describeEdgeFailure(fnError, 'The payment could not start.')
        if (failure.cause !== '') console.warn('[bkash-create-payment]', failure)
        error.value = failure.message
        return
      }

      const payload = data as { ok?: boolean; redirectUrl?: string } | null
      if (payload?.ok === true && payload.redirectUrl) {
        window.location.assign(payload.redirectUrl)
        return
      }
      error.value = t('customer.paywall.refused')
    } finally {
      paying.value = false
    }
  }

  /** Evidence for the open manual order, uploaded and submitted on this page. */
  const submitEvidence = async (evidence: Record<string, unknown>): Promise<void> => {
    if (!existingOrder.value) return

    submittingEvidence.value = true
    error.value = null
    try {
      const payload = await buildEvidencePayload(
        evidence,
        fileUpload.upload,
        existingOrder.value.id,
      )

      const { error: submitError } = await supabase.rpc('submit_evidence', {
        p_order_id: existingOrder.value.id,
        ...payload,
      })

      if (submitError) {
        error.value = submitError.message
        return
      }

      if (polling) await polling.refresh()
    } catch (err) {
      error.value = describeCaught(err, 'Failed to submit evidence')
    } finally {
      submittingEvidence.value = false
    }
  }

  /**
   * Takes ownership of one order on this page: shows its state inline and
   * keeps watching it until it lands somewhere terminal. Used both by the
   * mount-time lookup and by the manual submission, which creates the order
   * right here.
   */
  const adoptOrder = async (orderId: string): Promise<void> => {
    const { data: status } = await rpc<MyOrderStatus>('my_order_status', {
      p_order_id: orderId,
    })
    if (status) orderDetails.value = status

    // An approved order has nothing left to act on: what it bought takes the
    // panel's place.
    if (status?.status === 'approved') {
      await fetchUnlocked()
    }

    const { data: orders } = await rpcList<MyOrder>('my_orders')
    const mine = (orders ?? []).find((o) => o.id === orderId)
    if (mine) existingOrder.value = mine

    // An open order moves on its own - the operator reviews it, the cron
    // expires it - so the page keeps watching it until it lands somewhere
    // terminal.
    polling = useOrderPolling(orderId)
    void polling.refresh()
    polling.startPolling()

    watch(polling.status, async (next) => {
      if (next === 'approved') {
        polling?.stopPolling()
        await fetchUnlocked()
      } else if (next === 'expired') {
        // Nothing is in the way any more: the pay form comes back.
        polling?.stopPolling()
        existingOrder.value = null
        orderDetails.value = null
      } else if (next) {
        orderDetails.value = { ...(orderDetails.value ?? {}), status: next } as MyOrderStatus
      }
    })
  }

  const loadExistingOrder = async (): Promise<void> => {
    // A session is not guaranteed: the customer may be reading before their
    // first order. Nothing here may block the page's own render.
    try {
      const { data: sessionData } = await supabase.auth.getSession()
      if (!sessionData.session) return

      const { data: orders } = await rpcList<MyOrder>('my_orders')

      // `under_review` is deliberately missing from the SQL's open set (a
      // review does not block a second order), but it is exactly the state a
      // customer's order sits in across a refresh after submitting proof -
      // skip it and the payment form reappears over their heads. Approved
      // wins over everything (they already own it); an open order beats one
      // under review, because the open one is the thing they can still act on.
      const priority: Record<string, number> = {
        approved: 0,
        draft: 1,
        awaiting_proof: 1,
        rejected: 1,
        locked: 1,
        under_review: 2,
      }

      const mine = (orders ?? [])
        .filter((o) => o.slug === slug.value && o.status in priority)
        .sort((a, b) => (priority[a.status] ?? 9) - (priority[b.status] ?? 9))[0]
      if (!mine) return

      // Approved needs no status details - the content is the whole panel -
      // so it skips the status fetch entirely.
      if (mine.status === 'approved') {
        existingOrder.value = mine
        await fetchUnlocked()
        return
      }

      await adoptOrder(mine.id)
    } catch (err) {
      console.warn('[order-state]', err)
    }
  }

  /** Preselect the kind when there is exactly one choice. */
  const preselectKind = (): void => {
    const kinds = [...new Set(gateways.value.map((g) => g.kind))]
    const onlyKind = kinds.length === 1 ? kinds[0] : undefined
    if (onlyKind) {
      selectedKind.value = onlyKind
    }
  }

  /**
   * A `kind_mismatch` raise means an open order for this page is already in
   * the way. The page never navigates to it: the order panel takes the form's
   * place right here, because the page is the whole checkout and a redirect
   * to the deep-link route is exactly the multi-page flow this view exists to
   * retire.
   */
  const handOffToOpenOrder = async (): Promise<void> => {
    const { data, error: ordersError } = await supabase.rpc('my_orders')

    if (ordersError || !Array.isArray(data)) {
      error.value = t('customer.paywall.openOrderExists')
      return
    }

    const openStatuses = new Set(['draft', 'awaiting_proof', 'rejected', 'locked'])
    const existing = (data as Array<{ id: string; slug: string; status: string }>).find(
      (order) => order.slug === slug.value && openStatuses.has(order.status),
    )

    if (!existing) {
      // The order expired in the gap. Nothing is in the way any more, so the
      // customer can simply try again - but they must be told to, or they read
      // a dead end as a refusal.
      error.value = t('customer.paywall.openOrderExpired')
      return
    }

    await adoptOrder(existing.id)
  }

  /**
   * Whether the chosen kind pays online.
   *
   * The shop decides which account of a kind takes the money, so the client
   * asks "is any account of this kind automatic?" rather than picking one
   * itself. A manual kind answers false and takes the evidence path instead.
   */
  const kindPaysOnline = computed(() =>
    gateways.value.some((g) => g.kind === selectedKind.value && g.provider !== null),
  )

  // -- Customer country and the banner layout that follows from it ----------

  const customerCountry = ref<string | null>(null)
  let countryRequested = false

  /**
   * The customer's country. Sources, in order:
   *
   * 1. `?country=XX` on the URL - lets an operator verify banner layouts
   *    without a VPN.
   * 2. `window.__COFIBUY_GEO__` - stamped into the HTML by the storefront
   *    Worker, which is the only layer that sees Cloudflare's geo context
   *    for the visitor.
   * 3. The `geo-country` edge function - answers null on Supabase's runtime,
   *    which simply does not have the value; kept as a portability fallback.
   *
   * One call per checkout instance; a failure leaves null and the banner
   * layout falls through to the International catch-all.
   */
  const loadCustomerCountry = async (): Promise<void> => {
    if (countryRequested) return
    countryRequested = true

    const fromParam = new URLSearchParams(window.location.search).get('country')
    if (fromParam && /^[A-Za-z]{2}$/.test(fromParam)) {
      customerCountry.value = fromParam.toUpperCase()
      return
    }

    // Same-origin endpoint served by the storefront Worker - the
    // authoritative source. It answers from the visitor's own request with
    // no-store, so it cannot be stale the way an HTML document can.
    try {
      const response = await fetch('/api/geo', { cache: 'no-store' })
      if (response.ok) {
        const data = (await response.json()) as { country?: unknown }
        if (typeof data.country === 'string' && /^[A-Z]{2}$/.test(data.country)) {
          customerCountry.value = data.country
          console.debug('[geo] country from /api/geo:', data.country)
          return
        }
      }
    } catch {
      // Same-origin endpoint missing (plain static host) - fall through.
    }

    // Belt: the value the Worker also injects into the HTML at serve time.
    const injected = (window as unknown as { __COFIBUY_GEO__?: unknown }).__COFIBUY_GEO__
    if (typeof injected === 'string' && /^[A-Z]{2}$/.test(injected)) {
      customerCountry.value = injected
      console.debug('[geo] country from worker injection:', injected)
      return
    }

    try {
      const { getSupabase } = await import('@/lib/supabase')
      const { data, error } = await getSupabase().functions.invoke('geo-country', { body: {} })
      const country = (data as { country?: unknown } | null)?.country
      if (!error && typeof country === 'string' && /^[A-Z]{2}$/.test(country)) {
        customerCountry.value = country
      }
    } catch {
      // Geo is an enhancement; the international rules are the correct
      // fallback, not an error state.
    }
  }

  const gatewayBanners = computed<GatewayBanner[]>(() => {
    const country = customerCountry.value
    // The customer's own gateways, or - when nothing matches - the
    // International catch-all group takes the primary and preferred roles.
    const matched = country !== null ? gateways.value.filter((g) => g.country === country) : []
    const home = matched.length > 0 ? matched : gateways.value.filter((g) => g.country === null)
    const primaryIds = new Set(home.filter((g) => g.is_primary_for_country).map((g) => g.id))
    const homeIds = new Set(home.map((g) => g.id))
    const rank = (g: CheckoutGateway): number =>
      primaryIds.has(g.id) ? 0 : homeIds.has(g.id) ? 1 : 2

    // One banner per kind, since orders route by kind: the representative is
    // the kind's best-placed gateway - primary, then home, then foreign, then
    // the operator's sort order.
    const byKind = new Map<string, CheckoutGateway[]>()
    for (const gateway of gateways.value) {
      const list = byKind.get(gateway.kind) ?? []
      list.push(gateway)
      byKind.set(gateway.kind, list)
    }

    const entries: GatewayBanner[] = []
    for (const [kind, list] of byKind) {
      const sorted = [...list].sort(
        (a, b) => rank(a) - rank(b) || (a.sort_order ?? 0) - (b.sort_order ?? 0),
      )
      const rep = sorted[0]
      if (!rep) continue
      const placement = rank(rep)
      const size: GatewayBanner['size'] =
        placement === 0 ? 'big' : placement === 1 ? 'normal' : 'foreign'
      // Each size prefers its own art and degrades to the other rather than
      // an empty card.
      const bannerUrl =
        size === 'big'
          ? (rep.banner_url ?? rep.banner_small_url)
          : (rep.banner_small_url ?? rep.banner_url)
      entries.push({
        kind,
        name: pick({ bn: rep.name_bn, en: rep.name_en }) || kind,
        provider: rep.provider,
        bannerUrl,
        size,
      })
    }

    const order = { big: 0, normal: 1, foreign: 2 } as const
    return entries.sort((a, b) => order[a.size] - order[b.size])
  })

  /**
   * Orders belong to a user, so an anonymous sign-in is the floor of every
   * submission path. Checking the stored session is cheaper and safer than
   * calling getUser(), which also rejects for an expired session and would
   * silently orphan the old user.
   */
  const ensureSession = async (): Promise<boolean> => {
    const { data: sessionData } = await supabase.auth.getSession()
    if (sessionData.session) return true

    const { error: anonError } = await supabase.auth.signInAnonymously()
    if (anonError) {
      // This one is an operator problem, not a customer problem: the project
      // has anonymous sign-ins switched off, so nobody can order at all.
      error.value = anonError.message.includes('Anonymous sign-ins are disabled')
        ? 'Checkout is not available yet: anonymous sign-ins are disabled for this store.'
        : anonError.message
      return false
    }
    return true
  }

  const createOrder = async (): Promise<void> => {
    if (!page.value || !selectedKind.value || !isAmountValid.value) {
      return
    }

    creating.value = true
    error.value = null
    try {
      if (!(await ensureSession())) return

      // The online kinds skip the order page entirely: the function creates
      // the order and opens the bKash session in one SQL call, and the
      // customer's next screen is bKash's. `creating` stays true through the
      // redirect so a slow function cannot be double-submitted into two
      // sessions.
      const { data, error: fnError } = await supabase.functions.invoke('bkash-create-payment', {
        // bKash needs to know where to send the browser back to; the function
        // builds the callback from this origin and bKash's own whitelist is
        // what makes a spoofed value harmless.
        body: {
          slug: slug.value,
          kind: selectedKind.value,
          amount: amount.value,
          origin: window.location.origin,
          context: buildVisitContext(customerCountry.value, await resolveCity()),
        },
      })

      if (fnError) {
        const failure = await describeEdgeFailure(fnError, 'The payment could not start.')
        if (failure.cause !== '') console.warn('[bkash-create-payment]', failure)
        // `kind_mismatch` needs a state change, not a sentence: take the
        // customer to the order that is already waiting.
        if (failure.message.startsWith('kind_mismatch:')) {
          await handOffToOpenOrder()
          return
        }
        error.value = failure.message
        return
      }

      const payload = data as
        { ok: true; redirectUrl: string } | { ok: false; refusal: { code?: string } } | null

      if (payload && payload.ok === false) {
        error.value = describeRefusal(payload.refusal?.code)
        return
      }
      if (!payload || payload.ok !== true || !payload.redirectUrl) {
        error.value = t('customer.paywall.refused')
        return
      }

      window.location.assign(payload.redirectUrl)
    } catch (err) {
      error.value = err instanceof Error ? err.message : 'Failed to create order'
    } finally {
      creating.value = false
    }
  }

  /**
   * The manual path, in one click: the order is created, the proof is
   * uploaded against it and submitted, and the page itself turns into the
   * order status. There is no separate order page to walk through any more -
   * the form the customer just filled in is on this page, and so is what
   * replaces it.
   */
  const createManualOrder = async (evidence: Record<string, unknown>): Promise<void> => {
    if (!page.value || !selectedKind.value || !isAmountValid.value) {
      return
    }

    creating.value = true
    error.value = null
    try {
      if (!(await ensureSession())) return

      // Signature is `create_order(p_slug, p_kind, p_amount)`, with the amount
      // in whole taka. A *kind*, not a gateway id: the shop decides which
      // account of that kind the money goes to, weighted, and the client no
      // longer gets a say in that.
      const { data, error: createError } = await rpc<OrderResult>('create_order', {
        p_slug: slug.value,
        p_kind: selectedKind.value,
        p_amount: amount.value,
        p_context: buildVisitContext(customerCountry.value, await resolveCity()),
      })

      if (createError) {
        // `kind_mismatch` is raised, not returned as a refusal code, and the
        // migration's own comment says what the client owes here: change
        // state, not show a message. The customer already has an open order
        // for this report, pinned to one gateway so a transfer receipt cannot
        // end up aimed at an account nobody watches.
        if (
          typeof createError.message === 'string' &&
          createError.message.startsWith('kind_mismatch:')
        ) {
          await handOffToOpenOrder()
          return
        }

        error.value =
          'transport' in createError && createError.transport
            ? t('customer.errors.network')
            : createError.message
        return
      }

      // The function reports refusals in the payload rather than as an error.
      if (!data?.ok || !data.order_id) {
        error.value = describeRefusal(data?.code)
        return
      }

      // The uploads need the order id - that is half of every storage path -
      // so the proof can only be sent now that the order exists. If this half
      // fails, the order stands and the page's own order card offers the
      // proof form again; nothing is lost and nothing is asked twice.
      const payload = await buildEvidencePayload(evidence, fileUpload.upload, data.order_id)

      const { error: submitError } = await supabase.rpc('submit_evidence', {
        p_order_id: data.order_id,
        ...payload,
      })

      if (submitError) {
        error.value = submitError.message
        // The order exists; adopt it so the inline card takes over from the
        // form.
        await adoptOrder(data.order_id)
        return
      }

      await adoptOrder(data.order_id)
    } catch (err) {
      error.value = describeCaught(err, 'Failed to create order')
    } finally {
      creating.value = false
    }
  }

  /**
   * Leaves a rejected order behind: the database detaches it from the user,
   * so it stops being theirs and stops being in any new order's way, and the
   * panel steps aside for the gateway banners again. Only a rejected order
   * detaches - every other status is either still actionable or is ownership.
   */
  const detaching = ref(false)

  const startAnotherOrder = async (): Promise<void> => {
    const order = existingOrder.value
    if (!order || detaching.value) return

    detaching.value = true
    error.value = null
    try {
      const { error: detachError } = await supabase.rpc('detach_order', {
        p_order_id: order.id,
      })

      if (detachError) {
        error.value = detachError.message
        return
      }

      polling?.stopPolling()
      polling = null
      existingOrder.value = null
      orderDetails.value = null
      selectedKind.value = null
      preselectKind()
    } catch (err) {
      error.value = describeCaught(err, 'Failed to start a new order')
    } finally {
      detaching.value = false
    }
  }

  const init = (): void => {
    void loadCustomerCountry()
    preselectKind()
    void loadExistingOrder()
  }

  return {
    // state
    maintenance,
    supportContact,
    gateways,
    selectedKind,
    amount,
    creating,
    error,
    existingOrder,
    orderDetails,
    unlockedBody,
    paying,
    submittingEvidence,
    customerCountry,
    detaching,
    justPaid: computed(() => route.query?.paid === '1'),
    telegramInvite,
    // computeds
    orderGateway,
    orderPaysOnline,
    selectedGateway,
    pickedGatewayName,
    selectedAccountFields,
    selectedInstructions,
    orderAccountFields,
    orderAccountLegacy,
    orderEvidenceFields,
    pageTitle,
    pageCta,
    ctaUrl,
    effectiveMin,
    hideMin,
    amountPresets,
    fixedAmount,
    isAmountValid,
    amountHint,
    amountError,
    kindPaysOnline,
    gatewayBanners,
    // helpers
    pick,
    money,
    formatExpiry,
    selectPreset,
    applyDefaultAmount,
    startInvitePolling,
    stopInvitePolling,
    // actions
    init,
    payExisting,
    submitEvidence,
    startAnotherOrder,
    createOrder,
    createManualOrder,
  }
}

export type PageCheckout = ReturnType<typeof buildCheckout>

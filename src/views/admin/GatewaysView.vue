<template>
  <div>
    <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="page-title">Payment methods</h1>
        <p class="page-subtitle">
          Any method you like — the account customers pay to, or an automatic one.
        </p>
      </div>
      <router-link to="/admin/gateways/new" class="btn-primary">
        <AppIcon name="plus" :size="18" />
        New method
      </router-link>
    </header>

    <div v-if="loading" class="empty-state">Loading...</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <div v-else-if="gateways.length === 0" class="card empty-state">
      <AppIcon name="card" :size="28" class="mx-auto mb-3 text-stone-400" />
      <p class="font-medium text-stone-700">No payment methods yet</p>
      <p class="mt-1">Add bKash, Nagad, a bank account, or anything else you accept.</p>
    </div>

    <!--
      Cards, not a table. Seven columns of prose - mode, environment, traffic share,
      destination summary, proof fields, status, actions - cannot survive a narrow
      viewport without becoming a horizontal scroll, and a horizontal scroll in the
      middle of a settings page is where rows go unread. One card per method keeps
      every signal and reflows at any width.
    -->
    <div v-else class="grid gap-4 lg:grid-cols-2">
      <div v-for="gw in gateways" :key="gw.id" class="card card-pad flex flex-col">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="font-medium text-stone-900">{{ gw.name_en || gw.name_bn || '—' }}</p>
            <p class="text-xs text-stone-500 uppercase">{{ gw.kind }}</p>
          </div>
          <span :class="gw.is_active ? 'badge-ok' : 'badge-muted'">
            {{ gw.is_active ? 'Active' : 'Hidden' }}
          </span>
        </div>

        <div class="mt-3 flex flex-wrap items-center gap-2">
          <span v-if="gw.provider" class="badge-ok">Automatic</span>
          <span v-else class="badge-muted">Manual</span>
          <!-- Which bKash this row's credentials belong to. Shown because a sandbox
               method silently never settles, and "it is active but nothing happens" is
               the symptom an operator would otherwise have to guess at. -->
          <span
            v-if="gw.provider"
            class="badge-muted text-[11px]"
            :class="gw.environment === 'live' ? 'text-emerald-700' : 'text-amber-700'"
          >
            {{ gw.environment === 'live' ? 'Live' : 'Sandbox' }}
          </span>
          <span v-if="gw.provider && gw.environment !== 'live'" class="text-[11px] text-amber-700">
            Never settles
          </span>
        </div>
        <p v-if="gw.provider" class="mt-1 text-xs text-stone-500">
          Approves itself on confirmation
        </p>

        <dl class="mt-4 space-y-2 text-sm">
          <div v-if="trafficShare(gw)" class="flex items-baseline justify-between gap-3">
            <dt class="text-stone-500">Traffic</dt>
            <dd class="text-right">
              {{ trafficShare(gw) }}
              <span class="text-xs text-stone-500"> of {{ gw.kind }}</span>
            </dd>
          </div>
          <div class="flex items-baseline justify-between gap-3">
            <dt class="text-stone-500">Send money to</dt>
            <dd class="text-right">
              <span v-if="detailCount(gw) > 0" :title="detailSummary(gw)">
                {{ detailCount(gw) }} ·
                <span class="text-xs text-stone-500">{{ detailSummary(gw) }}</span>
              </span>
              <span v-else-if="gw.provider" class="text-stone-400">Collected by provider</span>
              <span v-else class="text-stone-400">—</span>
            </dd>
          </div>
          <div class="flex items-baseline justify-between gap-3">
            <dt class="text-stone-500">Proof fields</dt>
            <dd class="text-right">
              <span
                v-if="fieldCount(gw) > 0"
                class="badge-muted ltr-value"
                :title="fieldKeys(gw).join(', ')"
              >
                {{ fieldCount(gw) }} · {{ fieldKeys(gw).join(', ') }}
              </span>
              <span v-else class="text-stone-400">None</span>
            </dd>
          </div>
        </dl>

        <div class="mt-4 flex items-center justify-end gap-1 border-t border-stone-100 pt-3">
          <router-link
            :to="`/admin/gateways/${gw.id}/edit`"
            class="btn-secondary !px-3 !py-1.5 !text-xs"
          >
            Edit
          </router-link>
          <button
            type="button"
            class="btn-secondary !px-2.5 !py-1.5 text-red-700 hover:!bg-red-50"
            :aria-label="`Delete ${gw.name_en || 'gateway'}`"
            @click="deleteGateway(gw.id)"
          >
            <AppIcon name="trash" :size="16" />
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import AppIcon from '@/components/AppIcon.vue'
import { rpc } from '@/lib/rpc'

/**
 * The row `admin_gateways` returns. Typed because this view now reasons about two
 * different shapes of "where the money goes" - `account_fields` for a method saved since
 * the column existed, the legacy pair for one that has not been resaved - and reading
 * either off an `any` would let a rename pass typecheck while every detail rendered as
 * nothing.
 */
interface GatewayRow {
  id: string
  kind: string
  provider: string | null
  name_en: string | null
  name_bn: string | null
  account_fields: { key: string; label_en: string; value: string }[] | null
  account_number: string | null
  account_name: string | null
  evidence_fields: { key: string }[] | null
  is_active: boolean
  /**
   * Present only for an automatic gateway, and deliberately defaulted rather than left
   * possibly-undefined: `admin_upsert_gateway` coalesces a blank to 'sandbox', so a row saved
   * before the column existed reads back as null and means sandbox, not "unknown".
   */
  environment: 'sandbox' | 'live' | null
  /** Share of the kind's traffic this account takes. Absent means one share. */
  weight: number | null
}

const gateways = ref<GatewayRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

/**
 * The other accounts competing for this kind's traffic, and what share each one takes.
 *
 * A weight decides nothing until there is something to decide between, so a kind with a
 * single account renders an em dash instead of "100%": a percentage the operator cannot
 * change is noise, and it would sit in a column that looks like it is asking for input.
 * Inactive accounts are excluded because the database excludes them from the draw, and a
 * share computed against them would disagree with the traffic that actually arrives.
 */
const rivals = (gw: GatewayRow): GatewayRow[] =>
  gateways.value.filter((g) => g.kind === gw.kind && g.is_active && g.id !== gw.id)

const trafficShare = (gw: GatewayRow): string | null => {
  const others = rivals(gw)
  if (others.length === 0) return null

  const total = [gw, ...others].reduce((sum, g) => sum + (g.weight ?? 1), 0)
  if (total <= 0) return null

  const pct = Math.round(((gw.weight ?? 1) / total) * 100)
  return `${pct}%`
}

const fieldCount = (gw: GatewayRow): number => gw.evidence_fields?.length ?? 0

const fieldKeys = (gw: GatewayRow): string[] => (gw.evidence_fields ?? []).map((f) => f.key)

/**
 * How many destinations this method publishes, counting the legacy pair for a gateway
 * saved before `account_fields` existed. Without the fallback the list would show an
 * em dash for a bank transfer that very much has an account number.
 */
const details = (gw: GatewayRow): { key: string; label_en: string; value: string }[] => {
  const configured = (gw.account_fields ?? []).filter((f) => f.value?.trim())
  if (configured.length > 0) return configured

  const fallback: { key: string; label_en: string; value: string }[] = []
  if (gw.account_number?.trim()) {
    fallback.push({
      key: 'account_number',
      label_en: 'Account number',
      value: gw.account_number,
    })
  }
  if (gw.account_name?.trim()) {
    fallback.push({ key: 'account_name', label_en: 'Account name', value: gw.account_name })
  }
  return fallback
}

const detailCount = (gw: GatewayRow): number => details(gw).length

const detailSummary = (gw: GatewayRow): string =>
  details(gw)
    .map((d) => d.label_en)
    .join(', ')

const loadGateways = async (): Promise<void> => {
  error.value = null
  try {
    const { data, error: rpcError } = await rpc<Record<string, unknown>>('admin_gateways')
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    gateways.value = (data ?? []) as unknown as typeof gateways.value
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load gateways'
  } finally {
    loading.value = false
  }
}

const deleteGateway = async (id: string): Promise<void> => {
  if (!confirm('Delete this payment method? Orders that already reference it keep their copy.'))
    return
  try {
    // `p_gateway_id`, not `p_id`, to match `api.admin_delete_gateway(uuid)`.
    const { error: rpcError } = await rpc<Record<string, unknown>>('admin_delete_gateway', {
      p_gateway_id: id,
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    await loadGateways()
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to delete'
  }
}

onMounted(loadGateways)
</script>

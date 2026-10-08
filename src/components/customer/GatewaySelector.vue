<template>
  <div class="space-y-3">
    <label
      v-for="option in options"
      :key="option.kind"
      class="block cursor-pointer rounded-xl border p-4 transition"
      :class="
        selected === option.kind
          ? 'border-brand-600 bg-brand-50 ring-1 ring-brand-600'
          : 'border-stone-200 bg-white hover:border-stone-300'
      "
    >
      <div class="flex items-start gap-3">
        <input
          type="radio"
          name="gateway-kind"
          class="mt-1 size-4 shrink-0 accent-brand-700"
          :checked="selected === option.kind"
          :aria-label="option.label"
          @change="select(option.kind)"
        />

        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="font-semibold text-stone-900">{{ option.label }}</span>
            <span class="badge-muted uppercase">{{ option.kind }}</span>
          </div>

          <!-- The mode is the one thing a customer cannot infer from a wallet number, and
               it is what decides whether they are handed to a processor or shown
               instructions. `provider` is null for a manual method. -->
          <p class="mt-1 text-xs text-stone-500">
            {{
              option.provider ? 'Taken automatically when you pay' : 'You send it, then send proof'
            }}
          </p>
        </div>
      </div>
    </label>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useContent } from '@/composables/useContent'

/**
 * What the paywall payload now carries for a gateway: an id, a kind, a display name, the
 * provider slug, and a sort order. Deliberately narrow - the account number, instructions,
 * reference prompt and evidence fields were published here for every anonymous visitor of
 * every paywall page and now live on the order instead, so this component has nothing to
 * render them from.
 */
interface Gateway {
  id: string
  kind: string
  name_en: string | null
  name_bn: string | null
  provider: string | null
  sort_order: number | null
}

const props = defineProps<{ gateways: Gateway[] }>()

const emit = defineEmits<{ (e: 'select', kind: string): void }>()

/**
 * The kind, not the gateway id. With weighted routing a kind can have several accounts
 * behind it and the customer has no business choosing between them - they chose "bKash",
 * and which bKash wallet is the shop's decision. Grouping by kind is what keeps the
 * selector showing one row per choice rather than one row per bank account.
 *
 * Every gateway of a kind agrees on `provider`: `private.guard_gateway_kind_uniformity`
 * refuses an active kind that is both manual and automatic, so the first row's value is the
 * kind's value and there is no case where these disagree.
 */
const options = computed(() => {
  const byKind = new Map<string, Gateway>()
  for (const gateway of props.gateways) {
    const existing = byKind.get(gateway.kind)
    if (!existing || (gateway.sort_order ?? 0) < (existing.sort_order ?? 0)) {
      byKind.set(gateway.kind, gateway)
    }
  }
  return [...byKind.values()]
    .sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0))
    .map((gateway) => ({
      kind: gateway.kind,
      provider: gateway.provider,
      label: pick({ bn: gateway.name_bn, en: gateway.name_en }) || gateway.kind,
    }))
})

const { pick } = useContent()

const selected = defineModel<string | null>('selected', { default: null })

const select = (kind: string): void => {
  selected.value = kind
  emit('select', kind)
}
</script>

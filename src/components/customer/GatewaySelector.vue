<template>
  <div class="space-y-3">
    <label
      v-for="gateway in gateways"
      :key="gateway.id"
      class="block cursor-pointer rounded-xl border p-4 transition"
      :class="
        selectedGatewayId === gateway.id
          ? 'border-brand-600 bg-brand-50 ring-1 ring-brand-600'
          : 'border-stone-200 bg-white hover:border-stone-300'
      "
    >
      <div class="flex items-start gap-3">
        <input
          type="radio"
          name="gateway"
          class="mt-1 size-4 shrink-0 accent-brand-700"
          :checked="selectedGatewayId === gateway.id"
          :aria-label="getGatewayName(gateway)"
          @change="selectGateway(gateway.id)"
        />

        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="font-semibold text-stone-900">{{ getGatewayName(gateway) }}</span>
            <span class="badge-muted uppercase">{{ gateway.kind }}</span>
          </div>

          <div v-if="gateway.account_number" class="mt-3">
            <p class="label !mb-1">{{ t('customer.paywall.sendTo') }}</p>
            <button
              type="button"
              class="group inline-flex max-w-full items-center gap-2 rounded-lg bg-white px-2.5 py-1.5 text-left ring-1 ring-stone-200 transition hover:ring-brand-400"
              :aria-label="t('customer.common.copy')"
              @click.prevent.stop="copyAccount(gateway)"
            >
              <span class="ltr-value truncate font-semibold text-stone-900">
                {{ gateway.account_number }}
              </span>
              <span v-if="gateway.account_name" class="truncate text-xs text-stone-500">
                {{ gateway.account_name }}
              </span>
              <AppIcon
                name="check"
                :size="16"
                class="ml-auto shrink-0 text-emerald-600"
                :class="copiedId === gateway.id ? '' : 'text-stone-400'"
              />
            </button>
          </div>

          <div v-if="getGatewayInstructions(gateway)" class="mt-3">
            <MarkdownBody :source="getGatewayInstructions(gateway)" />
          </div>
        </div>
      </div>
    </label>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { useContent } from '@/composables/useContent'
import AppIcon from '@/components/AppIcon.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'

interface Gateway {
  id: string
  kind?: string
  name_bn: string | null
  name_en: string | null
  instructions_md_bn: string | null
  instructions_md_en: string | null
  account_number: string | null
  account_name: string | null
  [key: string]: unknown
}

defineProps<{ gateways: Gateway[] }>()

const emit = defineEmits<{ (e: 'select', gatewayId: string): void }>()

const selectedGatewayId = defineModel<string | null>('selected', { default: null })

const { pick } = useContent()
const { t } = useI18n()

const copiedId = ref<string | null>(null)

const getGatewayName = (gateway: Gateway): string => {
  return pick({ bn: gateway.name_bn, en: gateway.name_en } as any) || ''
}

const getGatewayInstructions = (gateway: Gateway): string => {
  return pick({ bn: gateway.instructions_md_bn, en: gateway.instructions_md_en } as any) || ''
}

// The account number is transcribed by hand into the bKash/Nagad app, so it is
// offered as a copy target rather than left for the customer to retype.
const copyAccount = async (gateway: Gateway): Promise<void> => {
  if (!gateway.account_number) return
  try {
    await navigator.clipboard.writeText(gateway.account_number)
    copiedId.value = gateway.id
    setTimeout(() => (copiedId.value = null), 1500)
  } catch {
    // Clipboard access can be refused; the number is still visible to read.
  }
}

const selectGateway = (gatewayId: string): void => {
  selectedGatewayId.value = gatewayId
  emit('select', gatewayId)
}
</script>

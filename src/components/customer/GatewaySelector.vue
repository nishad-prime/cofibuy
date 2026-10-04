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

          <div v-if="hasDetails(gateway)" class="mt-3">
            <p class="label !mb-1">{{ t('customer.paywall.sendTo') }}</p>
            <GatewayAccountDetails
              :fields="gateway.account_fields"
              :legacy-number="gateway.account_number"
              :legacy-name="gateway.account_name"
            />
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
import { useI18n } from 'vue-i18n'
import { useContent } from '@/composables/useContent'
import MarkdownBody from '@/components/MarkdownBody.vue'
import GatewayAccountDetails, {
  type AccountField,
} from '@/components/customer/GatewayAccountDetails.vue'

interface Gateway {
  id: string
  kind?: string
  name_bn: string | null
  name_en: string | null
  instructions_md_bn: string | null
  instructions_md_en: string | null
  account_fields: AccountField[] | null
  account_number: string | null
  account_name: string | null
  [key: string]: unknown
}

defineProps<{ gateways: Gateway[] }>()

const emit = defineEmits<{ (e: 'select', gatewayId: string): void }>()

const selectedGatewayId = defineModel<string | null>('selected', { default: null })

const { pick } = useContent()
const { t } = useI18n()

const getGatewayName = (gateway: Gateway): string => {
  return pick({ bn: gateway.name_bn, en: gateway.name_en } as any) || ''
}

const getGatewayInstructions = (gateway: Gateway): string => {
  return pick({ bn: gateway.instructions_md_bn, en: gateway.instructions_md_en } as any) || ''
}

/**
 * Whether there is anything to show. An automated method has no destination at all, so
 * the heading is suppressed rather than printed above an empty space.
 */
const hasDetails = (gateway: Gateway): boolean => {
  if ((gateway.account_fields ?? []).some((field) => field.value?.trim())) return true
  return !!(gateway.account_number?.trim() || gateway.account_name?.trim())
}

const selectGateway = (gatewayId: string): void => {
  selectedGatewayId.value = gatewayId
  emit('select', gatewayId)
}
</script>

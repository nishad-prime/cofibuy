<template>
  <div class="space-y-4">
    <div
      v-for="gateway in gateways"
      :key="gateway.id"
      class="cursor-pointer rounded-lg border p-4 transition-colors"
      :class="
        selectedGatewayId === gateway.id
          ? 'border-blue-500 bg-blue-50'
          : 'border-gray-200 hover:border-gray-300'
      "
      @click="selectGateway(gateway.id)"
    >
      <div class="flex items-start justify-between">
        <div>
          <h3 class="text-lg font-semibold">
            {{ getGatewayName(gateway) }}
          </h3>
          <p v-if="getGatewayInstructions(gateway)" class="mt-2 text-sm text-gray-600">
            {{ getGatewayInstructions(gateway) }}
          </p>
          <p v-if="gateway.account_number" class="mt-2 text-sm text-gray-700">
            {{ gateway.account_number }}
            <span v-if="gateway.account_name">({{ gateway.account_name }})</span>
          </p>
        </div>
        <input
          type="radio"
          :checked="selectedGatewayId === gateway.id"
          class="mt-1 h-4 w-4 text-blue-600"
          @change="selectGateway(gateway.id)"
        />
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useContent } from '@/composables/useContent'

interface Gateway {
  id: string
  name_bn: string | null
  name_en: string | null
  instructions_bn: string | null
  instructions_en: string | null
  account_number: string | null
  account_name: string | null
  [key: string]: any
}

defineProps<{
  gateways: Gateway[]
}>()

const emit = defineEmits<{
  (e: 'select', gatewayId: string): void
}>()

const selectedGatewayId = defineModel<string | null>('selected', { default: null })

const { pick } = useContent()

const getGatewayName = (gateway: Gateway): string => {
  return pick({ bn: gateway.name_bn, en: gateway.name_en } as any) || ''
}

const getGatewayInstructions = (gateway: Gateway): string => {
  return pick({ bn: gateway.instructions_bn, en: gateway.instructions_en } as any) || ''
}

const selectGateway = (gatewayId: string): void => {
  selectedGatewayId.value = gatewayId
  emit('select', gatewayId)
}
</script>

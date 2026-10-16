<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { formatMoney } from '@/lib/money'
import { useAdminCurrency } from '@/composables/useAdminCurrency'
import { useAnimatedNumber } from '@/composables/useAnimatedNumber'

const props = defineProps<{
  value: number | null | undefined
  money?: boolean
}>()

const { currency } = useAdminCurrency()

const numeric = computed(() => (typeof props.value === 'number' ? props.value : null))
const { displayed, set, seed } = useAnimatedNumber(numeric.value ?? 0)

const seeded = ref(false)

watch(
  numeric,
  (next) => {
    if (next === null) return
    if (!seeded.value) {
      seed(next)
      seeded.value = true
      return
    }
    set(next)
  },
  { immediate: true },
)

const text = computed(() => {
  if (numeric.value === null) return '—'
  return props.money ? formatMoney(displayed.value, 'en', currency.value) : String(displayed.value)
})
</script>

<template>
  <span class="ltr-value tabular-nums">{{ text }}</span>
</template>

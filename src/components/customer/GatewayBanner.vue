<template>
  <!--
    One gateway banner on the modal's first step. The image IS the button -
    no overlay text, no labels: banners are recognizable art, and tapping one
    picks the kind and walks straight into the send step.
  -->
  <button
    type="button"
    class="gateway-banner group relative block w-full overflow-hidden rounded-2xl text-left transition"
    :class="[
      size === 'big' ? 'col-span-2 ring-2 ring-brand-500' : 'ring-1 ring-white/10',
      size === 'foreign'
        ? 'scale-[0.92] opacity-60 hover:scale-100 hover:opacity-100'
        : 'hover:ring-brand-400',
    ]"
    @click="$emit('select')"
  >
    <img
      v-if="entry.bannerUrl"
      :src="entry.bannerUrl"
      :alt="entry.name"
      class="w-full object-cover"
      :class="size === 'big' ? 'aspect-[3/1]' : 'aspect-[1.5/1]'"
    />
    <!-- No art uploaded: a branded card with the name still reads as a choice. -->
    <div
      v-else
      class="flex w-full items-center justify-center bg-gradient-to-br from-stone-800 via-stone-900 to-stone-950"
      :class="size === 'big' ? 'aspect-[3/1]' : 'aspect-[1.5/1]'"
    >
      <span class="px-4 text-center text-base font-bold text-white">{{ entry.name }}</span>
    </div>
  </button>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import type { GatewayBanner as GatewayBannerEntry } from '@/composables/usePageCheckout'

const props = defineProps<{
  entry: GatewayBannerEntry
}>()

defineEmits<{ (e: 'select'): void }>()

const size = computed(() => props.entry.size)
</script>

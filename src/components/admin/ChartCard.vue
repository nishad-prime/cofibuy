<template>
  <section class="card card-pad flex h-full flex-col">
    <div class="flex items-start justify-between gap-3">
      <div>
        <h2 class="text-sm font-semibold text-stone-900">{{ title }}</h2>
        <p v-if="hint" class="hint">{{ hint }}</p>
      </div>
      <slot name="action" />
    </div>
    <div class="mt-4 flex-1">
      <slot />
    </div>
  </section>
</template>

<script setup lang="ts">
defineProps<{ title: string; hint?: string }>()
</script>

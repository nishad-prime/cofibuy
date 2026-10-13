<template>
  <!--
    A tasteful stand-in for an unassigned image slot. An empty slot would
    collapse the layout; a raw broken-image would look broken. The gradient
    block keeps the section's rhythm and carries the one mark that matters
    on an 18+ page.

    Deliberately carries NO size classes of its own: the caller sizes it
    (aspect ratio or fixed box), and an internal h-full would override the
    caller's aspect ratio and collapse the box.
  -->
  <div
    class="flex items-center justify-center bg-gradient-to-br from-stone-700 via-stone-900 to-stone-950"
    role="img"
    :aria-label="label ?? undefined"
  >
    <span
      class="rounded-full border border-white/25 bg-white/5 px-5 py-2 text-sm font-bold tracking-[0.25em] text-brand-300 ltr-value"
    >
      18+
    </span>
  </div>
</template>

<script setup lang="ts">
withDefaults(
  defineProps<{
    /** Read to screen readers; also what the slot would have described. */
    label?: string | null
  }>(),
  { label: null },
)
</script>

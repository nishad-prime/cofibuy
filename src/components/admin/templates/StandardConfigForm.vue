<template>
  <p class="text-sm text-gray-600">
    The standard layout has no options. The page's title and teaser are the only content it draws,
    and both are edited above.
  </p>
</template>

<script setup lang="ts">
/**
 * The standard template's config editor: deliberately empty.
 *
 * The component exists so the page form can render "the selected template's
 * options" for every template without knowing which ones have any. If the
 * standard layout ever gains an option, it arrives here — and the registry
 * already points at this file.
 */
</script>

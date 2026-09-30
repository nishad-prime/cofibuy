<script setup lang="ts">
import { renderMarkdown } from '@/lib/markdown'
import { computed } from 'vue'

const props = withDefaults(defineProps<{ source?: string | null }>(), { source: null })

const html = computed(() => renderMarkdown(props.source))
</script>

<template>
  <!-- eslint-disable-next-line vue/no-v-html -- sanitised in renderMarkdown -->
  <div class="prose-en prose-sm max-w-none text-stone-800" v-html="html" />
</template>

<style>
/*
 * Minimal typographic rules for rendered Markdown. Kept global rather than
 * scoped because v-html content is not processed by scoped styles.
 */
.prose-en :is(h1, h2, h3) {
  @apply mt-6 mb-2 font-semibold text-stone-900;
}
.prose-en :is(h1) {
  @apply text-xl;
}
.prose-en :is(h2) {
  @apply text-lg;
}
.prose-en :is(h3) {
  @apply text-base;
}
.prose-en p {
  @apply my-3 leading-relaxed;
}
.prose-en :is(ul, ol) {
  @apply my-3 space-y-1 ps-5;
}
.prose-en ul {
  @apply list-disc;
}
.prose-en ol {
  @apply list-decimal;
}
.prose-en a {
  @apply text-brand-700 underline underline-offset-2 hover:text-brand-800;
}
.prose-en code {
  @apply rounded bg-stone-100 px-1 py-0.5 text-[0.85em];
}
.prose-en pre {
  @apply my-3 overflow-x-auto rounded-lg bg-stone-900 p-3 text-xs text-stone-100;
}
.prose-en pre code {
  @apply bg-transparent p-0 text-inherit;
}
.prose-en blockquote {
  @apply my-3 border-s-4 border-stone-200 ps-4 text-stone-600;
}
.prose-en img {
  @apply my-4 max-w-full rounded-lg;
}
.prose-en hr {
  @apply my-6 border-stone-200;
}
.prose-en table {
  @apply my-3 w-full text-start text-sm;
}
.prose-en :is(th, td) {
  @apply border border-stone-200 px-2 py-1;
}
</style>

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
 *
 * Every rule is written once. An earlier revision repeated the list/link block
 * verbatim, which made later edits look applied when they were not.
 */
.prose-en :is(h1, h2, h3) {
  margin-top: 1.5rem;
  margin-bottom: 0.5rem;
  font-weight: 600;
  color: rgb(28 25 23);
}
.prose-en :is(h1) {
  font-size: 1.25rem;
}
.prose-en :is(h2) {
  font-size: 1.125rem;
}
.prose-en :is(h3) {
  font-size: 1rem;
}
.prose-en :is(h1, h2, h3):first-child {
  margin-top: 0;
}
.prose-en p {
  margin-top: 0.75rem;
  margin-bottom: 0.75rem;
  line-height: 1.625;
}
.prose-en ul,
.prose-en ol {
  margin-top: 0.75rem;
  margin-bottom: 0.75rem;
  padding-left: 1.25rem;
}
.prose-en ul {
  list-style-type: disc;
}
.prose-en ol {
  list-style-type: decimal;
}
.prose-en li {
  margin-top: 0.25rem;
  margin-bottom: 0.25rem;
}
.prose-en a {
  color: rgb(120 63 4);
  text-decoration: underline;
  text-underline-offset: 2px;
}
.prose-en a:hover {
  color: rgb(87 45 3);
}
.prose-en code {
  border-radius: 0.25rem;
  background-color: rgb(245 245 244);
  padding: 0.125rem 0.25rem;
  font-size: 0.85em;
}
.prose-en pre {
  margin-top: 0.75rem;
  margin-bottom: 0.75rem;
  overflow-x: auto;
  border-radius: 0.5rem;
  background-color: rgb(28 25 23);
  padding: 0.75rem;
  font-size: 0.75rem;
  color: rgb(245 245 244);
}
.prose-en pre code {
  background-color: transparent;
  padding: 0;
  color: inherit;
}
.prose-en blockquote {
  margin-top: 0.75rem;
  margin-bottom: 0.75rem;
  border-left-width: 4px;
  border-color: rgb(231 229 228);
  padding-left: 1rem;
  color: rgb(87 83 78);
}
.prose-en img {
  margin-top: 1rem;
  margin-bottom: 1rem;
  max-width: 100%;
  border-radius: 0.5rem;
}
.prose-en hr {
  margin-top: 1.5rem;
  margin-bottom: 1.5rem;
  border-color: rgb(231 229 228);
}
.prose-en table {
  margin-top: 0.75rem;
  margin-bottom: 0.75rem;
  width: 100%;
  text-align: start;
  font-size: 0.875rem;
}
.prose-en :is(th, td) {
  border-width: 1px;
  border-color: rgb(231 229 228);
  padding: 0.25rem 0.5rem;
}
.prose-en th {
  background-color: rgb(250 250 249);
  font-weight: 600;
}
</style>

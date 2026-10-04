<script setup lang="ts">
/**
 * Renders one operator-overridden string, as markdown when the database says so.
 *
 * Every caller passes a key that is a standalone prose block, enforced by the
 * `MarkdownCopyKey` prop type rather than by trust.
 *
 * Two things are worth knowing about the markup this produces.
 *
 * The two branches are different elements. The plain branch honours `tag`, so a
 * call site that was a `<p>` stays a `<p>` and the default styling is untouched.
 * The markdown branch is always `MarkdownBody`'s `<div>`, because a rendered
 * block cannot live inside a `<p>` - the browser closes the `<p>` early and the
 * rest of the paragraph becomes a sibling. All six call sites are standalone
 * block slots, so the swap to `<div>` is valid wherever it happens.
 *
 * `class` is not declared as a prop, so Vue's fallthrough puts it on whichever
 * branch renders. That means a call site writes its classes once and they apply
 * in both modes. In markdown mode the element also carries `MarkdownBody`'s own
 * `prose-en prose-sm text-stone-800`, which is intentional: the operator asked
 * for markdown, and markdown has its own typography. The plain path - what a
 * customer sees unless someone opts a key in - looks exactly as it did before.
 */
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import MarkdownBody from '@/components/MarkdownBody.vue'
import { useCopyOverrides } from '@/composables/useCopyOverrides'
import type { MarkdownCopyKey } from '@/config/copyKeys'

const props = withDefaults(
  defineProps<{
    /** Dotted key below `customer.`, from the registry's markdown-allowed list. */
    copyKey: MarkdownCopyKey
    /** Element for the plain-text branch. Ignored when the key renders as markdown. */
    tag?: string
  }>(),
  { tag: 'span' },
)

const { t } = useI18n()
const { isMarkdown } = useCopyOverrides()

const text = computed(() => t(`customer.${props.copyKey}`) as string)
const markdown = computed(() => isMarkdown(props.copyKey))
</script>

<template>
  <MarkdownBody v-if="markdown" :source="text" />
  <component v-else :is="props.tag">{{ text }}</component>
</template>

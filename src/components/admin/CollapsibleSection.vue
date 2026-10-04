<script setup lang="ts">
import { computed } from 'vue'
import AppIcon from '@/components/AppIcon.vue'

/**
 * A titled panel the operator can fold away.
 *
 * Both admin forms grew long enough that all of it open at once stopped being
 * readable: the gateway form is six panels and the copy editor is a dozen. Folding
 * them is only useful if the panels stay consistent with each other, so the open
 * state is deliberately *not* owned here.
 *
 *   1. Only one open at a time is a rule about the set, and a component that only
 *      knows about itself cannot enforce it. The parent holds a single section id.
 *   2. A save can fail on a field nobody can currently see. If the panel owned its own
 *      state there would be no way to say "open yourself, you have a problem", and
 *      the error would be filed inside a closed box where it looks like nothing
 *      happened. The parent sets `open` for that, and `hasError` marks which panel.
 *
 * The body is `v-show`, never `v-if`. `AccountFieldEditor` and `EvidenceFieldEditor`
 * keep unsaved rows in their own state and expose them through template refs, and the
 * gateway form reads those refs when it builds the save payload. `v-if` unmounts them,
 * so folding a panel would discard everything typed into it. Hiding costs nothing here
 * and keeps that state alive.
 */
const open = defineModel<boolean>('open', { required: true })

const props = defineProps<{
  /** Stable id, so the header and body can reference each other. */
  panelId: string
  title: string
  /** Marks a panel holding an invalid field, so it is findable while closed. */
  hasError?: boolean
  /** Rendered in the header beside the title, for counts or short status. */
  note?: string
}>()

const headerId = computed(() => `${props.panelId}-header`)
const bodyId = computed(() => `${props.panelId}-body`)
</script>

<template>
  <section class="card overflow-hidden">
    <h2>
      <button
        :id="headerId"
        type="button"
        class="flex w-full items-center justify-between gap-3 px-5 py-4 text-left hover:bg-stone-50"
        :aria-expanded="open"
        :aria-controls="bodyId"
        @click="open = !open"
      >
        <span class="flex min-w-0 items-center gap-2">
          <AppIcon
            name="chevronDown"
            :size="18"
            class="shrink-0 text-stone-400 transition-transform"
            :class="open ? 'rotate-180' : ''"
          />
          <span class="truncate text-sm font-semibold tracking-wide text-stone-900 uppercase">
            {{ title }}
          </span>
          <span v-if="note" class="badge-muted shrink-0">{{ note }}</span>
          <span v-if="hasError" class="badge-danger shrink-0">Needs attention</span>
        </span>
      </button>
    </h2>

    <div
      v-show="open"
      :id="bodyId"
      role="region"
      :aria-labelledby="headerId"
      class="border-t border-stone-200 p-5"
    >
      <slot />
    </div>
  </section>
</template>

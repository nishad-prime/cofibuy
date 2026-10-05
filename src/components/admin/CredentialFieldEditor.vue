<template>
  <div class="space-y-4">
    <p
      v-if="fields.length"
      class="rounded-lg border border-stone-200 bg-stone-50 p-3 text-xs text-stone-600"
    >
      Credentials are stored per gateway in an encrypted secret bundle and are never sent back to
      this page. A box you do not touch is left exactly as it is — only fields you re-enter are
      replaced.
    </p>

    <div v-for="field in fields" :key="field.key" class="block">
      <label class="mb-1 block text-sm font-medium text-stone-700">
        {{ field.label_en || field.key }}
        <span v-if="!field.secret" class="ml-1 text-xs font-normal text-stone-400">not secret</span>
      </label>

      <div class="relative">
        <input
          :value="value[field.key] ?? ''"
          :type="field.secret ? 'password' : 'text'"
          class="field"
          :placeholder="placeholderFor(field)"
          autocomplete="new-password"
          autocapitalize="off"
          autocorrect="off"
          spellcheck="false"
          :aria-describedby="changed.has(field.key) ? `cred-${field.key}-changed` : undefined"
          @input="onInput(field.key, $event)"
        />
        <span
          v-if="changed.has(field.key)"
          class="absolute right-3 top-1/2 -translate-y-1/2 text-xs font-medium text-amber-700"
        >
          will be replaced
        </span>
      </div>

      <p
        v-if="changed.has(field.key)"
        :id="`cred-${field.key}-changed`"
        class="mt-1 text-xs text-amber-700"
      >
        Saving overwrites the stored value for this field.
      </p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'

/**
 * One credential the provider needs. Mirrors `private.auto_providers.fields`, which is
 * what drives this form - the registry row is the single source of truth, so adding a
 * provider with different credentials is a database insert rather than a new Vue file.
 */
export interface ProviderField {
  key: string
  label_en: string
  secret?: boolean
}

const props = defineProps<{
  fields: ProviderField[]
  /**
   * Only the keys the operator has actually re-entered. The absence of a key means
   * "leave the stored value alone", which is why this is a sparse object rather than
   * a full credential set: sending a blank string for an untouched secret would be
   * read by `store_credential_bundle` as an attempt to clear it, and it refuses.
   */
  modelValue: Record<string, string>
  /** True when the provider already has stored credentials, which changes the placeholders. */
  hasStored?: boolean
}>()

const emit = defineEmits<{ 'update:modelValue': [Record<string, string>] }>()

const value = computed(() => props.modelValue)

/** The keys present in the draft, i.e. the ones this save would replace. */
const changed = computed(() => new Set(Object.keys(props.modelValue)))

const placeholderFor = (field: ProviderField): string => {
  if (field.secret && props.hasStored && !(field.key in props.modelValue)) {
    return 'Unchanged — type to replace'
  }
  return field.secret ? '••••••••' : ''
}

const onInput = (key: string, event: Event): void => {
  const next = { ...props.modelValue }
  const raw = (event.target as HTMLInputElement).value
  // An emptied box is dropped rather than sent as ''. `store_credential_bundle`
  // rejects a blank value, so sending one would turn "I cleared the box" into a
  // validation error naming a field the operator was only trying to leave alone.
  if (raw === '') delete next[key]
  else next[key] = raw
  emit('update:modelValue', next)
}
</script>

<template>
  <div class="space-y-6">
    <div class="grid gap-4 md:grid-cols-2">
      <div>
        <label class="block text-sm font-medium text-gray-700">Hero subtitle (EN)</label>
        <input
          v-model="config.subtitle_en"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-700">Hero subtitle (BN)</label>
        <input
          v-model="config.subtitle_bn"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
      </div>
    </div>

    <!--
      One editor per language pair rather than one per language: a feature row
      is one thought in two languages, and splitting the list per language would
      let the two halves drift out of order.
    -->
    <fieldset class="space-y-3">
      <legend class="text-sm font-medium text-gray-700">Feature list</legend>
      <div
        v-for="(item, index) in config.items"
        :key="index"
        class="rounded-md border border-gray-200 p-3"
      >
        <div class="flex items-center justify-between">
          <p class="text-xs text-gray-500">Feature {{ index + 1 }}</p>
          <button
            type="button"
            class="text-xs text-red-600 hover:underline"
            @click="config.items.splice(index, 1)"
          >
            Remove
          </button>
        </div>
        <div class="mt-2 grid gap-2 md:grid-cols-2">
          <input
            v-model="item.title_en"
            placeholder="Title (EN)"
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <input
            v-model="item.title_bn"
            placeholder="Title (BN)"
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <textarea
            v-model="item.body_en"
            rows="2"
            placeholder="Description (EN)"
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <textarea
            v-model="item.body_bn"
            rows="2"
            placeholder="Description (BN)"
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
        </div>
      </div>
      <button
        type="button"
        class="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
        @click="addItem"
      >
        Add feature
      </button>
    </fieldset>

    <fieldset class="space-y-3">
      <legend class="text-sm font-medium text-gray-700">FAQ</legend>
      <div
        v-for="(entry, index) in config.faq"
        :key="index"
        class="rounded-md border border-gray-200 p-3"
      >
        <div class="flex items-center justify-between">
          <p class="text-xs text-gray-500">Question {{ index + 1 }}</p>
          <button
            type="button"
            class="text-xs text-red-600 hover:underline"
            @click="config.faq.splice(index, 1)"
          >
            Remove
          </button>
        </div>
        <div class="mt-2 grid gap-2 md:grid-cols-2">
          <input
            v-model="entry.q_en"
            placeholder="Question (EN)"
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <input
            v-model="entry.q_bn"
            placeholder="Question (BN)"
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <textarea
            v-model="entry.a_en"
            rows="2"
            placeholder="Answer (EN)"
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <textarea
            v-model="entry.a_bn"
            rows="2"
            placeholder="Answer (BN)"
            class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
        </div>
      </div>
      <button
        type="button"
        class="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
        @click="addFaq"
      >
        Add question
      </button>
    </fieldset>
  </div>
</template>

<script setup lang="ts">
/**
 * The landing template's config editor.
 *
 * `defineModel` rather than a mutated prop: the page form owns the config
 * object, and every keystroke here is an edit to it in place — the same shape
 * the rest of the form uses, so save simply serialises whatever is on screen.
 */
import type { LandingConfig } from '@/pages/templates/registry'

const config = defineModel<LandingConfig>({ required: true })

const addItem = (): void => {
  config.value.items.push({ title_en: '', title_bn: '', body_en: '', body_bn: '' })
}

const addFaq = (): void => {
  config.value.faq.push({ q_en: '', q_bn: '', a_en: '', a_bn: '' })
}
</script>

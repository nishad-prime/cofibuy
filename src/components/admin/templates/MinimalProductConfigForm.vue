<template>
  <div class="space-y-6">
    <CollapsibleSection
      panel-id="product"
      :open="openSections['product'] ?? false"
      @update:open="openSections['product'] = $event"
      title="Product"
    >
      <img
        v-if="config.hero_image_url"
        :src="config.hero_image_url"
        :alt="config.hero_image_alt_en || ''"
        class="w-full max-w-sm rounded-xl"
      />
      <div class="mt-3">
        <label class="label">Product image</label>
        <PageImageUpload v-model:image-url="config.hero_image_url" />
      </div>
      <div class="mt-3 grid gap-4 md:grid-cols-2">
        <div>
          <label class="label">Image alt (EN)</label>
          <input v-model="config.hero_image_alt_en" class="field" />
        </div>
        <div>
          <label class="label">Image alt (BN)</label>
          <input v-model="config.hero_image_alt_bn" class="field" />
        </div>
        <div>
          <label class="label">Title override (EN)</label>
          <input v-model="config.hero_title_en" class="field" />
          <p class="hint">Leave empty to use the page's own title.</p>
        </div>
        <div>
          <label class="label">Title override (BN)</label>
          <input v-model="config.hero_title_bn" class="field" />
        </div>
        <div>
          <label class="label">Subtitle (EN)</label>
          <textarea v-model="config.hero_subtitle_en" rows="2" class="field"></textarea>
        </div>
        <div>
          <label class="label">Subtitle (BN)</label>
          <textarea v-model="config.hero_subtitle_bn" rows="2" class="field"></textarea>
        </div>
      </div>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="what-is-included"
      :open="openSections['what-is-included'] ?? false"
      @update:open="openSections['what-is-included'] = $event"
      title="What is included"
    >
      <div
        v-for="(item, index) in config.included"
        :key="index"
        class="mb-3 rounded-md border border-gray-200 p-3"
      >
        <div class="flex items-center justify-between">
          <p class="text-xs text-gray-500">Item {{ index + 1 }}</p>
          <button
            type="button"
            class="text-xs text-red-600 hover:underline"
            @click="config.included.splice(index, 1)"
          >
            Remove
          </button>
        </div>
        <div class="mt-2 grid gap-2 md:grid-cols-2">
          <input
            v-model="item.title_en"
            placeholder="Title (EN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <input
            v-model="item.title_bn"
            placeholder="Title (BN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <textarea
            v-model="item.body_en"
            rows="2"
            placeholder="Body (EN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <textarea
            v-model="item.body_bn"
            rows="2"
            placeholder="Body (BN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
        </div>
      </div>
      <button
        type="button"
        class="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
        @click="config.included.push({ title_en: '', title_bn: '', body_en: '', body_bn: '' })"
      >
        Add item
      </button>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="checkout"
      :open="openSections['checkout'] ?? false"
      @update:open="openSections['checkout'] = $event"
      title="Checkout"
    >
      <div class="grid gap-4 md:grid-cols-2">
        <div>
          <label class="label">Checkout note (EN)</label>
          <textarea v-model="config.checkout_note_en" rows="2" class="field"></textarea>
        </div>
        <div>
          <label class="label">Checkout note (BN)</label>
          <textarea v-model="config.checkout_note_bn" rows="2" class="field"></textarea>
        </div>
      </div>
    </CollapsibleSection>
  </div>
</template>

<script setup lang="ts">
import CollapsibleSection from '@/components/admin/CollapsibleSection.vue'
import PageImageUpload from '@/components/admin/PageImageUpload.vue'
import { ref } from 'vue'
import type { MinimalProductConfig } from '@/pages/templates/registry'

const openSections = ref<Record<string, boolean>>({
  hero: true,
})

const config = defineModel<MinimalProductConfig>({ required: true })
</script>

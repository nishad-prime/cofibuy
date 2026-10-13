<template>
  <div class="space-y-6">
    <!--
      Sections in the same order the customer sees them, each collapsible so a
      long form stays navigable.
    -->
    <CollapsibleSection
      panel-id="hero"
      :open="openSections['hero'] ?? false"
      @update:open="openSections['hero'] = $event"
      title="Hero"
    >
      <div class="space-y-4">
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Eyebrow (EN)</label>
            <input v-model="config.hero_eyebrow_en" class="field" />
          </div>
          <div>
            <label class="label">Eyebrow (BN)</label>
            <input v-model="config.hero_eyebrow_bn" class="field" />
          </div>
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Hero title (EN)</label>
            <input v-model="config.hero_title_en" class="field" />
          </div>
          <div>
            <label class="label">Hero title (BN)</label>
            <input v-model="config.hero_title_bn" class="field" />
          </div>
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Subtitle (EN)</label>
            <textarea v-model="config.hero_subtitle_en" rows="2" class="field"></textarea>
          </div>
          <div>
            <label class="label">Subtitle (BN)</label>
            <textarea v-model="config.hero_subtitle_bn" rows="2" class="field"></textarea>
          </div>
        </div>

        <label class="label">Hero image</label>
        <PageImageUpload v-model:image-url="config.hero_image_url" />

        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Image alt (EN)</label>
            <input v-model="config.hero_image_alt_en" class="field" />
          </div>
          <div>
            <label class="label">Image alt (BN)</label>
            <input v-model="config.hero_image_alt_bn" class="field" />
          </div>
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Hero button (EN)</label>
            <input v-model="config.hero_cta_en" class="field" />
          </div>
          <div>
            <label class="label">Hero button (BN)</label>
            <input v-model="config.hero_cta_bn" class="field" />
          </div>
        </div>
        <p class="hint">Every button on the page scrolls the customer to the checkout.</p>
      </div>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="video"
      :open="openSections['video'] ?? false"
      @update:open="openSections['video'] = $event"
      title="Video"
    >
      <div class="space-y-4">
        <div>
          <label class="label">Video URL</label>
          <input v-model="config.video_url" class="field" placeholder="https://…/video.mp4" />
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Section heading (EN)</label>
            <input v-model="config.video_heading_en" class="field" />
          </div>
          <div>
            <label class="label">Section heading (BN)</label>
            <input v-model="config.video_heading_bn" class="field" />
          </div>
          <div>
            <label class="label">Hero secondary button (EN)</label>
            <input v-model="config.hero_video_cta_en" class="field" />
          </div>
          <div>
            <label class="label">Hero secondary button (BN)</label>
            <input v-model="config.hero_video_cta_bn" class="field" />
          </div>
        </div>
        <p class="hint">
          Portrait video (576×1280) hosted on Cloudflare R2. Upload with
          <code
            >wrangler r2 object put &lt;bucket&gt;/videos/&lt;name&gt;.mp4 --file video.mp4</code
          >
          and paste the object's public URL above. Leaving the URL empty hides the video section and
          the hero's secondary button.
        </p>
      </div>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="the-problem"
      :open="openSections['the-problem'] ?? false"
      @update:open="openSections['the-problem'] = $event"
      title="The problem"
    >
      <div class="grid gap-4 md:grid-cols-2">
        <div>
          <label class="label">Heading (EN)</label>
          <input v-model="config.problem_heading_en" class="field" />
        </div>
        <div>
          <label class="label">Heading (BN)</label>
          <input v-model="config.problem_heading_bn" class="field" />
        </div>
        <div>
          <label class="label">Body (EN)</label>
          <textarea v-model="config.problem_body_en" rows="3" class="field"></textarea>
        </div>
        <div>
          <label class="label">Body (BN)</label>
          <textarea v-model="config.problem_body_bn" rows="3" class="field"></textarea>
        </div>
      </div>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="benefits"
      :open="openSections['benefits'] ?? false"
      @update:open="openSections['benefits'] = $event"
      title="Benefits"
    >
      <div
        v-for="(item, index) in config.benefits"
        :key="index"
        class="mb-3 rounded-md border border-gray-200 p-3"
      >
        <div class="flex items-center justify-between">
          <p class="text-xs text-gray-500">Benefit {{ index + 1 }}</p>
          <button
            type="button"
            class="text-xs text-red-600 hover:underline"
            @click="config.benefits.splice(index, 1)"
          >
            Remove
          </button>
        </div>
        <div class="mt-2 grid gap-2 md:grid-cols-2">
          <input
            v-model="item.icon"
            placeholder="Icon (emoji)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
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
        @click="
          config.benefits.push({ icon: '', title_en: '', title_bn: '', body_en: '', body_bn: '' })
        "
      >
        Add benefit
      </button>
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
      panel-id="how-it-works"
      :open="openSections['how-it-works'] ?? false"
      @update:open="openSections['how-it-works'] = $event"
      title="How it works"
    >
      <div class="grid gap-4 md:grid-cols-2">
        <div>
          <label class="label">Heading (EN)</label>
          <input v-model="config.how_heading_en" class="field" />
        </div>
        <div>
          <label class="label">Heading (BN)</label>
          <input v-model="config.how_heading_bn" class="field" />
        </div>
      </div>
      <div
        v-for="(step, index) in config.how"
        :key="index"
        class="mt-3 rounded-md border border-gray-200 p-3"
      >
        <div class="flex items-center justify-between">
          <p class="text-xs text-gray-500">Step {{ index + 1 }}</p>
          <button
            type="button"
            class="text-xs text-red-600 hover:underline"
            @click="config.how.splice(index, 1)"
          >
            Remove
          </button>
        </div>
        <div class="mt-2 grid gap-2 md:grid-cols-2">
          <input
            v-model="step.title_en"
            placeholder="Title (EN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <input
            v-model="step.title_bn"
            placeholder="Title (BN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <textarea
            v-model="step.body_en"
            rows="2"
            placeholder="Body (EN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <textarea
            v-model="step.body_bn"
            rows="2"
            placeholder="Body (BN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
        </div>
      </div>
      <button
        type="button"
        class="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
        @click="config.how.push({ title_en: '', title_bn: '', body_en: '', body_bn: '' })"
      >
        Add step
      </button>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="testimonials"
      :open="openSections['testimonials'] ?? false"
      @update:open="openSections['testimonials'] = $event"
      title="Testimonials"
    >
      <p class="hint mb-3">
        Quotes you have permission to use. Write them as real sentences from real customers; the
        page presents them exactly as written.
      </p>
      <div
        v-for="(entry, index) in config.testimonials"
        :key="index"
        class="mb-3 rounded-md border border-gray-200 p-3"
      >
        <div class="flex items-center justify-between">
          <p class="text-xs text-gray-500">Quote {{ index + 1 }}</p>
          <button
            type="button"
            class="text-xs text-red-600 hover:underline"
            @click="config.testimonials.splice(index, 1)"
          >
            Remove
          </button>
        </div>
        <div class="mt-2 grid gap-2 md:grid-cols-2">
          <textarea
            v-model="entry.quote_en"
            rows="2"
            placeholder="Quote (EN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <textarea
            v-model="entry.quote_bn"
            rows="2"
            placeholder="Quote (BN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <input
            v-model="entry.author_en"
            placeholder="Author (EN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <input
            v-model="entry.author_bn"
            placeholder="Author (BN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
        </div>
      </div>
      <button
        type="button"
        class="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
        @click="
          config.testimonials.push({ quote_en: '', quote_bn: '', author_en: '', author_bn: '' })
        "
      >
        Add quote
      </button>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="faq"
      :open="openSections['faq'] ?? false"
      @update:open="openSections['faq'] = $event"
      title="FAQ"
    >
      <div
        v-for="(entry, index) in config.faq"
        :key="index"
        class="mb-3 rounded-md border border-gray-200 p-3"
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
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <input
            v-model="entry.q_bn"
            placeholder="Question (BN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <textarea
            v-model="entry.a_en"
            rows="2"
            placeholder="Answer (EN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <textarea
            v-model="entry.a_bn"
            rows="2"
            placeholder="Answer (BN)"
            class="rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
        </div>
      </div>
      <button
        type="button"
        class="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
        @click="config.faq.push({ q_en: '', q_bn: '', a_en: '', a_bn: '' })"
      >
        Add question
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
          <label class="label">Checkout heading (EN)</label>
          <input v-model="config.checkout_heading_en" class="field" />
        </div>
        <div>
          <label class="label">Checkout heading (BN)</label>
          <input v-model="config.checkout_heading_bn" class="field" />
        </div>
        <div>
          <label class="label">Checkout note (EN)</label>
          <textarea v-model="config.checkout_note_en" rows="2" class="field"></textarea>
        </div>
        <div>
          <label class="label">Checkout note (BN)</label>
          <textarea v-model="config.checkout_note_bn" rows="2" class="field"></textarea>
        </div>
      </div>
      <p class="hint mt-3">
        The payment methods, prices and proof form are configured on this page's other fields - this
        section is only the words around them.
      </p>
    </CollapsibleSection>
  </div>
</template>

<script setup lang="ts">
import CollapsibleSection from '@/components/admin/CollapsibleSection.vue'
import PageImageUpload from '@/components/admin/PageImageUpload.vue'
import { ref } from 'vue'
import type { SalesLandingConfig } from '@/pages/templates/registry'

const openSections = ref<Record<string, boolean>>({
  hero: true,
})

const config = defineModel<SalesLandingConfig>({ required: true })
</script>

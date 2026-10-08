<template>
  <div>
    <router-link to="/admin/pages" class="mb-4 inline-block text-blue-600 hover:underline">
      ← Back to pages
    </router-link>

    <h1 class="mb-6 text-2xl font-bold text-gray-900">{{ isEdit ? 'Edit Page' : 'New Page' }}</h1>

    <form @submit.prevent="save" class="max-w-2xl space-y-6">
      <div>
        <label for="slug" class="block text-sm font-medium text-gray-700">Slug</label>
        <input
          id="slug"
          v-model="form.slug"
          required
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
      </div>

      <!-- The template decides which layout draws the page and which options
           appear below. Switching it re-renders the options panel; the stored
           config is kept until save, so an accidental switch is not lossy. -->
      <div>
        <label for="template" class="block text-sm font-medium text-gray-700">Template</label>
        <select
          id="template"
          v-model="form.template"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 md:w-64"
        >
          <option v-for="t in PAGE_TEMPLATES" :key="t.id" :value="t.id">{{ t.label }}</option>
        </select>
      </div>

      <!--
        The price chips the paywall shows. Comma-separated whole taka values;
        the customer taps one instead of typing, or picks Custom and types
        anything at or above the minimum. Leave empty for no chips.
      -->
      <div>
        <label for="presets" class="block text-sm font-medium text-gray-700">Amount presets</label>
        <input
          id="presets"
          v-model="presetsInput"
          placeholder="100, 500, 1000"
          class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
        />
        <div v-if="presetsPreview.length > 0" class="mt-2 flex flex-wrap gap-2">
          <span
            v-for="preset in presetsPreview"
            :key="preset"
            class="rounded-full border border-gray-200 bg-gray-50 px-3 py-1 text-sm text-gray-700"
          >
            ৳{{ preset }}
          </span>
        </div>
      </div>

      <div class="grid gap-6 md:grid-cols-2">
        <div>
          <label class="block text-sm font-medium text-gray-700">Title (EN)</label>
          <input
            v-model="form.title_en"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-gray-700">Title (BN)</label>
          <input
            v-model="form.title_bn"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>
      </div>

      <!--
        The prose fields, rendered from one list.

        They were in the form's state and in its save payload long before they had inputs, so an
        operator could load a page, change its title, save, and silently write back every teaser,
        body and button label exactly as they found it - with no way to see or change any of it.
        The list is the single place these eight fields are named, and the draft panel below reads
        the same one, so a field that gains an input here cannot be missing there.
      -->
      <fieldset class="space-y-4 border-t border-gray-200 pt-4">
        <legend class="sr-only">Product copy</legend>

        <div v-for="field in BRIEF_FIELDS" :key="field.form">
          <label :for="field.form" class="block text-sm font-medium text-gray-700">
            {{ field.label }}
          </label>
          <textarea
            v-if="field.kind === 'textarea'"
            :id="field.form"
            v-model="form[field.form] as string"
            rows="3"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <input
            v-else
            :id="field.form"
            v-model="form[field.form] as string"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>

        <!-- Not part of the brief. A URL is a thing the operator knows and the model cannot
             know, and inventing one would produce a pay button pointing nowhere. -->
        <div>
          <label for="cta_url" class="block text-sm font-medium text-gray-700"
            >Pay button URL</label
          >
          <input
            id="cta_url"
            v-model="form.cta_url"
            placeholder="https://…"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2"
          />
        </div>
      </fieldset>

      <!--
        The selected template's own options. Rendered through the registry so a
        template that adds options tomorrow needs no change here.
      -->
      <fieldset class="space-y-3 border-t border-gray-200 pt-4">
        <legend class="text-sm font-medium text-gray-700">
          {{ template.label }} template options
        </legend>
        <component :is="template.adminForm" v-model="form.template_config" />
      </fieldset>

      <!--
        Owner-only, and hidden from staff rather than disabled: `admin_upsert_page` is owner-only
        too, so a staff member who can see this button cannot save the result, and offering a
        button that cannot lead anywhere is worse than not offering it.
      -->
      <fieldset v-if="isOwner" class="space-y-3 border-t border-gray-200 pt-4">
        <legend class="text-sm font-medium text-gray-700">Fill the form with AI</legend>

        <p class="text-sm text-gray-600">
          Write one paragraph about what this page sells and what the buyer receives. The model
          fills every field from it, in both languages. Nothing is saved: everything lands in the
          fields below for you to read and edit, and what you leave out cannot appear, because the
          paragraph is the only thing the model sees.
        </p>

        <textarea
          v-model="paragraph"
          rows="4"
          placeholder="A pocket guide to the birds of the Sundarbans. Sixty pages, with photographs, a trail map and a checklist. Written for first-time visitors."
          class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
        ></textarea>

        <button
          type="button"
          :disabled="filling || paragraph.trim() === ''"
          class="rounded-md border border-blue-600 px-4 py-2 text-sm text-blue-700 hover:bg-blue-50 disabled:border-gray-300 disabled:text-gray-400"
          @click="fillForm"
        >
          {{ filling ? 'Filling...' : 'Fill every field' }}
        </button>

        <p v-if="fillError" class="rounded-lg bg-red-50 p-3 text-sm text-red-800">
          {{ fillError }}
        </p>
      </fieldset>

      <div class="flex flex-wrap items-center space-x-4">
        <label class="flex items-center">
          <input type="checkbox" v-model="form.is_active" class="rounded border-gray-300" />
          <span class="ml-2 text-sm">Active</span>
        </label>
        <label class="flex items-center">
          <input type="checkbox" v-model="form.is_listed" class="rounded border-gray-300" />
          <span class="ml-2 text-sm">Show in index</span>
        </label>
        <label class="flex items-center">
          <input type="checkbox" v-model="form.hide_min" class="rounded border-gray-300" />
          <span class="ml-2 text-sm">Hide Min</span>
        </label>
      </div>

      <!-- "Unlisted" is not "private". Spelling that out here prevents the
           obvious wrong move: treating it as an access control and expecting
           the slug to stop working. -->
      <p v-if="form.is_active && !form.is_listed" class="text-sm text-amber-700">
        This page is live and buyable by its URL, but it will not appear in the public index. Anyone
        with the URL can still open and pay for it.
      </p>

      <button
        type="submit"
        :disabled="saving"
        class="rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:bg-gray-400"
      >
        {{ saving ? 'Saving...' : 'Save' }}
      </button>

      <div v-if="error" class="rounded-lg bg-red-50 p-4 text-red-800">
        {{ error }}
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getSupabase } from '@/lib/supabase'
import { describeEdgeFailure } from '@/lib/edgeError'
import { useStaffRole } from '@/composables/useStaffRole'
import { PAGE_BRIEF_FIELDS as BRIEF_FIELDS, pageFormDefaults } from '@/config/linkBriefFields'
import { normalizeConfig, PAGE_TEMPLATES, templateFor } from '@/pages/templates/registry'
import { rpc, rpcList } from '@/lib/rpc'

const route = useRoute()
const router = useRouter()
const supabase = getSupabase()

const pageId = computed(() => route.params.id as string)
const isEdit = computed(() => !!route.params.id)

type PageForm = Record<string, string | boolean | number | null | Record<string, unknown>> & {
  template: string
}

const form = ref<PageForm>(pageFormDefaults() as PageForm)

/**
 * The presets, edited as comma-separated text and normalized on save. The
 * input keeps exactly what the operator typed; the payload carries the parsed
 * whole numbers, because the database refuses anything else.
 */
const presetsInput = ref('')

const presetsPreview = computed(() =>
  presetsInput.value
    .split(',')
    .map((part) => Number(part.trim()))
    .filter((n) => Number.isFinite(n) && n >= 1),
)

/** The template whose options panel is on screen right now. */
const template = computed(() => templateFor(form.value.template))

const saving = ref(false)
const error = ref<string | null>(null)

const { isOwner } = useStaffRole()

/**
 * Describe-and-fill state.
 *
 * `paragraph` is deliberately not part of `form`: it is a prompt, not shop copy, and saving it
 * would put a sentence the operator only meant for the model into the database. The fill lands
 * directly in the form's own fields rather than in a separate proposal panel, because the fields
 * are already on screen and already editable - a second copy of each value to accept or reject
 * would only ask the operator to read everything twice.
 */
const paragraph = ref('')
const filling = ref(false)
const fillError = ref<string | null>(null)

/**
 * The fields the model is asked to fill, in form-field names.
 *
 * Drawn from the form itself so the answer keys are the save payload's keys and
 * applying a value is one assignment. The landing template's lists (features,
 * FAQ) stay out on purpose: `ai-fill-form` fills strings, and a model-authored
 * list would be a proposal the operator cannot see the shape of before saving.
 */
const fillFields = computed(() => {
  const fields = [
    { key: 'title_en', label: 'Title (English)', hint: 'the page title, at most a few words' },
    { key: 'title_bn', label: 'Title (Bangla)', hint: 'the page title, at most a few words' },
    {
      key: 'teaser_en',
      label: 'Teaser (English)',
      hint: 'one or two sentences shown above the pay form; plain prose, no headings',
    },
    {
      key: 'teaser_bn',
      label: 'Teaser (Bangla)',
      hint: 'one or two sentences shown above the pay form; plain prose, no headings',
    },
    {
      key: 'body_en',
      label: 'What the buyer receives (English)',
      hint: 'shown after payment is approved; plain prose, no headings',
    },
    {
      key: 'body_bn',
      label: 'What the buyer receives (Bangla)',
      hint: 'shown after payment is approved; plain prose, no headings',
    },
    { key: 'cta_label_en', label: 'Pay button label (English)', hint: 'two or three words' },
    { key: 'cta_label_bn', label: 'Pay button label (Bangla)', hint: 'two or three words' },
  ]

  if (form.value.template === 'landing') {
    fields.push(
      {
        key: 'subtitle_en',
        label: 'Hero subtitle (English)',
        hint: 'one sentence under the title',
      },
      { key: 'subtitle_bn', label: 'Hero subtitle (Bangla)', hint: 'one sentence under the title' },
    )
  }

  // The selling templates own their whole page: the paragraph fills every
  // section's words. Their arrays (benefits, steps, FAQ rows) stay out - the
  // model writes strings, and those rows are edited one by one in the form.
  if (form.value.template === 'sales-landing') {
    fields.push(
      {
        key: 'hero_eyebrow_en',
        label: 'Eyebrow (English)',
        hint: 'two or three words above the title',
      },
      {
        key: 'hero_eyebrow_bn',
        label: 'Eyebrow (Bangla)',
        hint: 'two or three words above the title',
      },
      {
        key: 'hero_title_en',
        label: 'Hero title (English)',
        hint: 'the promise, at most a few words',
      },
      {
        key: 'hero_title_bn',
        label: 'Hero title (Bangla)',
        hint: 'the promise, at most a few words',
      },
      {
        key: 'hero_subtitle_en',
        label: 'Hero subtitle (English)',
        hint: 'one or two sentences under the title',
      },
      {
        key: 'hero_subtitle_bn',
        label: 'Hero subtitle (Bangla)',
        hint: 'one or two sentences under the title',
      },
      { key: 'hero_cta_en', label: 'Hero button (English)', hint: 'two or three words' },
      { key: 'hero_cta_bn', label: 'Hero button (Bangla)', hint: 'two or three words' },
      {
        key: 'problem_heading_en',
        label: 'Problem heading (English)',
        hint: 'the problem the buyer has, as a short sentence',
      },
      {
        key: 'problem_heading_bn',
        label: 'Problem heading (Bangla)',
        hint: 'the problem the buyer has, as a short sentence',
      },
      {
        key: 'problem_body_en',
        label: 'Problem body (English)',
        hint: 'two or three sentences of plain prose',
      },
      {
        key: 'problem_body_bn',
        label: 'Problem body (Bangla)',
        hint: 'two or three sentences of plain prose',
      },
      {
        key: 'included_heading_en',
        label: 'Included heading (English)',
        hint: 'a few words naming what the buyer receives',
      },
      {
        key: 'included_heading_bn',
        label: 'Included heading (Bangla)',
        hint: 'a few words naming what the buyer receives',
      },
      {
        key: 'how_heading_en',
        label: 'How it works heading (English)',
        hint: 'a few words naming the steps',
      },
      {
        key: 'how_heading_bn',
        label: 'How it works heading (Bangla)',
        hint: 'a few words naming the steps',
      },
      {
        key: 'checkout_heading_en',
        label: 'Checkout heading (English)',
        hint: 'an invitation to pay, a few words',
      },
      {
        key: 'checkout_heading_bn',
        label: 'Checkout heading (Bangla)',
        hint: 'an invitation to pay, a few words',
      },
      {
        key: 'checkout_note_en',
        label: 'Checkout note (English)',
        hint: 'one sentence beside the payment form',
      },
      {
        key: 'checkout_note_bn',
        label: 'Checkout note (Bangla)',
        hint: 'one sentence beside the payment form',
      },
    )
  }

  if (form.value.template === 'minimal-product') {
    fields.push(
      {
        key: 'hero_title_en',
        label: 'Title override (English)',
        hint: 'leave empty to keep the page title',
      },
      {
        key: 'hero_title_bn',
        label: 'Title override (Bangla)',
        hint: 'leave empty to keep the page title',
      },
      {
        key: 'hero_subtitle_en',
        label: 'Subtitle (English)',
        hint: 'one sentence under the title',
      },
      { key: 'hero_subtitle_bn', label: 'Subtitle (Bangla)', hint: 'one sentence under the title' },
      {
        key: 'checkout_note_en',
        label: 'Checkout note (English)',
        hint: 'one sentence beside the payment form',
      },
      {
        key: 'checkout_note_bn',
        label: 'Checkout note (Bangla)',
        hint: 'one sentence beside the payment form',
      },
    )
  }
  return fields
})

const fillForm = async (): Promise<void> => {
  if (filling.value || paragraph.value.trim() === '') return

  filling.value = true
  fillError.value = null

  try {
    const { data, error: fnError } = await supabase.functions.invoke('ai-fill-form', {
      body: { paragraph: paragraph.value.trim(), fields: fillFields.value },
    })

    if (fnError) throw fnError

    const values = (data as { values?: Record<string, unknown> } | null)?.values
    if (!values) throw new Error('The fill came back empty.')

    // A key the form does not have is ignored rather than invented into state.
    // The selling templates' words live inside the template config, so their
    // keys land there; the rest are ordinary form fields.
    const inConfig = ['sales-landing', 'minimal-product'].includes(form.value.template)
    for (const field of fillFields.value) {
      const value = values[field.key]
      if (typeof value !== 'string' || value === '') continue
      if (inConfig) {
        ;(form.value.template_config as Record<string, unknown>)[field.key] = value
      } else {
        form.value[field.key] = value
      }
    }
  } catch (err) {
    const failure = await describeEdgeFailure(err, 'The fill did not come back.')
    if (failure.cause !== '') console.warn('[ai-fill-form]', failure)
    fillError.value = failure.message
  } finally {
    filling.value = false
  }
}

onMounted(async () => {
  if (isEdit.value) {
    const { data } = await rpcList<Record<string, unknown>>('admin_pages')
    const row = (data ?? []).find((l) => l.id === pageId.value)
    if (row) {
      // The row columns and the form fields have different names, so assigning
      // the row wholesale would silently blank every markdown field on save.
      Object.assign(form.value, {
        slug: row.slug ?? '',
        title_en: row.title_en ?? '',
        title_bn: row.title_bn ?? '',
        teaser_en: row.teaser_md_en ?? '',
        teaser_bn: row.teaser_md_bn ?? '',
        body_en: row.unlock_body_md_en ?? '',
        body_bn: row.unlock_body_md_bn ?? '',
        cta_label_en: row.unlock_cta_label_en ?? '',
        cta_label_bn: row.unlock_cta_label_bn ?? '',
        cta_url: row.unlock_cta_url ?? '',
        is_active: row.is_active ?? false,
        is_listed: row.is_listed ?? true,
        sort_order: row.sort_order ?? 0,
        min_override: row.min_amount_override ?? null,
        hide_min: row.hide_min_override ?? false,
        template: row.template ?? 'standard',
        template_config: normalizeConfig(row.template as string, row.template_config),
      })
      presetsInput.value = ((form.value.amount_presets as number[] | null) ?? [])
        .map((n) => String(n))
        .join(', ')
    }
  }
})

const save = async (): Promise<void> => {
  saving.value = true
  error.value = null
  try {
    // `api.admin_upsert_page` takes one jsonb argument; the keys must match the
    // names it reads out of that jsonb exactly.
    const { error: rpcError } = await rpc<Record<string, unknown>>('admin_upsert_page', {
      p_page: {
        id: isEdit.value ? pageId.value : '',
        slug: form.value.slug,
        title_en: form.value.title_en,
        title_bn: form.value.title_bn,
        teaser_md_en: form.value.teaser_en,
        teaser_md_bn: form.value.teaser_bn,
        unlock_body_md_en: form.value.body_en,
        unlock_body_md_bn: form.value.body_bn,
        unlock_cta_label_en: form.value.cta_label_en,
        unlock_cta_label_bn: form.value.cta_label_bn,
        unlock_cta_url: form.value.cta_url,
        is_active: form.value.is_active,
        // Sent on every save, not just on create. The RPC's `on conflict` clause
        // lists this explicitly, and a missing key would let the old value win.
        is_listed: form.value.is_listed,
        sort_order: form.value.sort_order,
        min_amount_override: form.value.min_override,
        hide_min_override: form.value.hide_min,
        template: form.value.template,
        template_config: form.value.template_config,
        amount_presets: presetsPreview.value,
      },
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    router.push('/admin/pages')
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to save'
  } finally {
    saving.value = false
  }
}
</script>

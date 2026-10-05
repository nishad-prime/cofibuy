<template>
  <div>
    <router-link to="/admin/links" class="mb-4 inline-block text-blue-600 hover:underline">
      ← Back to links
    </router-link>

    <h1 class="mb-6 text-2xl font-bold text-gray-900">{{ isEdit ? 'Edit Link' : 'New Link' }}</h1>

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
        operator could load a link, change its title, save, and silently write back every teaser,
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
            v-model="form[field.form]"
            rows="3"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          ></textarea>
          <input
            v-else
            :id="field.form"
            v-model="form[field.form]"
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
        Owner-only, and hidden from staff rather than disabled: `admin_upsert_link` is owner-only
        too, so a staff member who can see this button cannot save the result, and offering a
        button that cannot lead anywhere is worse than not offering it.
      -->
      <fieldset v-if="isOwner" class="space-y-3 border-t border-gray-200 pt-4">
        <legend class="text-sm font-medium text-gray-700">Draft the copy with AI</legend>

        <p class="text-sm text-gray-600">
          Describe what the guide is and what is in it. This text is used only as the model's
          instructions — it is never saved — and the guide itself is never uploaded to it, so
          anything you leave out cannot appear in the draft.
        </p>

        <textarea
          v-model="subject"
          rows="3"
          placeholder="A pocket guide to the birds of the Sundarbans, with photographs and a map of the trails."
          class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
        ></textarea>

        <button
          type="button"
          :disabled="drafting || subject.trim() === ''"
          class="rounded-md border border-blue-600 px-4 py-2 text-sm text-blue-700 hover:bg-blue-50 disabled:border-gray-300 disabled:text-gray-400"
          @click="draftCopy"
        >
          {{ drafting ? 'Drafting...' : 'Draft copy' }}
        </button>

        <p v-if="draftError" class="rounded-lg bg-red-50 p-3 text-sm text-red-800">
          {{ draftError }}
        </p>

        <!--
          The proposal stays open after a field is applied, because the operator will usually
          keep most of it and reject one line, and the alternative - applying a single field
          closing the panel - would force them to draft again for the rest.
        -->
        <div v-if="brief" class="space-y-3 rounded-lg border border-blue-200 bg-blue-50/60 p-3">
          <div class="flex items-center justify-between gap-3">
            <p class="text-sm font-medium text-blue-900">
              Suggested copy — apply what you agree with.
            </p>
            <div class="flex items-center gap-3">
              <button
                type="button"
                class="text-xs text-blue-700 underline underline-offset-2"
                @click="applyAll"
              >
                Use all
              </button>
              <button
                type="button"
                class="text-xs text-gray-500 underline underline-offset-2"
                @click="discardBrief"
              >
                Discard
              </button>
            </div>
          </div>

          <div
            v-for="field in BRIEF_FIELDS"
            :key="`brief-${field.form}`"
            class="rounded border border-blue-100 bg-white p-2"
          >
            <div class="flex items-baseline justify-between gap-3">
              <p class="text-xs font-medium text-gray-500">{{ field.label }}</p>
              <button
                type="button"
                class="shrink-0 text-xs text-blue-700 underline underline-offset-2"
                @click="applyBrief(field.form)"
              >
                {{ applied.includes(field.form) ? 'Applied' : 'Use this' }}
              </button>
            </div>
            <p class="mt-1 whitespace-pre-wrap text-sm text-gray-800">{{ brief[field.key] }}</p>
          </div>
        </div>
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
        This link is live and buyable by its URL, but it will not appear in the public index. Anyone
        with the link can still open and pay for it.
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
import { LINK_BRIEF_FIELDS as BRIEF_FIELDS, linkFormDefaults } from '@/config/linkBriefFields'

const route = useRoute()
const router = useRouter()
const supabase = getSupabase()

const linkId = computed(() => route.params.id as string)
const isEdit = computed(() => !!route.params.id)

const form = ref<any>(linkFormDefaults())

const saving = ref(false)
const error = ref<string | null>(null)

const { isOwner } = useStaffRole()

/**
 * AI draft state.
 *
 * `subject` is deliberately not part of `form`: it is a prompt, not shop copy, and saving it would
 * put a sentence the operator only meant for the model into the database.
 */
const subject = ref('')
const brief = ref<Record<string, string> | null>(null)
const applied = ref<string[]>([])
const drafting = ref(false)
const draftError = ref<string | null>(null)

const draftCopy = async (): Promise<void> => {
  if (drafting.value || subject.value.trim() === '') return

  drafting.value = true
  draftError.value = null

  try {
    const { data, error: fnError } = await supabase.functions.invoke('ai-draft-link', {
      body: {
        subject: subject.value.trim(),
        slug: form.value.slug,
        // The form's current values, sent under their column names so the draft can improve on
        // them. Only what the operator has typed so far: a field they just cleared is empty on
        // purpose, and treating that as missing context would quietly draft it back.
        title_en: form.value.title_en,
        title_bn: form.value.title_bn,
        teaser_md_en: form.value.teaser_en,
        teaser_md_bn: form.value.teaser_bn,
        unlock_body_md_en: form.value.body_en,
        unlock_body_md_bn: form.value.body_bn,
        unlock_cta_label_en: form.value.cta_label_en,
        unlock_cta_label_bn: form.value.cta_label_bn,
      },
    })

    if (fnError) throw fnError

    const payload = data as { brief?: Record<string, unknown> } | null
    const next = payload?.brief

    // Every field or none. A partial set is the case the preview exists for, but a set missing a
    // field is a function bug rather than a draft, and applying it would blank the field.
    if (!next || BRIEF_FIELDS.some((field) => typeof next[field.key] !== 'string')) {
      throw new Error('The draft came back incomplete, so nothing was applied.')
    }

    brief.value = next as Record<string, string>
    applied.value = []
  } catch (err) {
    // The function's `detail` names the field or provider at fault; the SDK's own message does
    // not. `describeEdgeFailure` reads it out of the error's `context` and, when the request
    // never reached the function, reports the transport fault rather than the SDK's generic
    // `Failed to send a request to the Edge Function`, which reads the same for every cause.
    const failure = await describeEdgeFailure(err, 'The draft did not come back.')
    if (failure.cause !== '') console.warn('[ai-draft-link]', failure)
    draftError.value = failure.message
  } finally {
    drafting.value = false
  }
}

/** Moves one proposed field into the form, where it is an unsaved edit like anything else. */
const applyBrief = (formField: string): void => {
  const field = BRIEF_FIELDS.find((f) => f.form === formField)
  if (!field || !brief.value) return

  form.value[field.form] = brief.value[field.key]
  if (!applied.value.includes(field.form)) applied.value.push(field.form)
}

const applyAll = (): void => {
  for (const field of BRIEF_FIELDS) applyBrief(field.form)
}

const discardBrief = (): void => {
  brief.value = null
  applied.value = []
}

onMounted(async () => {
  if (isEdit.value) {
    const { data } = await (supabase.rpc as any)('admin_links')
    const link = (data || []).find((l: any) => l.id === linkId.value)
    if (link) {
      // The row columns and the form fields have different names, so assigning
      // the row wholesale would silently blank every markdown field on save.
      Object.assign(form.value, {
        slug: link.slug ?? '',
        title_en: link.title_en ?? '',
        title_bn: link.title_bn ?? '',
        teaser_en: link.teaser_md_en ?? '',
        teaser_bn: link.teaser_md_bn ?? '',
        body_en: link.unlock_body_md_en ?? '',
        body_bn: link.unlock_body_md_bn ?? '',
        cta_label_en: link.unlock_cta_label_en ?? '',
        cta_label_bn: link.unlock_cta_label_bn ?? '',
        cta_url: link.unlock_cta_url ?? '',
        is_active: link.is_active ?? false,
        is_listed: link.is_listed ?? true,
        sort_order: link.sort_order ?? 0,
        min_override: link.min_amount_override ?? null,
        hide_min: link.hide_min_override ?? false,
      })
    }
  }
})

const save = async (): Promise<void> => {
  saving.value = true
  error.value = null
  discardBrief()
  try {
    // `api.admin_upsert_link` takes one jsonb argument; the keys must match the
    // names it reads out of that jsonb exactly.
    const { error: rpcError } = await (supabase.rpc as any)('admin_upsert_link', {
      p_link: {
        id: isEdit.value ? linkId.value : '',
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
      },
    })
    if (rpcError) {
      error.value = rpcError.message
      return
    }
    router.push('/admin/links')
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to save'
  } finally {
    saving.value = false
  }
}
</script>
